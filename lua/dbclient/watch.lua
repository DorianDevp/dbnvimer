--- `watch(1)` for SQL, and a small statement profiler.
---
--- Watching a queue table during a deploy, or a counter while something drains,
--- is a real thing people do with a shell loop. Doing it in a buffer means the
--- changed cells can be highlighted, which is the part the shell loop cannot do.

local buffer = require("dbclient.ui.buffer")
local client = require("dbclient.core.client")
local grid = require("dbclient.ui.grid")
local highlights = require("dbclient.ui.highlights")
local session = require("dbclient.session")
local window = require("dbclient.ui.window")

local M = {
  --- bufnr -> watcher
  watchers = {},
}

local HEADER_LINES = 3

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

local function stop(watcher)
  if watcher.timer then
    watcher.timer:stop()
    watcher.timer:close()
    watcher.timer = nil
  end
end

--- Key a row by its first column so rows can be compared across runs even when
--- the order shifts.
local function row_key(row)
  local value = row[1]
  if value == nil or value == vim.NIL then
    return nil
  end
  return tostring(value)
end

--- Cells that differ from the previous run.
---@param previous table[]|nil
---@param rows table[]
---@return table<integer, table<integer, boolean>> changed, table<integer, boolean> added
local function diff_rows(previous, rows)
  local changed, added = {}, {}
  if not previous then
    return changed, added
  end

  local before = {}
  for _, row in ipairs(previous) do
    local key = row_key(row)
    if key then
      before[key] = row
    end
  end

  for index, row in ipairs(rows) do
    local key = row_key(row)
    local old = key and before[key]
    if not old then
      added[index] = true
    else
      for column = 1, #row do
        local a, b = row[column], old[column]
        local a_text = (a == nil or a == vim.NIL) and "\0" or tostring(a)
        local b_text = (b == nil or b == vim.NIL) and "\0" or tostring(b)
        if a_text ~= b_text then
          changed[index] = changed[index] or {}
          changed[index][column] = true
        end
      end
    end
  end

  return changed, added
end

local function render(watcher, result)
  local bufnr = watcher.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return stop(watcher)
  end

  local columns = result.columns or {}
  local rows = result.rows or {}
  local sizes = grid.widths(columns, rows)
  local spans = grid.spans(columns, sizes)
  local header, underline = grid.render_header(columns, sizes)

  local changed, added = diff_rows(watcher.previous, rows)
  watcher.previous = rows
  watcher.runs = (watcher.runs or 0) + 1

  local lines = {
    ("watch every %ds  ·  run %d  ·  %d row(s)  ·  %d ms  ·  %s"):format(
      watcher.interval,
      watcher.runs,
      #rows,
      result.elapsed_ms or 0,
      os.date("%H:%M:%S")
    ),
    header,
    underline,
  }
  local nulls = {}
  for index, row in ipairs(rows) do
    local line, row_nulls = grid.render_row(row, columns, sizes)
    table.insert(lines, line)
    nulls[index] = row_nulls
  end

  buffer.set_lines(bufnr, lines)

  highlights.grid(bufnr, {
    header_line = 1,
    first_row = HEADER_LINES,
    spans = spans,
    columns = columns,
    rows = #rows,
    nulls = nulls,
    stripes = false,
  })

  -- Highlight what moved since the previous run; this is the whole point.
  local marks = { { line = 0, group = "DBClientHeader" } }
  for index in pairs(added) do
    table.insert(marks, { line = HEADER_LINES + index - 1, group = "DBClientPendingAdd" })
  end
  for index, columns_changed in pairs(changed) do
    for column in pairs(columns_changed) do
      local span = spans[column]
      if span then
        table.insert(marks, {
          line = HEADER_LINES + index - 1,
          col = span.start,
          end_col = span.finish,
          group = "DBClientPending",
          priority = 200,
        })
      end
    end
  end
  highlights.lines(bufnr, marks, highlights.ns_virt)
end

--- Start watching a statement.
---@param opts { session_id?: string, sql: string, interval?: integer }
function M.start(opts)
  local target = session.get(opts.session_id)
  if not target then
    return notify("no active connection", vim.log.levels.WARN)
  end

  local bufnr = buffer.scratch("dbclient://watch", { modifiable = false })
  vim.bo[bufnr].filetype = "dbclient-watch"

  local existing = M.watchers[bufnr]
  if existing then
    stop(existing)
  end

  local watcher = {
    bufnr = bufnr,
    session_id = target.id,
    sql = opts.sql,
    interval = math.max(1, opts.interval or 5),
    previous = nil,
    runs = 0,
  }
  M.watchers[bufnr] = watcher

  buffer.show(bufnr, "botright 16split")
  vim.wo.cursorline = true
  vim.wo.wrap = false
  require("dbclient.ui.winbar").bind(bufnr, target.id)

  local function tick()
    client.async(function()
      local result = client.call("query", { sql = watcher.sql, limit = 500 }, watcher.session_id)
      render(watcher, result)
    end, function(err)
      buffer.set_lines(bufnr, { "! " .. tostring(err) })
      stop(watcher)
    end)
  end

  if not existing then
    vim.keymap.set("n", "q", function()
      stop(watcher)
      buffer.hide(bufnr)
    end, { buffer = bufnr, silent = true, nowait = true, desc = "DBClient: stop watching" })

    vim.keymap.set("n", "gr", tick, {
      buffer = bufnr,
      silent = true,
      desc = "DBClient: refresh now",
    })

    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = bufnr,
      callback = function()
        stop(watcher)
        M.watchers[bufnr] = nil
      end,
    })
  end

  tick()
  watcher.timer = vim.uv.new_timer()
  watcher.timer:start(
    watcher.interval * 1000,
    watcher.interval * 1000,
    vim.schedule_wrap(tick)
  )

  notify(("watching every %ds; q stops"):format(watcher.interval))
end

function M.stop_all()
  for _, watcher in pairs(M.watchers) do
    stop(watcher)
  end
end

--- Run a statement repeatedly and report the distribution of its timings.
---@param opts { session_id?: string, sql: string, runs?: integer }
function M.profile(opts)
  local target = session.get(opts.session_id)
  if not target then
    return notify("no active connection", vim.log.levels.WARN)
  end

  local runs = math.max(2, math.min(opts.runs or 10, 100))

  client.async(function()
    local timings = {}
    local rows = 0
    for _ = 1, runs do
      local result = client.call("query", { sql = opts.sql, limit = 1 }, target.id)
      table.insert(timings, result.elapsed_ms or 0)
      rows = #(result.rows or {})
    end
    table.sort(timings)

    local total = 0
    for _, value in ipairs(timings) do
      total = total + value
    end

    local function percentile(fraction)
      local index = math.max(1, math.ceil(#timings * fraction))
      return timings[index]
    end

    local lines = {
      ("%d runs of: %s"):format(runs, opts.sql:gsub("%s+", " "):sub(1, 90)),
      "",
      ("min     %6d ms"):format(timings[1]),
      ("median  %6d ms"):format(percentile(0.5)),
      ("p90     %6d ms"):format(percentile(0.9)),
      ("max     %6d ms"):format(timings[#timings]),
      ("mean    %6.1f ms"):format(total / #timings),
      "",
      ("rows returned: %d"):format(rows),
    }

    -- A tiny distribution so an outlier is visible rather than averaged away.
    local widest = timings[#timings]
    if widest > 0 then
      table.insert(lines, "")
      table.insert(lines, "each run, in order of duration:")
      for _, value in ipairs(timings) do
        local width = math.floor(value / widest * 40)
        table.insert(lines, ("  %6d ms  %s"):format(value, string.rep("▇", math.max(1, width))))
      end
    end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false

    local winid = window.float(bufnr, { title = "profile", max_width = 0.8, max_height = 0.8 })
    highlights.lines(bufnr, { { line = 0, group = "DBClientHeader" } })
    window.close_keys(bufnr, winid)
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

M.diff_rows = diff_rows

return M

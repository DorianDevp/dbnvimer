--- Server activity and lock monitor.
---
--- The view refreshes on a timer and can cancel or terminate the session under
--- the cursor, which is the pair of things you actually want at the moment you
--- open a monitor.

local buffer = require("dbclient.ui.buffer")
local client = require("dbclient.core.client")
local grid = require("dbclient.ui.grid")
local help = require("dbclient.ui.help")
local highlights = require("dbclient.ui.highlights")
local keymap = require("dbclient.keymap")
local session = require("dbclient.session")

local M = {
  bufnr = nil,
  timer = nil,
  auto = true,
  mode = "activity",
  session_id = nil,
  view = nil,
}

local INTERVAL_MS = 3000
local HEADER_LINES = 3

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

local function stop_timer()
  if M.timer then
    M.timer:stop()
    M.timer:close()
    M.timer = nil
  end
end

--- Fetch and draw the current view.
function M.refresh()
  if not M.bufnr or not vim.api.nvim_buf_is_valid(M.bufnr) then
    return stop_timer()
  end

  client.async(function()
    local result = M.mode == "locks" and session.locks(M.session_id) or session.activity(M.session_id)
    if not vim.api.nvim_buf_is_valid(M.bufnr) then
      return
    end

    local sizes = grid.widths(result.columns, result.rows)
    local header, underline = grid.render_header(result.columns, sizes)
    local lines = {
      ("%s  ·  %d row(s)  ·  %s  ·  %s"):format(
        M.mode,
        #result.rows,
        M.auto and ("auto %ds"):format(INTERVAL_MS / 1000) or "manual",
        os.date("%H:%M:%S")
      ),
      header,
      underline,
    }
    local nulls = {}
    for index, row in ipairs(result.rows) do
      local line, row_nulls = grid.render_row(row, result.columns, sizes)
      table.insert(lines, line)
      nulls[index] = row_nulls
    end

    M.view = {
      columns = result.columns,
      rows = result.rows,
      spans = grid.spans(result.columns, sizes),
      sizes = sizes,
    }

    local cursor = nil
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == M.bufnr then
        cursor = { win, vim.api.nvim_win_get_cursor(win) }
      end
    end

    buffer.set_lines(M.bufnr, lines)
    highlights.grid(M.bufnr, {
      header_line = 1,
      first_row = HEADER_LINES,
      spans = M.view.spans,
      columns = result.columns,
      rows = #result.rows,
      nulls = nulls,
      stripes = true,
    })
    highlights.lines(M.bufnr, { { line = 0, group = "DBClientHeader" } }, highlights.ns_virt)

    if cursor and vim.api.nvim_win_is_valid(cursor[1]) then
      local line = math.min(cursor[2][1], math.max(1, #lines))
      pcall(vim.api.nvim_win_set_cursor, cursor[1], { line, cursor[2][2] })
    end
  end, function(err)
    if M.bufnr and vim.api.nvim_buf_is_valid(M.bufnr) then
      buffer.set_lines(M.bufnr, { "! " .. tostring(err) })
    end
    stop_timer()
  end)
end

local function start_timer()
  stop_timer()
  if not M.auto then
    return
  end
  M.timer = vim.uv.new_timer()
  M.timer:start(INTERVAL_MS, INTERVAL_MS, vim.schedule_wrap(M.refresh))
end

--- The value of a named column on the row under the cursor.
---@param name string
---@return string|nil
local function column_value(name)
  if not M.view then
    return nil
  end
  local row_index = vim.api.nvim_win_get_cursor(0)[1] - HEADER_LINES
  local row = M.view.rows[row_index]
  if not row then
    return nil
  end
  for index, column in ipairs(M.view.columns) do
    if column.name:lower():find(name, 1, true) then
      local value = row[index]
      if value ~= nil and value ~= vim.NIL then
        return tostring(value)
      end
    end
  end
end

--- Cancel or terminate the backend under the cursor.
---@param terminate boolean
local function act_on_backend(terminate)
  local pid = column_value("pid") or column_value("id")
  if not pid then
    return notify("no process id on this row", vim.log.levels.WARN)
  end

  local target = session.get(M.session_id)
  if not target then
    return
  end
  local adapter = target.spec.adapter

  local sql
  if adapter == "postgres" then
    sql = terminate and ("select pg_terminate_backend(%s)"):format(pid)
      or ("select pg_cancel_backend(%s)"):format(pid)
  elseif adapter == "mariadb" then
    sql = terminate and ("kill connection %s"):format(pid) or ("kill query %s"):format(pid)
  else
    return notify("this backend has no session monitor", vim.log.levels.WARN)
  end

  vim.ui.select({ "no", "yes" }, {
    prompt = ("%s backend %s?"):format(terminate and "terminate" or "cancel", pid),
  }, function(choice)
    if choice ~= "yes" then
      return
    end
    client.async(function()
      session.query(target.id, sql)
      notify(("%s sent to %s"):format(terminate and "terminate" or "cancel", pid))
      M.refresh()
    end, function(err)
      notify(err, vim.log.levels.ERROR)
    end)
  end)
end

--- Open the monitor.
---@param opts? { session_id?: string, mode?: "activity"|"locks" }
function M.open(opts)
  opts = opts or {}
  local target = session.get(opts.session_id)
  if not target then
    return notify("no active connection", vim.log.levels.WARN)
  end

  M.session_id = target.id
  M.mode = opts.mode or "activity"

  local first = M.bufnr == nil or not vim.api.nvim_buf_is_valid(M.bufnr)
  M.bufnr = buffer.scratch("dbclient://activity", { modifiable = false })
  vim.bo[M.bufnr].filetype = "dbclient-activity"

  buffer.show(M.bufnr, "botright 18split")
  vim.wo.cursorline = true
  vim.wo.wrap = false
  require("dbclient.ui.winbar").bind(M.bufnr, target.id)

  if first then
    keymap.apply("activity", M.bufnr, {
      cancel_query = function()
        act_on_backend(false)
      end,
      kill_session = function()
        act_on_backend(true)
      end,
      refresh = M.refresh,
      toggle_auto = function()
        M.auto = not M.auto
        start_timer()
        M.refresh()
      end,
      close = function()
        stop_timer()
        buffer.hide(M.bufnr)
      end,
      help = help.handler("activity"),
    })

    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = M.bufnr,
      callback = function()
        stop_timer()
        M.bufnr = nil
      end,
    })
  end

  M.refresh()
  start_timer()
end

return M

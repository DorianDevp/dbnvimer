--- Result set snapshots, and diffing two of them.
---
--- "Did this change since yesterday?" and "why does this row differ between
--- staging and production?" are both questions with no good answer in most
--- tools. Here a result set can be written to a file and compared with a fresh
--- run, or with a run against another connection, using Neovim's own diff mode.

local buffer = require("dbclient.ui.buffer")
local client = require("dbclient.core.client")
local config = require("dbclient.config")
local export = require("dbclient.export")
local session = require("dbclient.session")

local M = {}

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

local function directory()
  return config.get().export.dir .. "/snapshots"
end

--- Render a result set in a form that diffs cleanly: one row per line, sorted,
--- with each cell labelled so a column insertion does not shift everything.
---@param result table
---@param opts? { sort?: boolean }
---@return string[]
function M.render(result, opts)
  opts = opts or {}
  local columns = result.columns or {}
  local rows = result.rows or {}

  local lines = {}
  for _, row in ipairs(rows) do
    local cells = {}
    for index, column in ipairs(columns) do
      local value = row[index]
      table.insert(
        cells,
        ("%s=%s"):format(
          column.name,
          value == nil or value == vim.NIL and "NULL" or tostring(value)
        )
      )
    end
    table.insert(lines, table.concat(cells, "  "))
  end

  -- Sorting makes the diff about content rather than row order, which is what
  -- you want when comparing two servers.
  if opts.sort ~= false then
    table.sort(lines)
  end
  return lines
end

--- Write a result set to a snapshot file.
---@param result table
---@param name string
---@return string path
function M.save(result, name)
  vim.fn.mkdir(directory(), "p")
  local path = ("%s/%s.snapshot"):format(directory(), name:gsub("[^%w_.-]", "_"))

  local lines = {
    ("-- dbclient snapshot: %s"):format(name),
    ("-- taken: %s"):format(os.date("%Y-%m-%d %H:%M:%S")),
    ("-- rows: %d"):format(#(result.rows or {})),
    "",
  }
  vim.list_extend(lines, M.render(result))
  vim.fn.writefile(lines, path)
  return path
end

--- List saved snapshots, newest first.
---@return { name: string, path: string, at: integer }[]
function M.list()
  local found = {}
  for _, path in ipairs(vim.fn.glob(directory() .. "/*.snapshot", false, true)) do
    local stat = vim.uv.fs_stat(path)
    table.insert(found, {
      name = vim.fn.fnamemodify(path, ":t:r"),
      path = path,
      at = stat and stat.mtime.sec or 0,
    })
  end
  table.sort(found, function(a, b)
    return a.at > b.at
  end)
  return found
end

--- Open two sets of lines side by side in diff mode.
---@param left { name: string, lines: string[] }
---@param right { name: string, lines: string[] }
function M.diff_lines(left, right)
  local left_buf = buffer.scratch("dbclient://snapshot/" .. left.name, { modifiable = false })
  local right_buf = buffer.scratch("dbclient://snapshot/" .. right.name, { modifiable = false })

  buffer.set_lines(left_buf, left.lines)
  buffer.set_lines(right_buf, right.lines)

  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, left_buf)
  vim.cmd("diffthis")
  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, right_buf)
  vim.cmd("diffthis")
  vim.cmd("wincmd p")

  notify("]c and [c walk the differences")
end

--- Save the result buffer's current contents.
function M.save_current()
  local view = require("dbclient.ui.results").view()
  if not view then
    return notify("no result set to snapshot", vim.log.levels.WARN)
  end

  local suggested = os.date("%Y%m%d-%H%M%S")
  vim.ui.input({ prompt = "snapshot name ", default = suggested }, function(name)
    if not name or name == "" then
      return
    end
    local path = M.save(view, name)
    notify("saved " .. path)
  end)
end

--- Compare the current result buffer with a saved snapshot.
function M.diff_with_saved()
  local view = require("dbclient.ui.results").view()
  if not view then
    return notify("run a query first", vim.log.levels.WARN)
  end

  local snapshots = M.list()
  if #snapshots == 0 then
    return notify("no snapshots saved yet", vim.log.levels.WARN)
  end

  vim.ui.select(snapshots, {
    prompt = "compare with",
    format_item = function(entry)
      return ("%s  %s"):format(os.date("%Y-%m-%d %H:%M", entry.at), entry.name)
    end,
  }, function(choice)
    if not choice then
      return
    end
    local saved = vim.fn.readfile(choice.path)
    -- Drop the header comments so the diff is about data.
    local body = {}
    for _, line in ipairs(saved) do
      if not line:match("^%-%-") and line ~= "" then
        table.insert(body, line)
      end
    end

    M.diff_lines(
      { name = choice.name, lines = body },
      { name = "current", lines = M.render(view) }
    )
  end)
end

--- Run the same statement against two connections and diff the results.
---@param opts? { sql?: string }
function M.diff_connections(opts)
  opts = opts or {}
  local sessions = session.list()
  if #sessions < 2 then
    return notify("open at least two connections first", vim.log.levels.WARN)
  end

  local function ask_sql(callback)
    if opts.sql then
      return callback(opts.sql)
    end
    local view = require("dbclient.ui.results").view()
    vim.ui.input({ prompt = "sql ", default = view and view.sql or "" }, function(sql)
      if sql and sql:match("%S") then
        callback(sql)
      end
    end)
  end

  ask_sql(function(sql)
    vim.ui.select(sessions, {
      prompt = "left side",
      format_item = function(entry)
        return entry.name
      end,
    }, function(left)
      if not left then
        return
      end
      vim.ui.select(sessions, {
        prompt = "right side",
        format_item = function(entry)
          return entry.name
        end,
      }, function(right)
        if not right then
          return
        end
        client.async(function()
          local left_result = client.call("query", { sql = sql, limit = 20000 }, left.id)
          local right_result = client.call("query", { sql = sql, limit = 20000 }, right.id)
          M.diff_lines(
            { name = left.name, lines = M.render(left_result) },
            { name = right.name, lines = M.render(right_result) }
          )
        end, function(err)
          notify(err, vim.log.levels.ERROR)
        end)
      end)
    end)
  end)
end

--- Export the current result set through a shell pipeline.
---
--- `:'<,'>!jq …` already works on the buffer text; this is for feeding the
--- machine-readable form instead of the aligned grid.
---@param command string
---@param format string|nil
function M.pipe(command, format)
  local view = require("dbclient.ui.results").view()
    or require("dbclient.ui.data").view()
  if not view then
    return notify("no result set", vim.log.levels.WARN)
  end

  local input = table.concat(export.render(view, format or "jsonl"), "\n")
  local result = vim.system({ "sh", "-c", command }, { stdin = input, text = true }):wait()

  local lines = vim.split((result.stdout or "") .. (result.stderr or ""), "\n")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "hide"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, bufnr)
  notify(("piped through `%s` (exit %d)"):format(command, result.code))
end

return M

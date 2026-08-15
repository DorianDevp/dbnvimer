--- Save and restore the DBClient workspace for a project.
---
--- `:mksession` does not know what a data buffer is, and reconstructing one
--- means reconnecting and re-running its query rather than restoring bytes. The
--- state is keyed by working directory, so coming back to a project brings back
--- the connections, the tables you had open with their filters and sorts, and
--- the contents of the query buffer.

local config = require("dbclient.config")
local session = require("dbclient.session")

local M = {}

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

local function directory()
  return vim.fs.dirname(config.get().history.path) .. "/workspaces"
end

--- One file per project, named after the path so it is recognisable.
---@param cwd string|nil
---@return string
function M.path(cwd)
  cwd = cwd or vim.uv.cwd()
  local slug = cwd:gsub("^/", ""):gsub("[^%w]", "_")
  return ("%s/%s.json"):format(directory(), slug)
end

--- Capture the current workspace.
---@return table
function M.capture()
  local state = {
    version = 1,
    cwd = vim.uv.cwd(),
    at = os.time(),
    connections = {},
    data = {},
    queries = {},
    active = nil,
  }

  for _, target in ipairs(session.list()) do
    table.insert(state.connections, target.name)
    if session.active == target.id then
      state.active = target.name
    end
  end

  for bufnr, view in pairs(require("dbclient.ui.data").views) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local target = session.get(view.session_id)
      table.insert(state.data, {
        connection = target and target.name,
        schema = view.schema,
        table = view.table,
        filter = view.filter,
        sort = view.sort,
        limit = view.limit,
        offset = view.offset,
        hidden = vim.tbl_keys(view.hidden or {}),
      })
    end
  end

  for bufnr, bound in pairs(require("dbclient.ui.query").buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local target = session.get(bound.session_id)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      if #lines > 1 or (lines[1] or "") ~= "" then
        table.insert(state.queries, {
          connection = target and target.name,
          name = vim.api.nvim_buf_get_name(bufnr),
          lines = lines,
        })
      end
    end
  end

  return state
end

--- Write the workspace to disk.
---@param cwd string|nil
---@return string|nil path
function M.save(cwd)
  local state = M.capture()
  if #state.connections == 0 and #state.data == 0 and #state.queries == 0 then
    return nil
  end

  vim.fn.mkdir(directory(), "p")
  local path = M.path(cwd)
  local ok = pcall(vim.fn.writefile, vim.split(vim.json.encode(state), "\n"), path)
  return ok and path or nil
end

--- Read a saved workspace.
---@param cwd string|nil
---@return table|nil
function M.load(cwd)
  local path = M.path(cwd)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok, state = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(state) ~= "table" then
    return nil
  end
  return state
end

--- Reopen everything a saved workspace describes.
---@param opts? { cwd?: string, silent?: boolean }
function M.restore(opts)
  opts = opts or {}
  local state = M.load(opts.cwd)
  if not state then
    if not opts.silent then
      notify("no saved workspace for this directory", vim.log.levels.WARN)
    end
    return
  end

  local remaining = #state.connections
  if remaining == 0 then
    return
  end

  local function reopen()
    for _, entry in ipairs(state.data or {}) do
      local target = entry.connection and session.find_by_name(entry.connection)
      if target then
        local hidden = {}
        for _, index in ipairs(entry.hidden or {}) do
          hidden[index] = true
        end
        require("dbclient.ui.data").open({
          session_id = target.id,
          schema = entry.schema,
          table = entry.table,
          filter = entry.filter,
          sort = entry.sort,
          limit = entry.limit,
          offset = entry.offset,
        })
        -- Hidden columns are restored after the first render.
        vim.defer_fn(function()
          for _, view in pairs(require("dbclient.ui.data").views) do
            if view.table == entry.table and view.schema == entry.schema then
              view.hidden = hidden
              require("dbclient.ui.data").render(view)
            end
          end
        end, 400)
      end
    end

    for _, entry in ipairs(state.queries or {}) do
      local target = entry.connection and session.find_by_name(entry.connection)
      if target then
        local bufnr = require("dbclient.ui.query").open({ session_id = target.id })
        if bufnr and entry.lines then
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, entry.lines)
        end
      end
    end

    if state.active then
      local target = session.find_by_name(state.active)
      if target then
        session.activate(target.id)
      end
    end

    notify(("restored %d connection(s) and %d table(s)"):format(
      #state.connections,
      #(state.data or {})
    ))
  end

  for _, name in ipairs(state.connections) do
    session.connect(name, function(_, err)
      if err and not opts.silent then
        notify(("could not reopen %s: %s"):format(name, err), vim.log.levels.WARN)
      end
      remaining = remaining - 1
      if remaining == 0 then
        vim.schedule(reopen)
      end
    end)
  end
end

--- Forget the saved workspace for this directory.
function M.clear(cwd)
  local path = M.path(cwd)
  if vim.fn.filereadable(path) == 1 then
    vim.fn.delete(path)
    notify("workspace cleared")
  end
end

--- Describe what would be restored, without doing it.
---@return string[]
function M.describe()
  local state = M.load()
  if not state then
    return { "no saved workspace for " .. vim.uv.cwd() }
  end

  local lines = {
    ("workspace for %s"):format(state.cwd or "?"),
    ("saved %s"):format(os.date("%Y-%m-%d %H:%M:%S", state.at or 0)),
    "",
    "connections:",
  }
  for _, name in ipairs(state.connections or {}) do
    table.insert(lines, "  " .. name .. (name == state.active and "  (active)" or ""))
  end

  if #(state.data or {}) > 0 then
    table.insert(lines, "")
    table.insert(lines, "tables:")
    for _, entry in ipairs(state.data) do
      local detail = {}
      if entry.filter then
        table.insert(detail, "where " .. entry.filter)
      end
      for _, term in ipairs(entry.sort or {}) do
        table.insert(detail, ("order by %s %s"):format(term.column, term.dir))
      end
      table.insert(
        lines,
        ("  %s.%s%s"):format(
          entry.schema,
          entry.table,
          #detail > 0 and ("  ·  " .. table.concat(detail, ", ")) or ""
        )
      )
    end
  end

  if #(state.queries or {}) > 0 then
    table.insert(lines, "")
    table.insert(lines, ("%d query buffer(s)"):format(#state.queries))
  end

  return lines
end

return M

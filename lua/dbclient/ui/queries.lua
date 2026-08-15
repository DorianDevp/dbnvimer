--- The saved query browser.
---
--- Two scopes are shown together: queries kept with the project, which the team
--- shares through the repository, and queries kept globally, which are yours.
--- `p` moves one between the two, because "this is worth sharing" is a decision
--- you usually make after writing it.

local buffer = require("dbclient.ui.buffer")
local help = require("dbclient.ui.help")
local highlights = require("dbclient.ui.highlights")
local keymap = require("dbclient.keymap")
local queries = require("dbclient.queries")
local session = require("dbclient.session")
local window = require("dbclient.ui.window")

local M = {
  bufnr = nil,
  winid = nil,
  ---@type table<integer, table|false>
  rows = {},
  session_id = nil,
}

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

local function render()
  if not M.bufnr or not vim.api.nvim_buf_is_valid(M.bufnr) then
    return
  end

  local entries = queries.list()
  local lines = {}
  local marks = {}
  M.rows = {}

  local function add(text, group, entry)
    table.insert(lines, text)
    if group then
      table.insert(marks, { line = #lines - 1, group = group })
    end
    M.rows[#lines] = entry or false
  end

  add("saved queries", "DBClientHeader")
  add("")

  if #entries == 0 then
    add("  none yet — press n to write one", "DBClientDetected")
  end

  local width = 0
  for _, entry in ipairs(entries) do
    width = math.max(width, vim.fn.strdisplaywidth(entry.name))
  end

  local scope = nil
  for _, entry in ipairs(entries) do
    if entry.scope ~= scope then
      -- No leading blank before the first group; the header already spaced it.
      if scope ~= nil then
        add("")
      end
      scope = entry.scope
      add(
        scope == "project" and "project  ·  shared through the repository"
          or "global  ·  yours alone",
        "DBClientSchema"
      )
    end

    local detail = {}
    if entry.connection then
      table.insert(detail, entry.connection)
    end
    if entry.description then
      table.insert(detail, entry.description)
    end
    if #entry.tags > 0 then
      table.insert(detail, "#" .. table.concat(entry.tags, " #"))
    end

    add(
      ("  %-" .. width .. "s   %s"):format(entry.name, table.concat(detail, "  ·  ")),
      "DBClientTable",
      entry
    )
  end

  add("")
  add("<CR> open   r run   n new   e rename   x delete   p scope   y yank   g? help", "DBClientHelpText")

  buffer.set_lines(M.bufnr, lines)
  highlights.lines(M.bufnr, marks)
end

---@return table|nil
local function selected()
  if not M.winid or not vim.api.nvim_win_is_valid(M.winid) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(M.winid)[1]
  local entry = M.rows[row]
  return entry or nil
end

--- The session a query should run on: its own `@conn`, else the active one.
---@param entry table
---@return table|nil
local function session_for(entry)
  if entry.connection then
    local target = session.find_by_name(entry.connection)
    if target then
      return target
    end
  end
  return session.get(M.session_id) or session.current()
end

local function close()
  window.close(M.winid, nil)
  M.winid = nil
end

--- Open a saved query in the quick query tab.
local function open_entry(entry)
  entry = entry or selected()
  if not entry then
    return
  end

  local target = session_for(entry)
  if not target then
    return notify("connect first", vim.log.levels.WARN)
  end

  close()
  require("dbclient.ui.scratch").open({ session_id = target.id, sql = entry.sql })
end

--- Run a saved query without opening it.
local function run_entry()
  local entry = selected()
  if not entry then
    return
  end

  local target = session_for(entry)
  if not target then
    return notify("connect first", vim.log.levels.WARN)
  end

  close()
  require("dbclient.core.client").async(function()
    local result = session.query(target.id, entry.sql, nil)
    require("dbclient.ui.results").show(result, {
      session_id = target.id,
      session_name = target.name,
      sql = entry.sql,
    })
    require("dbclient.history").record(target.name, entry.sql)
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

local function new_entry()
  close()
  local target = session.get(M.session_id) or session.current()
  if not target then
    return notify("connect first", vim.log.levels.WARN)
  end
  require("dbclient.ui.scratch").open({ session_id = target.id })
  notify("write the query, then gs to save it")
end

local function rename_entry()
  local entry = selected()
  if not entry then
    return
  end
  vim.ui.input({ prompt = "new name ", default = entry.name }, function(name)
    if not name or name == "" or name == entry.name then
      return
    end
    local path, err = queries.rename(entry, name)
    if not path then
      return notify(tostring(err), vim.log.levels.ERROR)
    end
    render()
  end)
end

local function delete_entry()
  local entry = selected()
  if not entry then
    return
  end
  vim.ui.select({ "no", "yes" }, {
    prompt = ("delete `%s`?"):format(entry.name),
  }, function(choice)
    if choice ~= "yes" then
      return
    end
    local ok, err = queries.delete(entry.path)
    if not ok then
      return notify(tostring(err), vim.log.levels.ERROR)
    end
    notify("deleted " .. entry.name)
    render()
  end)
end

local function promote_entry()
  local entry = selected()
  if not entry then
    return
  end
  local path, err = queries.promote(entry)
  if not path then
    return notify(tostring(err), vim.log.levels.ERROR)
  end
  notify(("moved `%s` to %s"):format(entry.name, entry.scope == "project" and "global" or "project"))
  render()
end

local function yank_entry()
  local entry = selected()
  if not entry then
    return
  end
  vim.fn.setreg('"', entry.sql)
  vim.fn.setreg("+", entry.sql)
  notify("yanked " .. entry.name)
end

--- Open the browser.
---@param opts? { session_id?: string }
function M.open(opts)
  opts = opts or {}
  M.session_id = opts.session_id

  M.bufnr = buffer.scratch("dbclient://queries", { modifiable = false })
  vim.bo[M.bufnr].filetype = "dbclient-queries"

  M.winid = window.float(M.bufnr, {
    title = "saved queries",
    max_width = 0.8,
    max_height = 0.7,
  })

  render()

  keymap.apply("queries", M.bufnr, {
    open = function()
      open_entry()
    end,
    run = run_entry,
    new = new_entry,
    rename = rename_entry,
    delete = delete_entry,
    promote = promote_entry,
    yank = yank_entry,
    refresh = render,
    close = close,
    help = help.handler("queries"),
  })

  -- Land on the first query rather than the header.
  for row, entry in pairs(M.rows) do
    if entry then
      pcall(vim.api.nvim_win_set_cursor, M.winid, { row, 0 })
      break
    end
  end
end

--- Pick a saved query through `vim.ui.select`, for users who prefer a picker.
function M.pick()
  local entries = queries.list()
  if #entries == 0 then
    return notify("no saved queries yet")
  end

  vim.ui.select(entries, {
    prompt = "saved queries",
    format_item = function(entry)
      return ("%-8s %-28s %s"):format(
        entry.scope,
        entry.name,
        entry.description or entry.sql:gsub("%s+", " "):sub(1, 50)
      )
    end,
  }, function(choice)
    if choice then
      open_entry(choice)
    end
  end)
end

M.render = render

return M

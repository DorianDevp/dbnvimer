--- Pickers, built on `vim.ui.select`.
---
--- Going through `vim.ui.select` means telescope, fzf-lua, snacks and dressing
--- users get their own picker for free, and nobody has to install one.

local client = require("dbclient.core.client")
local completion = require("dbclient.completion")
local connections = require("dbclient.connections")
local history = require("dbclient.history")
local session = require("dbclient.session")

local M = {}

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

--- Choose a connection and open it.
---@param callback? fun(target: table)
function M.connection(callback)
  connections.rescan()
  local names = connections.names()
  if #names == 0 then
    notify("no connections configured; press <leader>dC to add one", vim.log.levels.WARN)
    return require("dbclient.connections.ui").open()
  end

  local items = {}
  for _, name in ipairs(names) do
    table.insert(items, name)
  end

  vim.ui.select(items, {
    prompt = "connection",
    format_item = function(name)
      local spec = connections.get(name) or {}
      local open = session.find_by_name(name) and "● " or "○ "
      return ("%s%-20s %s"):format(open, name, connections.describe(name, spec))
    end,
  }, function(choice)
    if not choice then
      return
    end
    session.connect(choice, function(target, err)
      if err then
        return notify(err, vim.log.levels.ERROR)
      end
      completion.warm(target.id)
      require("dbclient.ui.sidebar").render()
      notify("connected to " .. choice)
      if callback then
        callback(target)
      end
    end)
  end)
end

--- Search every cached table and column.
function M.objects()
  local target = session.current()
  if not target then
    return notify("no active connection", vim.log.levels.WARN)
  end

  notify("indexing objects...")
  completion.load_all_columns(target.id, function()
    local entries = completion.search_entries(target.id)
    if #entries == 0 then
      return notify("nothing indexed yet; expand a schema first", vim.log.levels.WARN)
    end

    vim.ui.select(entries, {
      prompt = "objects",
      format_item = function(entry)
        return entry.label
      end,
    }, function(choice)
      if not choice then
        return
      end
      require("dbclient.ui.data").open({
        session_id = target.id,
        schema = choice.schema,
        table = choice.table,
      })
      if choice.column then
        notify(("column %s is in this table"):format(choice.column))
      end
    end)
  end)
end

--- Re-run something from the history.
function M.history()
  local target = session.current()
  local entries = history.recent()
  if #entries == 0 then
    return notify("history is empty")
  end

  vim.ui.select(entries, {
    prompt = "history",
    format_item = history.label,
  }, function(choice)
    if not choice then
      return
    end
    require("dbclient.ui.query").open({
      session_id = target and target.id,
      sql = choice.sql,
    })
  end)
end

--- Statements executed in this Neovim session, with timings.
function M.statement_log()
  local entries = session.log
  if #entries == 0 then
    return notify("nothing has been executed yet")
  end

  local columns = {
    { name = "at", type = "text", class = "temporal" },
    { name = "connection", type = "text", class = "text" },
    { name = "ms", type = "int", class = "number" },
    { name = "rows", type = "int", class = "number" },
    { name = "ok", type = "bool", class = "bool" },
    { name = "statement", type = "text", class = "text" },
  }

  local rows = {}
  for index = #entries, 1, -1 do
    local entry = entries[index]
    table.insert(rows, {
      os.date("%H:%M:%S", entry.at),
      entry.session,
      tostring(entry.elapsed_ms or 0),
      tostring(entry.rows or entry.affected or 0),
      entry.ok and "true" or "false",
      (entry.sql or ""):gsub("%s+", " "),
    })
  end

  require("dbclient.ui.results").show({
    columns = columns,
    rows = rows,
    elapsed_ms = 0,
    affected_rows = 0,
  }, { session_name = "statement log" })
end

--- Choose one of the open sessions.
function M.session()
  local sessions = session.list()
  if #sessions == 0 then
    return M.connection()
  end
  if #sessions == 1 then
    session.activate(sessions[1].id)
    return notify("active connection: " .. sessions[1].name)
  end

  vim.ui.select(sessions, {
    prompt = "active connection",
    format_item = function(entry)
      return ("%s  %s"):format(entry.name, entry.info and entry.info.server_version or "")
    end,
  }, function(choice)
    if choice then
      session.activate(choice.id)
      require("dbclient.ui.sidebar").render()
      require("dbclient.ui.winbar").refresh()
    end
  end)
end

--- Pick two schemas to diff, across connections if wanted.
function M.schema_diff()
  local sessions = session.list()
  if #sessions == 0 then
    return notify("connect first", vim.log.levels.WARN)
  end

  local function pick_side(prompt, callback)
    local entries = {}
    client.async(function()
      for _, target in ipairs(sessions) do
        local ok, schemas = pcall(session.schemas, target.id)
        if ok then
          for _, schema in ipairs(schemas) do
            table.insert(entries, {
              session_id = target.id,
              schema = schema.name,
              label = ("%s  %s"):format(target.name, schema.name),
            })
          end
        end
      end

      vim.ui.select(entries, {
        prompt = prompt,
        format_item = function(entry)
          return entry.label
        end,
      }, function(choice)
        if choice then
          callback(choice)
        end
      end)
    end, function(err)
      notify(err, vim.log.levels.ERROR)
    end)
  end

  pick_side("diff: left side", function(left)
    pick_side("diff: right side", function(right)
      require("dbclient.ui.ddl").diff_schemas({ left = left, right = right })
    end)
  end)
end

return M

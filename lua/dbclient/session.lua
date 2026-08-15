--- Session manager: many live connections at once, each with its own cache.
---
--- Every metadata accessor here must be called from inside `client.async`;
--- they yield until the core replies rather than blocking the editor.

local client = require("dbclient.core.client")
local config = require("dbclient.config")
local connections = require("dbclient.connections")

local M = {
  ---@type table<string, table>
  sessions = {},
  ---@type string|nil
  active = nil,
  ---@type string[]
  order = {},
  --- Statements executed this Neovim session, newest last.
  log = {},
  listeners = {},
}

local function empty_cache()
  return {
    schemas = nil,
    tables = {},
    columns = {},
    routines = {},
    indexes = {},
    foreign_keys = {},
    referencing = {},
    schema_keys = {},
  }
end

local function emit(event, payload)
  for _, listener in ipairs(M.listeners[event] or {}) do
    pcall(listener, payload)
  end
end

--- Subscribe to `connect`, `disconnect`, `activate`, `transaction` or `log`.
---@param event string
---@param callback fun(payload: any)
function M.on(event, callback)
  M.listeners[event] = M.listeners[event] or {}
  table.insert(M.listeners[event], callback)
end

--- The currently focused session, if any.
---@return table|nil
function M.current()
  return M.active and M.sessions[M.active] or nil
end

--- Session by id, or the active one when `id` is nil.
---@param id string|nil
---@return table|nil
function M.get(id)
  if id then
    return M.sessions[id]
  end
  return M.current()
end

--- Require an active session, raising inside the coroutine when there is none.
---@param id string|nil
---@return table
function M.require_session(id)
  local session = M.get(id)
  if not session then
    error("no active DBClient connection; run :DBClientConnect", 0)
  end
  return session
end

--- Sessions in the order they were opened.
---@return table[]
function M.list()
  local list = {}
  for _, id in ipairs(M.order) do
    if M.sessions[id] then
      table.insert(list, M.sessions[id])
    end
  end
  return list
end

--- Open a connection by name. Runs asynchronously and calls back with the
--- session table on success.
---@param name string
---@param callback? fun(session: table|nil, err: string|nil)
function M.connect(name, callback)
  local spec = connections.get(name)
  if not spec then
    local err = ("unknown connection `%s`"):format(name)
    if callback then
      callback(nil, err)
    else
      vim.notify("DBClient: " .. err, vim.log.levels.ERROR)
    end
    return
  end

  local existing = M.find_by_name(name)
  if existing then
    M.activate(existing.id)
    if callback then
      callback(existing, nil)
    end
    return
  end

  connections.resolve_password(name, spec, function(password)
    local connection, ssh = connections.to_wire(name, spec, password)
    client.async(function()
      local result = client.call("open-session", { connection = connection, ssh = ssh })
      local session = {
        id = result.session,
        name = name,
        spec = spec,
        info = result.info,
        cache = empty_cache(),
        in_transaction = false,
        color = spec.color,
        opened_at = os.time(),
      }
      M.sessions[session.id] = session
      table.insert(M.order, session.id)
      M.active = session.id
      emit("connect", session)
      emit("activate", session)
      if callback then
        callback(session, nil)
      end
    end, function(err)
      if callback then
        callback(nil, err)
      else
        vim.notify(("DBClient: could not connect to %s: %s"):format(name, err), vim.log.levels.ERROR)
      end
    end)
  end)
end

---@param name string
---@return table|nil
function M.find_by_name(name)
  for _, session in pairs(M.sessions) do
    if session.name == name then
      return session
    end
  end
end

--- Focus a session without reconnecting.
---@param id string
function M.activate(id)
  if not M.sessions[id] then
    return false
  end
  M.active = id
  emit("activate", M.sessions[id])
  return true
end

--- Close one session, or the active one when `id` is nil.
---@param id string|nil
function M.disconnect(id)
  local session = M.get(id)
  if not session then
    return
  end

  M.sessions[session.id] = nil
  M.order = vim.tbl_filter(function(entry)
    return entry ~= session.id
  end, M.order)
  if M.active == session.id then
    M.active = M.order[#M.order]
  end

  client.request("close-session", {}, session.id, function() end)
  emit("disconnect", session)
  if M.active then
    emit("activate", M.sessions[M.active])
  end
end

function M.disconnect_all()
  for _, id in ipairs(vim.deepcopy(M.order)) do
    M.disconnect(id)
  end
end

--- Ask the core to cancel whatever the session is running.
---@param id string|nil
function M.cancel(id)
  local session = M.get(id)
  if not session then
    return
  end
  client.request("cancel", {}, session.id, function(err, data)
    vim.schedule(function()
      if err then
        vim.notify("DBClient: " .. err, vim.log.levels.WARN)
      elseif data and data.cancelled then
        vim.notify("DBClient: statement cancelled", vim.log.levels.INFO)
      else
        vim.notify("DBClient: nothing to cancel", vim.log.levels.INFO)
      end
    end)
  end)
end

function M.invalidate(id)
  local session = M.get(id)
  if session then
    session.cache = empty_cache()
  end
end

--- Record an executed statement for `:DBClientLog` and the history picker.
---@param session table
---@param entry table
function M.record(session, entry)
  entry.session = session and session.name or "?"
  entry.at = os.time()
  table.insert(M.log, entry)
  local limit = config.get().log.limit
  while #M.log > limit do
    table.remove(M.log, 1)
  end
  emit("log", entry)
end

-- ---------------------------------------------------------------------------
-- Metadata accessors. Call these inside `client.async`.
-- ---------------------------------------------------------------------------

---@param id string|nil
---@param force boolean|nil
---@return table[]
function M.schemas(id, force)
  local session = M.require_session(id)
  if force or not session.cache.schemas then
    session.cache.schemas = client.call("schemas", {}, session.id)
  end
  return session.cache.schemas
end

function M.tables(id, schema, force)
  local session = M.require_session(id)
  if force or not session.cache.tables[schema] then
    session.cache.tables[schema] = client.call("tables", { schema = schema }, session.id)
  end
  return session.cache.tables[schema]
end

function M.columns(id, schema, table_name, force)
  local session = M.require_session(id)
  local key = schema .. "." .. table_name
  if force or not session.cache.columns[key] then
    session.cache.columns[key] =
      client.call("columns", { schema = schema, table = table_name }, session.id)
  end
  return session.cache.columns[key]
end

function M.routines(id, schema, force)
  local session = M.require_session(id)
  if force or not session.cache.routines[schema] then
    session.cache.routines[schema] = client.call("routines", { schema = schema }, session.id)
  end
  return session.cache.routines[schema]
end

function M.indexes(id, schema, table_name, force)
  local session = M.require_session(id)
  local key = schema .. "." .. table_name
  if force or not session.cache.indexes[key] then
    session.cache.indexes[key] =
      client.call("indexes", { schema = schema, table = table_name }, session.id)
  end
  return session.cache.indexes[key]
end

function M.foreign_keys(id, schema, table_name, force)
  local session = M.require_session(id)
  local key = schema .. "." .. table_name
  if force or not session.cache.foreign_keys[key] then
    session.cache.foreign_keys[key] =
      client.call("foreign-keys", { schema = schema, table = table_name }, session.id)
  end
  return session.cache.foreign_keys[key]
end

--- Every foreign key in a schema, in one round trip.
---
--- The per-table calls are fine for one table; asking for all of them was the
--- slowest thing the client did on a large schema by a factor of fifteen.
function M.schema_foreign_keys(id, schema, force)
  local target = M.require_session(id)
  target.cache.schema_keys = target.cache.schema_keys or {}
  if force or not target.cache.schema_keys[schema] then
    target.cache.schema_keys[schema] =
      client.call("schema-foreign-keys", { schema = schema }, target.id)
  end
  return target.cache.schema_keys[schema]
end

function M.referencing_keys(id, schema, table_name, force)
  local session = M.require_session(id)
  local key = schema .. "." .. table_name
  if force or not session.cache.referencing[key] then
    session.cache.referencing[key] =
      client.call("referencing-keys", { schema = schema, table = table_name }, session.id)
  end
  return session.cache.referencing[key]
end

function M.preview(id, params)
  local session = M.require_session(id)
  return client.call("preview", params, session.id)
end

function M.count(id, params)
  local session = M.require_session(id)
  return client.call("count", params, session.id).count
end

--- Execute one statement and log it.
---@param id string|nil
---@param sql string
---@param limit integer|nil
function M.query(id, sql, limit)
  local session = M.require_session(id)
  local started = vim.uv.hrtime()
  local ok, result = pcall(client.call, "query", { sql = sql, limit = limit }, session.id)
  local elapsed = (vim.uv.hrtime() - started) / 1e6

  M.record(session, {
    sql = sql,
    ok = ok,
    error = not ok and tostring(result) or nil,
    rows = ok and #(result.rows or {}) or 0,
    affected = ok and result.affected_rows or 0,
    elapsed_ms = ok and result.elapsed_ms or math.floor(elapsed),
  })

  if not ok then
    error(result, 0)
  end
  return result
end

function M.apply_changes(id, changes)
  local session = M.require_session(id)
  return client.call("apply-changes", { changes = changes }, session.id)
end

function M.begin(id)
  local session = M.require_session(id)
  client.call("begin", {}, session.id)
  session.in_transaction = true
  emit("transaction", session)
  return session
end

function M.commit(id)
  local session = M.require_session(id)
  client.call("commit", {}, session.id)
  session.in_transaction = false
  emit("transaction", session)
  return session
end

function M.rollback(id)
  local session = M.require_session(id)
  client.call("rollback", {}, session.id)
  session.in_transaction = false
  emit("transaction", session)
  return session
end

function M.ddl(id, kind, schema, name)
  local session = M.require_session(id)
  return client.call("ddl", { kind = kind, schema = schema, name = name }, session.id).ddl
end

function M.explain(id, sql, analyze)
  local session = M.require_session(id)
  return client.call("explain", { sql = sql, analyze = analyze }, session.id)
end

function M.column_stats(id, schema, table_name, column)
  local session = M.require_session(id)
  return client.call(
    "column-stats",
    { schema = schema, table = table_name, column = column },
    session.id
  )
end

function M.activity(id)
  local session = M.require_session(id)
  return client.call("activity", {}, session.id)
end

function M.locks(id)
  local session = M.require_session(id)
  return client.call("locks", {}, session.id)
end

function M.table_sizes(id, schema)
  local session = M.require_session(id)
  return client.call("table-sizes", { schema = schema }, session.id)
end

function M.unused_indexes(id, schema)
  local session = M.require_session(id)
  return client.call("unused-indexes", { schema = schema }, session.id)
end

--- Look up the primary key columns of a table from the cached metadata.
---@return string[]
function M.primary_key(id, schema, table_name)
  local primary = {}
  for _, column in ipairs(M.columns(id, schema, table_name)) do
    if column.key == "PRI" then
      table.insert(primary, column.name)
    end
  end
  return primary
end

return M

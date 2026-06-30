local adapters = require("dbclient.adapters")
local config = require("dbclient.config")

local M = {
  active_name = nil,
  active_handle = nil,
  active_adapter = nil,
  cache = {
    schemas = nil,
    tables = {},
    columns = {},
  },
}

local function connection_named(name)
  local connection = config.get().connections[name]
  if not connection then
    error("unknown DBClient connection: " .. name)
  end
  return connection
end

function M.connection_names()
  local names = vim.tbl_keys(config.get().connections)
  table.sort(names)
  return names
end

function M.connect(name)
  M.close()

  local connection = connection_named(name)
  local adapter = adapters.get(connection.adapter or "mariadb")

  M.active_name = name
  M.active_adapter = adapter
  M.active_handle = adapter.connect(connection, config.get())
  M.cache = { schemas = nil, tables = {}, columns = {} }
  return M.active_handle
end

function M.ensure_connected()
  if not M.active_handle then
    local names = M.connection_names()
    if #names == 0 then
      error("no DBClient connections configured")
    end
    M.connect(names[1])
  end
  return M.active_adapter, M.active_handle
end

function M.close()
  if M.active_adapter and M.active_handle then
    pcall(M.active_adapter.close, M.active_handle)
  end
  M.active_name = nil
  M.active_handle = nil
  M.active_adapter = nil
  M.cache = { schemas = nil, tables = {}, columns = {} }
end

function M.invalidate()
  M.cache = { schemas = nil, tables = {}, columns = {} }
end

function M.schemas(force)
  local adapter, handle = M.ensure_connected()
  if force or not M.cache.schemas then
    M.cache.schemas = adapter.schemas(handle)
  end
  return M.cache.schemas
end

function M.tables(schema, force)
  local adapter, handle = M.ensure_connected()
  if force or not M.cache.tables[schema] then
    M.cache.tables[schema] = adapter.tables(handle, schema)
  end
  return M.cache.tables[schema]
end

function M.columns(schema, table_name, force)
  local adapter, handle = M.ensure_connected()
  local key = schema .. "." .. table_name
  if force or not M.cache.columns[key] then
    M.cache.columns[key] = adapter.columns(handle, schema, table_name)
  end
  return M.cache.columns[key]
end

function M.query(sql)
  local adapter, handle = M.ensure_connected()
  return adapter.query(handle, sql)
end

return M

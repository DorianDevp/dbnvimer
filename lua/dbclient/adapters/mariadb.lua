local core = require("dbclient.core.command")

local M = {}

local function core_connection(connection)
  return {
    host = connection.host,
    port = connection.port or 3306,
    user = connection.user,
    password = connection.password,
    database = connection.database,
  }
end

local function tunnel_connection(connection, tunnel)
  local copy = vim.deepcopy(connection)
  copy.host = tunnel.local_host
  copy.port = tunnel.local_port
  return copy
end

function M.connect(connection)
  local tunnel = nil
  local effective = vim.deepcopy(connection)

  if connection.ssh then
    tunnel = core.run("tunnel-open", { ssh = connection.ssh })
    effective = tunnel_connection(connection, tunnel)
  end

  return {
    adapter = "mariadb",
    connection = effective,
    tunnel = tunnel,
  }
end

function M.close(handle)
  if handle and handle.tunnel then
    core.run("tunnel-close", { tunnel = handle.tunnel })
  end
end

function M.schemas(handle)
  return core.run("schemas", {
    connection = core_connection(handle.connection),
  })
end

function M.tables(handle, schema)
  return core.run("tables", {
    connection = core_connection(handle.connection),
    schema = schema,
  })
end

function M.columns(handle, schema, table_name)
  return core.run("columns", {
    connection = core_connection(handle.connection),
    schema = schema,
    table = table_name,
  })
end

function M.query(handle, sql)
  return core.run("query", {
    connection = core_connection(handle.connection),
    sql = sql,
  })
end

return M

local core = require("dbclient.core.command")

local M = {}

local function core_connection(connection)
  return {
    adapter = "mariadb",
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
    adapter = "mariadb",
    connection = core_connection(handle.connection),
  })
end

function M.tables(handle, schema)
  return core.run("tables", {
    adapter = "mariadb",
    connection = core_connection(handle.connection),
    schema = schema,
  })
end

function M.columns(handle, schema, table_name)
  return core.run("columns", {
    adapter = "mariadb",
    connection = core_connection(handle.connection),
    schema = schema,
    table = table_name,
  })
end

function M.routines(handle, schema)
  return core.run("routines", {
    adapter = "mariadb",
    connection = core_connection(handle.connection),
    schema = schema,
  })
end

function M.preview(handle, schema, table_name, limit)
  return core.run("preview", {
    adapter = "mariadb",
    connection = core_connection(handle.connection),
    schema = schema,
    table = table_name,
    limit = limit,
  })
end

function M.update_cell(handle, schema, table_name, column, value, pk)
  return core.run("update-cell", {
    adapter = "mariadb",
    connection = core_connection(handle.connection),
    schema = schema,
    table = table_name,
    column = column,
    value = value,
    pk = pk,
  })
end

function M.update_cells(handle, updates)
  return core.run("update-cells", {
    adapter = "mariadb",
    connection = core_connection(handle.connection),
    updates = updates,
  })
end

function M.query(handle, sql)
  return core.run("query", {
    adapter = "mariadb",
    connection = core_connection(handle.connection),
    sql = sql,
  })
end

return M

local core = require("dbclient.core.command")

local M = {}

local function core_connection(connection)
  return {
    host = "",
    port = 0,
    user = "",
    database = connection.database or connection.path,
    path = connection.path or connection.database,
  }
end

function M.connect(connection)
  return {
    adapter = "sqlite",
    connection = vim.deepcopy(connection),
  }
end

function M.close(_) end

function M.schemas(handle)
  return core.run("schemas", {
    adapter = "sqlite",
    connection = core_connection(handle.connection),
  })
end

function M.tables(handle, schema)
  return core.run("tables", {
    adapter = "sqlite",
    connection = core_connection(handle.connection),
    schema = schema,
  })
end

function M.columns(handle, schema, table_name)
  return core.run("columns", {
    adapter = "sqlite",
    connection = core_connection(handle.connection),
    schema = schema,
    table = table_name,
  })
end

function M.routines(handle, schema)
  return core.run("routines", {
    adapter = "sqlite",
    connection = core_connection(handle.connection),
    schema = schema,
  })
end

function M.preview(handle, schema, table_name, limit)
  return core.run("preview", {
    adapter = "sqlite",
    connection = core_connection(handle.connection),
    schema = schema,
    table = table_name,
    limit = limit,
  })
end

function M.update_cell(handle, schema, table_name, column, value, pk)
  return core.run("update-cell", {
    adapter = "sqlite",
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
    adapter = "sqlite",
    connection = core_connection(handle.connection),
    updates = updates,
  })
end

function M.query(handle, sql)
  return core.run("query", {
    adapter = "sqlite",
    connection = core_connection(handle.connection),
    sql = sql,
  })
end

return M

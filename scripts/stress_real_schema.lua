--- Drive every code path over a real schema and report what breaks.
---
---   DBCLIENT_STRESS="host=… port=… user=… password=… database=… adapter=mariadb" \
---     nvim --headless -u NONE -c "luafile scripts/stress_real_schema.lua"
---
--- Fixtures are written by the person writing the test, so they only contain
--- what that person thought of. A real schema contains what a decade of an
--- application actually did: fifty-six column tables, five column primary keys,
--- tables with no key at all, three collations, and no foreign keys anywhere.
--- This walks all of it and collects every failure rather than stopping at the
--- first, because the interesting output is the list.

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.columns = 200
vim.o.lines = 60

local core = vim.fn.getcwd() .. "/rust/dbclient-core/target/release/dbclient-core"
if vim.fn.executable(core) ~= 1 then
  print("dbclient-core is not built")
  vim.cmd("cquit 1")
end

local dsn = vim.env.DBCLIENT_STRESS
if not dsn then
  print("set DBCLIENT_STRESS to a connection string")
  vim.cmd("cquit 1")
end

local spec = { adapter = "mariadb" }
for key, value in dsn:gmatch("([%w_]+)=(%S+)") do
  if key == "port" then
    spec.port = tonumber(value)
  elseif key == "dbname" then
    spec.database = value
  else
    spec[key] = value
  end
end

local sandbox = vim.fn.tempname() .. "/dbclient"
vim.fn.mkdir(sandbox, "p")

require("dbclient").setup({
  core = { command = core },
  detect = { enabled = false },
  store = { enabled = false },
  -- Keep everything this writes out of the user's real data directory.
  history = { enabled = false, path = sandbox .. "/history.jsonl" },
  export = { dir = sandbox .. "/exports" },
  connections = { target = spec },
})

local client = require("dbclient.core.client")
local session = require("dbclient.session")

-- ---------------------------------------------------------------------------

local failures = {}
local timings = {}

local function record(what, err)
  table.insert(failures, { what = what, err = tostring(err) })
end

local function timed(label, fn)
  local started = vim.uv.hrtime()
  local ok, err = pcall(fn)
  local elapsed = (vim.uv.hrtime() - started) / 1e6
  table.insert(timings, { label = label, ms = elapsed })
  if not ok then
    record(label, err)
  end
  return ok
end

local function run(fn)
  local done, failure = false, nil
  client.async(function()
    fn()
    done = true
  end, function(err)
    failure = err
    done = true
  end)
  if not vim.wait(180000, function()
    return done
  end, 20) then
    return false, "timed out"
  end
  return failure == nil, failure
end

local function section(title)
  print("")
  print("── " .. title .. " " .. string.rep("─", math.max(0, 66 - #title)))
end

-- ---------------------------------------------------------------------------

local target
session.connect("target", function(result, err)
  target = result or err
end)
if not vim.wait(30000, function()
  return target ~= nil
end, 25) then
  print("connection timed out")
  vim.cmd("cquit 1")
end
if type(target) ~= "table" then
  print("could not connect: " .. tostring(target))
  vim.cmd("cquit 1")
end

section("server")
print(("  %s"):format(target.info.server_version))
print(("  database: %s"):format(target.info.database or "?"))

-- ---------------------------------------------------------------------------

local schema = spec.database
local tables = {}

section("metadata over the whole schema")

timed("list tables", function()
  local ok, err = run(function()
    tables = session.tables(target.id, schema)
  end)
  if not ok then
    error(err, 0)
  end
end)
print(("  %d tables"):format(#tables))

local wide, keyless, composite = nil, {}, {}
local column_total = 0

timed("columns for every table", function()
  local ok, err = run(function()
    for _, entry in ipairs(tables) do
      local columns_ok, columns = pcall(session.columns, target.id, schema, entry.name)
      if not columns_ok then
        record("columns " .. entry.name, columns)
      else
        column_total = column_total + #columns
        if not wide or #columns > wide.count then
          wide = { name = entry.name, count = #columns }
        end

        local primary = {}
        for _, column in ipairs(columns) do
          if column.key == "PRI" then
            table.insert(primary, column.name)
          end
        end
        if #primary == 0 then
          table.insert(keyless, entry.name)
        elseif #primary > 1 then
          table.insert(composite, { name = entry.name, key = primary })
        end
      end
    end
  end)
  if not ok then
    error(err, 0)
  end
end)
print(("  %d columns; widest is %s with %d"):format(column_total, wide.name, wide.count))
print(("  %d tables with no primary key, %d with a composite one"):format(#keyless, #composite))

timed("indexes for every table", function()
  local ok, err = run(function()
    for _, entry in ipairs(tables) do
      local indexes_ok, err_indexes = pcall(session.indexes, target.id, schema, entry.name)
      if not indexes_ok then
        record("indexes " .. entry.name, err_indexes)
      end
    end
  end)
  if not ok then
    error(err, 0)
  end
end)

timed("DDL for every table", function()
  local ok, err = run(function()
    for _, entry in ipairs(tables) do
      local kind = tostring(entry.kind):find("VIEW") and "view" or "table"
      local ddl_ok, ddl = pcall(session.ddl, target.id, kind, schema, entry.name)
      if not ddl_ok then
        record("ddl " .. entry.name, ddl)
      elseif not ddl:lower():find("create") then
        record("ddl " .. entry.name, "returned something that is not a CREATE statement")
      end
    end
  end)
  if not ok then
    error(err, 0)
  end
end)

-- Two ways of asking the same question, timed side by side: the per-table API
-- is what a single data buffer uses, and the schema-wide one is what anything
-- walking the whole graph should use.
timed("foreign keys: one query for the schema", function()
  local ok, err = run(function()
    local keys = session.schema_foreign_keys(target.id, schema, true)
    print(("  %d foreign keys in the schema"):format(#keys))
  end)
  if not ok then
    error(err, 0)
  end
end)

timed("foreign keys: per table, both directions (correctness sweep)", function()
  local ok, err = run(function()
    for _, entry in ipairs(tables) do
      local forward_ok, forward = pcall(session.foreign_keys, target.id, schema, entry.name)
      if not forward_ok then
        record("foreign_keys " .. entry.name, forward)
      end
      local reverse_ok, reverse = pcall(session.referencing_keys, target.id, schema, entry.name)
      if not reverse_ok then
        record("referencing_keys " .. entry.name, reverse)
      end
    end
  end)
  if not ok then
    error(err, 0)
  end
end)

-- ---------------------------------------------------------------------------

section("previewing every table")

local previewed, empty = 0, 0
timed("preview every table", function()
  local ok, err = run(function()
    for _, entry in ipairs(tables) do
      local preview_ok, result = pcall(session.preview, target.id, {
        schema = schema,
        table = entry.name,
        limit = 5,
      })
      if not preview_ok then
        record("preview " .. entry.name, result)
      else
        previewed = previewed + 1
        if #result.rows == 0 then
          empty = empty + 1
        end
      end
    end
  end)
  if not ok then
    error(err, 0)
  end
end)
print(("  %d previewed, %d of them empty"):format(previewed, empty))

-- ---------------------------------------------------------------------------

section("rendering the awkward tables")

local grid = require("dbclient.ui.grid")
local data = require("dbclient.ui.data")

local function open_and_check(name, label)
  local view
  data.open({ session_id = target.id, schema = schema, table = name, filter = "" })
  if not vim.wait(30000, function()
    for _, candidate in pairs(data.views) do
      if candidate.table == name and (candidate.generation or 0) > 0 then
        view = candidate
        return true
      end
    end
    return false
  end, 25) then
    record("render " .. name, "timed out")
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
  for index, line in ipairs(lines) do
    if line:find("\n") then
      record("render " .. name, ("line %d contains a raw newline"):format(index))
    end
  end

  -- Every data row must render to the same display width, or the columns have
  -- drifted apart somewhere.
  local widths = {}
  for index = data.HEADER_LINES + 1, #lines do
    table.insert(widths, vim.fn.strdisplaywidth(lines[index]))
  end
  for _, width in ipairs(widths) do
    if width ~= widths[1] then
      record("render " .. name, "rows do not line up")
      break
    end
  end

  -- The rendered row must parse back to the same number of cells.
  if #lines > data.HEADER_LINES and #view.columns > 0 then
    local cells = grid.parse_row(lines[data.HEADER_LINES + 1])
    if #cells ~= #view.columns then
      record(
        "render " .. name,
        ("parsed %d cells from a row of %d columns"):format(#cells, #view.columns)
      )
    end
  end

  print(("  %-28s %2d columns, %d row(s)  %s"):format(
    name,
    #view.columns,
    #view.rows,
    label or ""
  ))
  return view
end

open_and_check(wide.name, "widest table")
for index = 1, math.min(2, #composite) do
  open_and_check(
    composite[index].name,
    ("composite key: %s"):format(table.concat(composite[index].key, ", "))
  )
end
for index = 1, math.min(2, #keyless) do
  local view = open_and_check(keyless[index], "no primary key")
  if view and #view.primary > 0 then
    record("render " .. keyless[index], "reported a primary key it does not have")
  end
end

-- The biggest table, to see the grid handle a full page.
local biggest = nil
run(function()
  for _, entry in ipairs(tables) do
    local rows = tonumber(entry.estimated_rows) or 0
    if not biggest or rows > biggest.rows then
      biggest = { name = entry.name, rows = rows }
    end
  end
end)
if biggest then
  open_and_check(biggest.name, ("largest, ~%d rows"):format(biggest.rows))
end

-- ---------------------------------------------------------------------------

section("export")

local export_dir = vim.fn.tempname()
vim.fn.mkdir(export_dir, "p")

for _, format in ipairs({ "csv", "jsonl", "sql", "xlsx", "markdown" }) do
  timed("export " .. format, function()
    local ok, err = run(function()
      local outcome = client.call("export", {
        format = format,
        destination = ("%s/%s"):format(export_dir, biggest.name),
        schema = schema,
        table = biggest.name,
        limit = 5000,
        manifest = format == "csv",
        overwrite = true,
        sql_table = biggest.name,
      }, target.id)
      print(("  %-9s %6d rows  %8d bytes  %4d ms"):format(
        format,
        outcome.rows,
        outcome.files[1] and outcome.files[1].bytes or 0,
        outcome.elapsed_ms
      ))
    end)
    if not ok then
      error(err, 0)
    end
  end)
end

timed("export the whole biggest table, gzipped and partitioned", function()
  local ok, err = run(function()
    local outcome = client.call("export", {
      format = "csv",
      destination = export_dir .. "/chunks",
      schema = schema,
      table = biggest.name,
      partition_rows = 10000,
      compress = "gzip",
      manifest = false,
      overwrite = true,
    }, target.id)
    print(("  %d rows into %d gzipped file(s), %d ms"):format(
      outcome.rows,
      #outcome.files,
      outcome.elapsed_ms
    ))
  end)
  if not ok then
    error(err, 0)
  end
end)

-- ---------------------------------------------------------------------------

section("derived views")

timed("schema audit", function()
  local ok, err = run(function()
    local audit = require("dbclient.audit")
    local collected = audit.collect(target.id, schema)
    local findings = audit.analyse(collected)
    local counts = {}
    for _, finding in ipairs(findings) do
      counts[finding.code] = (counts[finding.code] or 0) + 1
    end
    local codes = vim.tbl_keys(counts)
    table.sort(codes)
    print(("  %d findings"):format(#findings))
    for _, code in ipairs(codes) do
      print(("    %-28s %d"):format(code, counts[code]))
    end
  end)
  if not ok then
    error(err, 0)
  end
end)

timed("completion index", function()
  local ok, err = run(function()
    local completion = require("dbclient.completion")
    completion.warm(target.id, { force = true, schemas = { schema } })
  end)
  if not ok then
    error(err, 0)
  end
  vim.wait(60000, function()
    local index = require("dbclient.completion").index[target.id]
    return index ~= nil and #index.tables > 0
  end, 50)
  local index = require("dbclient.completion").index[target.id]
  print(("  indexed %d tables"):format(index and #index.tables or 0))
end)

timed("column statistics on the widest table", function()
  local ok, err = run(function()
    local columns = session.columns(target.id, schema, wide.name)
    for index = 1, math.min(3, #columns) do
      local stats_ok, stats =
        pcall(session.column_stats, target.id, schema, wide.name, columns[index].name)
      if not stats_ok then
        record("column_stats " .. columns[index].name, stats)
      else
        print(("  %-24s %s rows, %s distinct"):format(
          columns[index].name,
          stats.total,
          stats.distinct
        ))
      end
    end
  end)
  if not ok then
    error(err, 0)
  end
end)

timed("join graph", function()
  local ok, err = run(function()
    local joins = require("dbclient.joins")
    local graph = joins.graph(target.id, schema)
    local edges = 0
    for _, list in pairs(graph.edges) do
      edges = edges + #list
    end
    print(("  %d tables, %d foreign key edges"):format(#graph.nodes, edges))
    if edges == 0 then
      print("  (this schema declares no foreign keys, so join paths cannot be derived)")
    end
  end)
  if not ok then
    error(err, 0)
  end
end)

timed("explain a real join", function()
  local ok, err = run(function()
    local plan = session.explain(
      target.id,
      ("select * from %s limit 10"):format(biggest.name),
      false
    )
    local lines = require("dbclient.ui.explain").render(plan)
    print(("  plan rendered in %d line(s)"):format(#lines))
  end)
  if not ok then
    error(err, 0)
  end
end)

-- ---------------------------------------------------------------------------

section("timings")
table.sort(timings, function(a, b)
  return a.ms > b.ms
end)
for index = 1, math.min(10, #timings) do
  print(("  %7.0f ms  %s"):format(timings[index].ms, timings[index].label))
end

section("failures")
if #failures == 0 then
  print("  none")
else
  local seen = {}
  for _, failure in ipairs(failures) do
    local key = failure.err:sub(1, 120)
    seen[key] = seen[key] or { count = 0, example = failure.what }
    seen[key].count = seen[key].count + 1
  end
  for message, entry in pairs(seen) do
    print(("  %dx  %s"):format(entry.count, entry.example))
    print(("       %s"):format(message))
  end
end

print("")
print(("%d failure(s)"):format(#failures))

session.disconnect_all()
client.stop()
vim.cmd(#failures == 0 and "cquit 0" or "cquit 1")

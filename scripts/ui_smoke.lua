--- Drive the real UI in headless Neovim and print what each buffer looks like.
---
---   nvim --headless -u NONE -c "luafile scripts/ui_smoke.lua"
---
--- This exercises the paths a user actually takes — commands and mappings, not
--- internal functions — and prints the rendered buffers so a change in
--- appearance is visible in a diff.

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.columns = 120
vim.o.lines = 40

local core = vim.fn.getcwd() .. "/rust/dbclient-core/target/release/dbclient-core"
if vim.fn.executable(core) ~= 1 then
  print("dbclient-core is not built; run cargo build --release first")
  vim.cmd("cquit 1")
end

local workdir = vim.fn.tempname()
vim.fn.mkdir(workdir, "p")
local db = workdir .. "/shop.db"

vim.system({ "sqlite3", db }, {
  stdin = [[
create table customers (
  id integer primary key,
  name text not null,
  city text,
  balance real,
  note text
);
insert into customers values
  (1, 'Łódź Sp. z o.o.', 'PL', 1250.5, NULL),
  (2, 'NULL', 'DE', -13.25, 'literal null string'),
  (3, 'Kraków Trading', 'PL', 0.0, 'has | a pipe'),
  (4, 'Gdańsk Logistics', NULL, 99999.99, 'two
lines');
create table orders (
  id integer primary key,
  customer_id integer references customers(id),
  total real,
  placed_at text
);
insert into orders values
  (10, 1, 99.5, '2026-01-04'),
  (11, 1, 10.0, '2026-02-11'),
  (12, 3, 5.25, '2026-03-02');
]],
  text = true,
}):wait()

require("dbclient").setup({
  core = { command = core },
  detect = { enabled = false },
  store = { enabled = false },
  history = { enabled = false, path = workdir .. "/history.jsonl" },
  connections = {
    shop = { adapter = "sqlite", path = db, color = "green" },
    shop_prod = { adapter = "sqlite", path = db, color = "red", access = "read" },
  },
})

local function wait(predicate, label)
  if not vim.wait(8000, predicate, 25) then
    print("TIMEOUT waiting for " .. label)
    vim.cmd("cquit 1")
  end
end

local function dump(title, bufnr, limit)
  print("")
  print("── " .. title .. " " .. string.rep("─", math.max(0, 70 - #title)))
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, limit or 40, false)
  for _, line in ipairs(lines) do
    print("  " .. line)
  end
end

local session = require("dbclient.session")
local sidebar = require("dbclient.ui.sidebar")
local data = require("dbclient.ui.data")
local results = require("dbclient.ui.results")

-- 1. Sidebar before connecting.
vim.cmd("DBClient")
wait(function()
  return sidebar.bufnr and #vim.api.nvim_buf_get_lines(sidebar.bufnr, 0, -1, false) > 1
end, "sidebar")
dump("sidebar (nothing connected)", sidebar.bufnr)

-- 2. Connect and expand.
vim.cmd("DBClientConnect shop")
wait(function()
  return session.find_by_name("shop") ~= nil
end, "connection")

local target = session.find_by_name("shop")
sidebar.expanded["connection:shop"] = true
sidebar.expanded["connection:shop:schema:main"] = true
sidebar.render()
wait(function()
  local lines = vim.api.nvim_buf_get_lines(sidebar.bufnr, 0, -1, false)
  return #lines > 3
end, "sidebar tree")
dump("sidebar (connected, schema expanded)", sidebar.bufnr)

-- 3. Data buffer.
vim.cmd("DBClientData main.customers")
local view
wait(function()
  for _, candidate in pairs(data.views) do
    if candidate.table == "customers" and (candidate.generation or 0) > 0 then
      view = candidate
      return true
    end
  end
end, "data buffer")
dump("data buffer", view.bufnr)

print("")
print("  winbar: " .. require("dbclient.ui.winbar").render(view.bufnr))
print("  statusline: " .. require("dbclient").statusline())

-- 4. Edit a cell the way a user would, then look at the pending change set.
local line_number = data.HEADER_LINES + 1
local line = vim.api.nvim_buf_get_lines(view.bufnr, line_number - 1, line_number, false)[1]
vim.api.nvim_buf_set_lines(view.bufnr, line_number - 1, line_number, false, {
  (line:gsub("PL", "CZ", 1)),
})
local pending = data.pending(view)
dump_lines = require("dbclient.data.diff").describe(pending, "main.customers")
print("")
print("── pending changes " .. string.rep("─", 53))
for _, text in ipairs(dump_lines) do
  print("  " .. text)
end

-- 5. Query buffer and results.
vim.cmd("edit! " .. workdir .. "/scratch.sql")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "-- @conn: shop",
  "select c.name, count(o.id) as orders, sum(o.total) as revenue",
  "from customers c left join orders o on o.customer_id = c.id",
  "group by c.name",
  "order by revenue desc nulls last;",
})
local query = require("dbclient.ui.query")
query.buffers[vim.api.nvim_get_current_buf()] = { session_id = target.id }
query.attach(vim.api.nvim_get_current_buf())
vim.api.nvim_win_set_cursor(0, { 2, 0 })
query.execute()
wait(function()
  local bufnr = vim.fn.bufnr("dbclient://results")
  return bufnr > 0 and #vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) > 3
end, "results")
dump("query results", vim.fn.bufnr("dbclient://results"))

-- 6. Value inspector on a NULL and on a multi-line value.
local value = require("dbclient.ui.value")
print("")
print("── value decode ".. string.rep("─", 56))
print("  json:      " .. vim.inspect(value.decode('{"a":1}').kind))
print("  timestamp: " .. table.concat(value.decode("1767225600").lines, " | "))

-- 7. Explain.
local explain = require("dbclient.ui.explain")
local plan
require("dbclient.core.client").async(function()
  plan = session.explain(target.id, "select * from customers where city = 'PL'", false)
end)
wait(function()
  return plan ~= nil
end, "plan")
print("")
print("── query plan " .. string.rep("─", 58))
for _, text in ipairs(explain.render(plan)) do
  print("  " .. text)
end

-- 8. Help popup content.
print("")
print("── g? in a data buffer " .. string.rep("─", 49))
for _, text in ipairs(require("dbclient.keymap").help_lines("data")) do
  print("  " .. text)
end

-- 8b. Relation walking, the trail and the quick query tab.
local trail = require("dbclient.trail")
trail.clear()
vim.cmd("DBClientData main.customers")
wait(function()
  return trail.current() and trail.current().table == "customers"
end, "first place")
vim.cmd("DBClientData main.orders")
wait(function()
  return trail.current() and trail.current().table == "orders"
end, "second place")
require("dbclient.ui.data").open({
  session_id = target.id,
  schema = "main",
  table = "customers",
  filter = "id = 1",
  via = "orders.customer_id",
})
wait(function()
  return trail.current() and trail.current().filter == "id = 1"
end, "third place")

print("")
print("── trail " .. string.rep("─", 62))
print("  breadcrumb: " .. trail.breadcrumb())
for _, item in ipairs(trail.list()) do
  print("  " .. item.label)
end
print("  g[ cofa, g] do przodu, gb wybiera dowolny punkt")

local scratch = require("dbclient.ui.scratch")
local scratch_buf = scratch.open({ session_id = target.id, sql = "select city, count(*) from customers group by city;" })
dump("quick query tab", scratch_buf)
scratch.close(target.id)

local queries = require("dbclient.queries")
queries.save({ name = "customers by city", sql = "select city, count(*) from customers group by city;",
  connection = "shop", description = "how many per country", scope = "global" })
queries.save({ name = "recent orders", sql = "select * from orders order by placed_at desc limit 20;",
  connection = "shop", scope = "global" })
require("dbclient.ui.queries").open({ session_id = target.id })
dump("saved queries", vim.fn.bufnr("dbclient://queries"))
for _, entry in ipairs(queries.list()) do
  queries.delete(entry.path)
end

-- 8c. Blast radius, charts, the schema audit and the join builder.
local blast = require("dbclient.blast")
local report
require("dbclient.core.client").async(function()
  report = blast.inspect(target.id, "delete from customers where city = 'PL'")
end)
wait(function()
  return report ~= nil
end, "blast radius")

print("")
print("── blast radius " .. string.rep("─", 56))
for _, text in ipairs((blast.lines(report, {
  sql = "delete from customers where city = 'PL'",
  connection = "shop",
  warnings = {},
}))) do
  print("  " .. text)
end

local chart = require("dbclient.chart")
local chart_result
require("dbclient.core.client").async(function()
  chart_result = session.query(
    target.id,
    "select city, count(*) as customers, sum(balance) as balance from customers group by city order by balance desc"
  )
end)
wait(function()
  return chart_result ~= nil
end, "chart data")

print("")
print("── chart " .. string.rep("─", 62))
for _, text in ipairs((chart.render(chart_result, { width = 70 }))) do
  print("  " .. text)
end

local audit = require("dbclient.audit")
local audit_schema
require("dbclient.core.client").async(function()
  audit_schema = audit.collect(target.id, "main", { deep = true })
end)
wait(function()
  return audit_schema ~= nil
end, "audit")

print("")
print("── schema audit " .. string.rep("─", 56))
for _, text in ipairs((audit.report(audit_schema, audit.analyse(audit_schema)))) do
  print("  " .. text)
end

local joins = require("dbclient.joins")
local graph
require("dbclient.core.client").async(function()
  graph = joins.graph(target.id, "main")
end)
wait(function()
  return graph ~= nil
end, "join graph")

print("")
print("── join builder " .. string.rep("─", 56))
local paths = joins.paths(graph, "orders", "customers")
if #paths > 0 then
  print("  " .. joins.describe(paths[1], "orders"))
  for _, text in ipairs(joins.render(paths[1], { schema = "main", from = "orders" })) do
    print("  " .. text)
  end
else
  print("  (no path found)")
end

-- 8d. The export editor.
local export_spec = require("dbclient.export.spec")
local values = export_spec.apply_preset(export_spec.defaults(), "excel")
values.destination = "~/exports/customers.csv"
values.table = "customers"
values.schema = "main"

print("")
print("── export editor (excel preset applied) " .. string.rep("─", 31))
for _, text in ipairs(export_spec.render(values, { connection = "shop" })) do
  print("  " .. text)
end

print("")
print("── export presets " .. string.rep("─", 53))
for _, name in ipairs(export_spec.preset_names()) do
  print(("  %-14s %s"):format(name, export_spec.presets[name].label))
end

-- 9. Connection manager rendering.
vim.cmd("DBClientConnections")
local manager = vim.fn.bufnr("dbclient://connections")
dump("connection manager", manager)

-- 10. Codegen.
print("")
print("── generated Go struct " .. string.rep("─", 49))
require("dbclient.core.client").async(function()
  local columns = session.columns(target.id, "main", "customers")
  for _, text in ipairs(require("dbclient.codegen").templates.go({
    schema = "main",
    table = "customers",
    columns = columns,
  })) do
    print("  " .. text)
  end
end)
vim.wait(2000, function()
  return false
end, 50)

print("")
print("UI smoke run complete")
session.disconnect_all()
require("dbclient.core.client").stop()
vim.cmd("cquit 0")

--- Edit a real data buffer badly, and see what the client says before the
--- server is ever asked.
---
---   DBCLIENT_PROBE="adapter=… host=… …" \
---     nvim --headless -u NONE -c "luafile scripts/constraint_probe.lua"
---
--- The unit tests check the rules against metadata written by hand. This checks
--- them against metadata a real server produced, which is where a declared type
--- turns out to be spelled `int(10) unsigned` rather than `int unsigned`, and
--- where `tinyint(1)` turns out to be how a boolean arrives.
---
--- Then it does the thing that actually matters: types a bad value into the
--- buffer and asserts that `:w` refuses and marks the cell.

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.columns = 160
vim.o.lines = 50

local dsn = vim.env.DBCLIENT_PROBE or ""
local spec = { adapter = "mariadb", access = "write" }
for key, value in dsn:gmatch("([%w_]+)=(%S+)") do
  spec[key] = key == "port" and tonumber(value) or value
end

local sandbox = vim.fn.tempname() .. "/dbclient"
vim.fn.mkdir(sandbox, "p")

require("dbclient").setup({
  core = { command = vim.fn.getcwd() .. "/rust/dbclient-core/target/release/dbclient-core" },
  detect = { enabled = false },
  store = { enabled = false },
  history = { enabled = false, path = sandbox .. "/history.jsonl" },
  export = { dir = sandbox .. "/exports" },
  connections = { probe = spec },
})

local client = require("dbclient.core.client")
local session = require("dbclient.session")
local constraints = require("dbclient.constraints")
local data = require("dbclient.ui.data")

local target
session.connect("probe", function(result, err)
  target = result or err
end)
if
  not vim.wait(20000, function()
    return target ~= nil
  end, 25) or type(target) ~= "table"
then
  print("could not connect: " .. tostring(target))
  vim.cmd("cquit 1")
end

local schema = vim.env.DBCLIENT_SCHEMA or spec.database
local table_name = vim.env.DBCLIENT_TABLE or "inquiry"
local failures = {}

-- ---------------------------------------------------------------------------
-- What the server says the columns are
-- ---------------------------------------------------------------------------

local columns
local done = false
client.async(function()
  columns = session.columns(target.id, schema, table_name)
  done = true
end, function(err)
  print("could not read columns: " .. tostring(err))
  done = true
end)
vim.wait(20000, function()
  return done
end, 25)

if not columns then
  vim.cmd("cquit 1")
end

print("")
print(("── %s.%s as the server declares it "):format(schema, table_name) .. string.rep("─", 40))
print(("  %-10s %-34s %-10s %s"):format("column", "declared", "read as", "bounds"))
for _, column in ipairs(columns) do
  local parsed = constraints.parse(column)
  local bounds = ""
  if parsed.max_length then
    bounds = ("max %d"):format(parsed.max_length)
  elseif parsed.min then
    bounds = ("%s … %s"):format(parsed.min, parsed.max)
  elseif parsed.values and #parsed.values > 0 then
    bounds = table.concat(parsed.values, ", ")
  elseif parsed.precision then
    bounds = ("%d digits, %d decimal"):format(parsed.precision, parsed.scale)
  end
  print(("  %-10s %-34s %-10s %s"):format(column.name, column.type, parsed.kind, bounds))

  if parsed.kind == "other" then
    failures[#failures + 1] = ("%s: %s was not understood"):format(column.name, column.type)
  end
end

-- ---------------------------------------------------------------------------
-- Values the schema should reject
-- ---------------------------------------------------------------------------

print("")
print("── values checked against the real metadata " .. string.rep("─", 47))

local function column_named(name)
  for _, column in ipairs(columns) do
    if column.name == name then
      return column
    end
  end
end

for _, case in ipairs({
  { "label", "far too long for eight", true },
  { "label", "short", false },
  { "status", "aktywny", true },
  { "status", "open", false },
  { "priority", "40000", true },
  { "priority", "3", false },
  { "priority", "nonsense", true },
  { "total", "12.345", true },
  { "total", "12.34", false },
  { "active", "7", true },
  { "active", "1", false },
  { "due", "2026-02-30", true },
  { "due", "2026-08-15", false },
  { "payload", "{not json", true },
  { "payload", '{"a":1}', false },
  -- PostgreSQL has no unsigned integers, so a negative primary key is legal
  -- there and only MySQL should refuse it.
  { "id", "-1", spec.adapter ~= "postgres" },
  { "note", "Łódź", false },
}) do
  local name, value, should_fail = case[1], case[2], case[3]
  local column = column_named(name)
  if not column then
    failures[#failures + 1] = "no column named " .. name
  else
    local problem = constraints.check(value, column)
    local verdict = problem and ("✗ " .. problem.message) or "ok"
    print(("  %-10s %-24s %s"):format(name, ("%q"):format(value), verdict))
    if should_fail and not problem then
      failures[#failures + 1] = ("%s = %q should have been refused"):format(name, value)
    elseif not should_fail and problem then
      failures[#failures + 1] =
        ("%s = %q was refused: %s"):format(name, value, problem.message)
    end
  end
end

-- ---------------------------------------------------------------------------
-- The buffer refuses to write
-- ---------------------------------------------------------------------------

print("")
print("── editing the buffer badly " .. string.rep("─", 63))

data.open({ session_id = target.id, schema = schema, table = table_name, filter = "" })
local view
if
  not vim.wait(30000, function()
    for _, candidate in pairs(data.views) do
      if candidate.table == table_name and (candidate.generation or 0) > 0 then
        view = candidate
        return true
      end
    end
    return false
  end, 25)
then
  print("  the data buffer did not render")
  vim.cmd("cquit 1")
end

--- Replace several cells of the first row at once.
---
--- All in one pass, and unpadded. Editing by span twice in a row would use
--- offsets from before the first edit, and padding to the rendered width would
--- truncate a longer value with an ellipsis — which the diff correctly refuses
--- to treat as an edit at all. Splitting and rejoining is what a user typing in
--- the grid actually produces.
local function set_cells(values)
  local grid = require("dbclient.ui.grid")
  local line_number = data.HEADER_LINES + 1
  local text = vim.api.nvim_buf_get_lines(view.bufnr, line_number - 1, line_number, false)[1]
  local cells = grid.parse_row(text)

  for position, column in ipairs(view.columns) do
    if values[column.name] then
      cells[position] = grid.escape(values[column.name])
    end
  end

  vim.api.nvim_buf_set_lines(view.bufnr, line_number - 1, line_number, false, {
    table.concat(cells, grid.SEPARATOR),
  })
end

vim.api.nvim_set_current_buf(view.bufnr)
set_cells({ status = "aktywny", priority = "40000" })

local findings = data.validate(view)
print(("  %d finding(s) from two bad cells"):format(#findings))
for _, finding in ipairs(findings) do
  print(("    line %s, column %-10s %s"):format(
    tostring(finding.line),
    finding.column,
    finding.message
  ))
end
if #findings ~= 2 then
  failures[#failures + 1] = ("expected 2 findings, got %d"):format(#findings)
end

local placed = vim.diagnostic.get(view.bufnr)
local marked = 0
for _, entry in ipairs(placed) do
  if entry.source == "dbclient" then
    marked = marked + 1
  end
end
print(("  %d diagnostic(s) placed on the cells"):format(marked))
if marked < 2 then
  failures[#failures + 1] = "the findings were not placed in the buffer"
end

-- And the write is refused rather than sent.
local before
client.async(function()
  before = session.query(target.id, ("select status, priority from %s"):format(table_name))
end)
vim.wait(10000, function()
  return before ~= nil
end, 25)

data.write()
vim.wait(1500, function()
  return false
end, 50)

local after
client.async(function()
  after = session.query(target.id, ("select status, priority from %s"):format(table_name))
end)
vim.wait(10000, function()
  return after ~= nil
end, 25)

local unchanged = vim.deep_equal(before and before.rows, after and after.rows)
print(("  the row is unchanged after `:w`: %s"):format(tostring(unchanged)))
if not unchanged then
  failures[#failures + 1] = "the write went through despite the findings"
end

print("")
if #failures == 0 then
  print("every declared constraint understood, and the bad write refused")
else
  print(("%d problem(s):"):format(#failures))
  for _, entry in ipairs(failures) do
    print("  " .. entry)
  end
end

session.disconnect_all()
client.stop()
vim.cmd(#failures == 0 and "cquit 0" or "cquit 1")

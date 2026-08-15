--- Exercise the relation-following features against a real relational schema.
---
---   DBCLIENT_PROBE="host=… port=… user=… password=… database=…" \
---     nvim --headless -u NONE -c "luafile scripts/relational_probe.lua"
---
--- The stress script walks every table; this one walks the *edges*, which is
--- the half that a schema without foreign keys cannot test at all.

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.columns = 190
vim.o.lines = 60

local core = vim.fn.getcwd() .. "/rust/dbclient-core/target/release/dbclient-core"
local dsn = vim.env.DBCLIENT_PROBE or ""
local spec = { adapter = "mariadb", access = "read" }
for key, value in dsn:gmatch("([%w_]+)=(%S+)") do
  if key == "port" then
    spec.port = tonumber(value)
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
  connections = { probe = spec },
})

local client = require("dbclient.core.client")
local session = require("dbclient.session")
local schema = spec.database

local target
session.connect("probe", function(result, err)
  target = result or err
end)
if not vim.wait(20000, function()
  return target ~= nil
end, 25) or type(target) ~= "table" then
  print("could not connect: " .. tostring(target))
  vim.cmd("cquit 1")
end

local failures = 0
local function run(label, fn)
  local done, failure = false, nil
  client.async(function()
    fn()
    done = true
  end, function(err)
    failure = err
    done = true
  end)
  if not vim.wait(120000, function()
    return done
  end, 25) then
    failure = "timed out"
  end
  if failure then
    failures = failures + 1
    print(("  ERROR in %s: %s"):format(label, failure))
  end
end

local function section(title)
  print("")
  print("── " .. title .. " " .. string.rep("─", math.max(0, 62 - #title)))
end

-- ---------------------------------------------------------------------------

section("read-only enforcement")
run("read-only", function()
  local ok = pcall(session.query, target.id, "delete from inquiry where id = 1")
  print("  a delete on a read-only connection is refused: " .. tostring(not ok))
end)

section("foreign keys, one query for the whole schema")
run("schema keys", function()
  local started = vim.uv.hrtime()
  local keys = session.schema_foreign_keys(target.id, schema, true)
  print(("  %d foreign keys in %.0f ms"):format(#keys, (vim.uv.hrtime() - started) / 1e6))
end)

section("join paths")
run("joins", function()
  local joins = require("dbclient.joins")
  joins.invalidate()
  local started = vim.uv.hrtime()
  local graph = joins.graph(target.id, schema)
  local edges = 0
  for _, list in pairs(graph.edges) do
    edges = edges + #list
  end
  print(("  graph: %d tables, %d edges, built in %.0f ms"):format(
    #graph.nodes,
    edges,
    (vim.uv.hrtime() - started) / 1e6
  ))

  for _, pair in ipairs({
    { "inquiry", "address" },
    { "inquiry", "manufacturer" },
    { "device", "address" },
  }) do
    local paths = joins.paths(graph, pair[1], pair[2])
    if #paths == 0 then
      print(("  %s → %s: no path"):format(pair[1], pair[2]))
    else
      print("  " .. joins.describe(paths[1], pair[1]))
      if pair[1] == "inquiry" and pair[2] == "address" then
        for _, line in ipairs(joins.render(paths[1], { schema = schema, from = pair[1] })) do
          print("      " .. line)
        end
      end
    end
  end
end)

section("fixture with the foreign key closure")
run("fixture", function()
  local fixture = require("dbclient.fixture")
  local collected = fixture.collect({
    session_id = target.id,
    schema = schema,
    table = "inquiry",
    pk = { id = "1" },
  })
  print(("  %d rows across %d tables"):format(collected.count, #collected.order))
  print("  order: " .. table.concat(collected.order, " → "))

  local lines = fixture.render({
    session_id = target.id,
    collected = collected,
    connection = "probe",
  })
  local shown = 0
  for _, line in ipairs(lines) do
    if line:match("^insert") then
      print("  " .. line:sub(1, 150))
      shown = shown + 1
      if shown >= 3 then
        break
      end
    end
  end
end)

section("data buffer and following a key")
local data = require("dbclient.ui.data")
data.open({ session_id = target.id, schema = schema, table = "inquiry", filter = "" })
local view
if not vim.wait(30000, function()
  for _, candidate in pairs(data.views) do
    if candidate.table == "inquiry" and (candidate.generation or 0) > 0 then
      view = candidate
      return true
    end
  end
  return false
end, 25) then
  failures = failures + 1
  print("  ERROR: the data buffer did not render")
else
  local keys = 0
  for _ in pairs(view.fk) do
    keys = keys + 1
  end
  print(("  %d columns, %d of them foreign keys, %d row(s)"):format(
    #view.columns,
    keys,
    #view.rows
  ))

  local index_of
  for index, column in ipairs(view.columns) do
    if column.name == "user_id" then
      index_of = index
    end
  end

  if index_of and #view.rows > 0 then
    local trail = require("dbclient.trail")
    trail.clear()
    trail.push({
      session_id = target.id,
      connection = target.name,
      schema = schema,
      table = "inquiry",
    })

    vim.api.nvim_win_set_cursor(0, { data.HEADER_LINES + 1, view.spans[index_of].start })
    data.follow_fk()
    vim.wait(20000, function()
      return trail.current() and trail.current().table == "user"
    end, 25)

    print("  gd on user_id landed on: " .. tostring(trail.current() and trail.current().table))
    print("  trail: " .. trail.breadcrumb())

    trail.back(1)
    vim.wait(5000, function()
      return not trail.restoring
    end, 25)
    print("  g[ went back to: " .. tostring(trail.current() and trail.current().table))
  end
end

print("")
print(("%d failure(s)"):format(failures))
session.disconnect_all()
client.stop()
vim.cmd(failures == 0 and "cquit 0" or "cquit 1")

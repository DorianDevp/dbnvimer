--- Build the record view for real rows and print what it would show.
---
---   DBCLIENT_PROBE="host=… port=… user=… password=… database=…" \
---     nvim --headless -u NONE -c "luafile scripts/record_probe.lua"
---
--- The interesting row is not the well-connected one, it is the *hub*: `user`
--- here has 23 things pointing at it, and a record page that costs one query
--- per incoming key is a record page nobody waits for. The probe counts the
--- round trips as well as the milliseconds.
---
--- Read-only.

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.columns = 180
vim.o.lines = 60

local dsn = vim.env.DBCLIENT_PROBE or ""
local spec = { adapter = "mariadb", access = "read" }
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
local neighbourhood = require("dbclient.neighbourhood")

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
local failures = {}

--- Count the requests a block of work costs.
local queries = 0
local original = client.request
client.request = function(...)
  queries = queries + 1
  return original(...)
end

local function show(table_name, pk, opts)
  opts = opts or {}
  local done, gathered, failure = false, nil, nil
  queries = 0
  local started = vim.uv.hrtime()

  client.async(function()
    gathered = neighbourhood.gather({
      session_id = target.id,
      schema = schema,
      table = table_name,
      pk = pk,
    })
    done = true
  end, function(err)
    failure, done = err, true
  end)
  vim.wait(60000, function()
    return done
  end, 25)

  local elapsed = (vim.uv.hrtime() - started) / 1e6
  print("")
  print(("── %s %s "):format(table_name, vim.inspect(pk):gsub("%s+", " "))
    .. string.rep("─", 40))

  if failure then
    table.insert(failures, ("%s: %s"):format(table_name, failure))
    print("  ERROR: " .. tostring(failure))
    return
  end

  print(("  %d parent(s), %d related table(s) — %d quer%s, %.0f ms"):format(
    #gathered.parents,
    #gathered.children,
    queries,
    queries == 1 and "y" or "ies",
    elapsed
  ))

  if opts.max_queries and queries > opts.max_queries then
    table.insert(
      failures,
      ("%s cost %d queries, more than the %d it should"):format(
        table_name,
        queries,
        opts.max_queries
      )
    )
  end

  local lines = neighbourhood.render(gathered)
  for index, line in ipairs(lines) do
    if index <= (opts.lines or 40) then
      print("  " .. line)
    end
  end
  if #lines > (opts.lines or 40) then
    print(("  … %d more line(s)"):format(#lines - (opts.lines or 40)))
  end

  -- Folds have to actually fold: every section line opens one and its body
  -- belongs to it, or `zo` does nothing and the page is a wall.
  local opens, bodies = 0, 0
  for _, line in ipairs(lines) do
    local level = neighbourhood.fold_level(line)
    if level == ">1" then
      opens = opens + 1
    elseif level == "1" then
      bodies = bodies + 1
    end
  end
  local sections = #gathered.parents + #gathered.children
  if opens ~= sections then
    table.insert(
      failures,
      ("%s: %d fold(s) for %d section(s)"):format(table_name, opens, sections)
    )
  end
  if sections > 0 and bodies == 0 then
    table.insert(failures, table_name .. ": folds have no body to hide")
  end
end

-- ---------------------------------------------------------------------------

local first = {}
local done = false
client.async(function()
  for _, name in ipairs({ "inquiry", "user", "address" }) do
    local rows = session.query(
      target.id,
      ("select id from %s.%s order by id limit 1"):format(schema, name)
    )
    first[name] = rows.rows[1] and tostring(rows.rows[1][1])
  end
  done = true
end, function(err)
  print("could not pick rows: " .. tostring(err))
  done = true
end)
vim.wait(30000, function()
  return done
end, 25)

if first.inquiry then
  -- Ten outgoing keys and a handful of children.
  show("inquiry", { id = first.inquiry }, { lines = 46, max_queries = 30 })
end
if first.user then
  -- The hub: 23 incoming keys. One `union all` should cover all of them.
  show("user", { id = first.user }, { lines = 26, max_queries = 40 })
end
if first.address then
  -- A leaf with no outgoing keys at all, which should still render.
  show("address", { id = first.address }, { lines = 20, max_queries = 20 })
end

print("")
if #failures == 0 then
  print("every record assembled, folded and paid for")
else
  print(("%d problem(s):"):format(#failures))
  for _, entry in ipairs(failures) do
    print("  " .. entry)
  end
end

session.disconnect_all()
client.stop()
vim.cmd(#failures == 0 and "cquit 0" or "cquit 1")

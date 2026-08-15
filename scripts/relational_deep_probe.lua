--- Walk a real relational schema in every direction, with real data in it.
---
---   DBCLIENT_PROBE="host=… port=… user=… password=… database=…" \
---     nvim --headless -u NONE -c "luafile scripts/relational_deep_probe.lua"
---
--- `relational_probe.lua` checks that the relation features work at all. This
--- one is about the shapes a hand-made fixture never has: a table with 23
--- things pointing at it, chains four joins long, cycles between tables, rows
--- whose foreign keys are null, and a fixture pulled from the most connected
--- row in the database.
---
--- Read-only by construction.

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.columns = 200
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

local schema = spec.database
local failures = {}

local function run(label, fn)
  local done, failure = false, nil
  client.async(function()
    fn()
    done = true
  end, function(err)
    failure, done = err, true
  end)
  if
    not vim.wait(120000, function()
      return done
    end, 25)
  then
    failure = "timed out"
  end
  if failure then
    table.insert(failures, ("%s: %s"):format(label, failure))
    print(("  ERROR in %s: %s"):format(label, failure))
  end
end

local function section(title)
  print("")
  print("── " .. title .. " " .. string.rep("─", math.max(0, 74 - #title)))
end

-- ---------------------------------------------------------------------------

section("the shape of the graph")

local joins = require("dbclient.joins")
local graph
run("graph", function()
  joins.invalidate()
  local started = vim.uv.hrtime()
  graph = joins.graph(target.id, schema)
  local edges = 0
  for _, list in pairs(graph.edges) do
    edges = edges + #list
  end
  print(("  %d tables, %d edges, %.1f ms"):format(
    #graph.nodes,
    edges,
    (vim.uv.hrtime() - started) / 1e6
  ))

  -- Degree, so the interesting rows can be picked rather than guessed at.
  -- Forward edges only: the graph carries each key twice so a path search can
  -- travel either way, and counting both would make every table look popular.
  local incoming = {}
  for _, list in pairs(graph.edges) do
    for _, edge in ipairs(list) do
      if not edge.reverse then
        incoming[edge.to] = (incoming[edge.to] or 0) + 1
      end
    end
  end
  local ranked = {}
  for name, count in pairs(incoming) do
    table.insert(ranked, { name = name, count = count })
  end
  table.sort(ranked, function(a, b)
    return a.count > b.count
  end)
  print("  most pointed at: ")
  for index = 1, math.min(5, #ranked) do
    print(("    %-24s %d"):format(ranked[index].name, ranked[index].count))
  end
end)

-- ---------------------------------------------------------------------------

section("cycles, which a fixture has to survive")

run("cycles", function()
  -- A fixture orders tables by dependency; a cycle has no valid order, so it
  -- must be detected rather than looped over.
  local visiting, done_with, cycles = {}, {}, {}
  local function walk(node, path)
    if visiting[node] then
      local at = 1
      for index, name in ipairs(path) do
        if name == node then
          at = index
          break
        end
      end
      table.insert(cycles, table.concat(vim.list_slice(path, at), " → ") .. " → " .. node)
      return
    end
    if done_with[node] then
      return
    end
    visiting[node] = true
    table.insert(path, node)
    for _, edge in ipairs(graph.edges[node] or {}) do
      -- Forward edges only. Following the reverse ones makes every pair of
      -- related tables look like a two-step cycle.
      if not edge.reverse then
        walk(edge.to, path)
      end
    end
    table.remove(path)
    visiting[node] = nil
    done_with[node] = true
  end
  for _, node in ipairs(graph.nodes) do
    walk(node, {})
  end

  if #cycles == 0 then
    print("  none")
  else
    for index = 1, math.min(5, #cycles) do
      print("  " .. cycles[index])
    end
    print(("  %d cycle(s) in total"):format(#cycles))
  end
end)

-- ---------------------------------------------------------------------------

section("join paths across the whole schema")

run("paths", function()
  local reachable, unreachable, longest = 0, 0, nil
  local sample = {}

  for _, from in ipairs(graph.nodes) do
    for _, to in ipairs(graph.nodes) do
      if from ~= to then
        local paths = joins.paths(graph, from, to)
        if #paths > 0 then
          reachable = reachable + 1
          local length = #paths[1]
          if not longest or length > longest.length then
            longest = { from = from, to = to, length = length, path = paths[1] }
          end
          if #sample < 3 and length >= 3 then
            table.insert(sample, { from = from, path = paths[1] })
          end
        else
          unreachable = unreachable + 1
        end
      end
    end
  end

  print(("  %d ordered pairs joinable, %d not"):format(reachable, unreachable))
  if longest then
    print(("  longest: %s"):format(joins.describe(longest.path, longest.from)))
  end
  for _, entry in ipairs(sample) do
    print("  " .. joins.describe(entry.path, entry.from))
  end
end)

-- ---------------------------------------------------------------------------

section("what points at a user")

run("reverse", function()
  local started = vim.uv.hrtime()
  local keys = session.referencing_keys(target.id, schema, "user")
  print(("  %d incoming foreign key(s) in %.0f ms"):format(
    #keys,
    (vim.uv.hrtime() - started) / 1e6
  ))
  local shown = 0
  for _, key in ipairs(keys) do
    if shown < 6 then
      print(("    %s.%s"):format(key.table, key.column))
      shown = shown + 1
    end
  end
  if #keys < 20 then
    table.insert(failures, ("only %d incoming keys on `user`, expected ~23"):format(#keys))
  end
end)

-- ---------------------------------------------------------------------------

section("a fixture from the most connected row")

run("fixture", function()
  local fixture = require("dbclient.fixture")
  local rows = session.query(
    target.id,
    ("select id from %s.inquiry order by id limit 1"):format(schema)
  )
  if #rows.rows == 0 then
    print("  no inquiries to pull")
    return
  end
  local id = tostring(rows.rows[1][1])

  local started = vim.uv.hrtime()
  local collected = fixture.collect({
    session_id = target.id,
    schema = schema,
    table = "inquiry",
    pk = { id = id },
  })
  print(("  inquiry #%s pulled %d rows across %d tables in %.0f ms"):format(
    id,
    collected.count,
    #collected.order,
    (vim.uv.hrtime() - started) / 1e6
  ))
  print("  order: " .. table.concat(collected.order, " → "))

  -- The order has to be a valid insert order: nothing may reference a table
  -- that comes later.
  local position = {}
  for index, name in ipairs(collected.order) do
    position[name:gsub("^.*%.", "")] = index
  end
  local violations = 0
  for name, index in pairs(position) do
    for _, edge in ipairs(graph.edges[name] or {}) do
      local target_position = position[edge.to]
      if not edge.reverse and target_position and target_position > index and edge.to ~= name then
        violations = violations + 1
        if violations <= 3 then
          print(("  ERROR: %s comes before %s but references it"):format(name, edge.to))
        end
      end
    end
  end
  if violations > 0 then
    table.insert(failures, ("fixture order has %d dependency violation(s)"):format(violations))
  else
    print("  the order is a valid insert order")
  end

  local lines = fixture.render({
    session_id = target.id,
    collected = collected,
    connection = "probe",
  })
  local inserts = 0
  for _, line in ipairs(lines) do
    if line:match("^insert") then
      inserts = inserts + 1
    end
  end
  print(("  %d insert statement(s) rendered"):format(inserts))
end)

-- ---------------------------------------------------------------------------

section("following keys as far as they go")

local data = require("dbclient.ui.data")
local trail = require("dbclient.trail")
local grid = require("dbclient.ui.grid")

--- The view showing in the current buffer.
local function current_view()
  for _, candidate in pairs(data.views) do
    if candidate.bufnr == vim.api.nvim_get_current_buf() then
      return candidate
    end
  end
end

--- Follow one foreign key out of the current row, choosing whichever leads
--- somewhere not yet visited.
---
--- Greedy rather than scripted: the point is to walk the graph the schema
--- actually has, not the one the probe's author guessed at.
---@param visited table<string, boolean>
---@return string|nil landed, string|nil via
local function hop(visited)
  local view = current_view()
  if not view or not view.fk then
    return nil
  end

  -- Prefer keys that lead somewhere with keys of its own. Sorting by column
  -- name instead walks straight into the first dictionary table and stops,
  -- which says nothing about whether the graph can be traversed.
  local function out_degree(name)
    local count = 0
    for _, edge in ipairs(graph.edges[name] or {}) do
      if not edge.reverse then
        count = count + 1
      end
    end
    return count
  end

  local candidates = {}
  for column, key in pairs(view.fk) do
    if not visited[key.ref_table] then
      table.insert(candidates, {
        column = column,
        to = key.ref_table,
        degree = out_degree(key.ref_table),
      })
    end
  end
  table.sort(candidates, function(a, b)
    if a.degree ~= b.degree then
      return a.degree > b.degree
    end
    return a.column < b.column
  end)

  local line = data.HEADER_LINES + 1
  local text = vim.api.nvim_buf_get_lines(view.bufnr, line - 1, line, false)[1] or ""
  local spans = grid.line_spans(text, view.spans)

  for _, candidate in ipairs(candidates) do
    local index
    for position, column in ipairs(view.columns) do
      if column.name == candidate.column then
        index = position
      end
    end
    -- A null foreign key has nothing to follow, so skip to the next one
    -- rather than reporting a dead end.
    local cell = index and spans[index] and vim.trim(text:sub(spans[index].start + 1, spans[index].finish))
    if index and cell and cell ~= "" and cell ~= require("dbclient.config").get().ui.null_display then
      vim.api.nvim_win_set_cursor(0, { line, spans[index].start })
      local before = trail.current() and trail.current().table
      data.follow_fk()
      local ok = vim.wait(20000, function()
        return trail.current() and trail.current().table ~= before
      end, 25)
      if ok then
        local landed = trail.current().table
        -- The trail moves as soon as the jump is decided; the buffer it lands
        -- in is still being fetched. Reading its spans before it has rendered
        -- gives nothing to put the cursor on, and the next hop silently finds
        -- no keys to follow.
        local arrived
        vim.wait(20000, function()
          for _, opened in pairs(data.views) do
            if opened.table == landed and (opened.generation or 0) > 0 then
              arrived = opened
              return true
            end
          end
          return false
        end, 25)
        if arrived then
          vim.api.nvim_set_current_buf(arrived.bufnr)
        end
        return landed, candidate.column
      end
    end
  end
  return nil
end

data.open({ session_id = target.id, schema = schema, table = "inquiry", filter = "" })
local opened
if
  not vim.wait(30000, function()
    for _, candidate in pairs(data.views) do
      if candidate.table == "inquiry" and (candidate.generation or 0) > 0 then
        opened = candidate
        return true
      end
    end
    return false
  end, 25)
then
  table.insert(failures, "the inquiry data buffer did not render")
else
  trail.clear()
  trail.push({
    session_id = target.id,
    connection = target.name,
    schema = schema,
    table = "inquiry",
  })
  vim.api.nvim_set_current_buf(opened.bufnr)

  local visited = { inquiry = true }
  local walked = { "inquiry" }
  for _ = 1, 4 do
    local landed, via = hop(visited)
    if not landed then
      break
    end
    visited[landed] = true
    table.insert(walked, ("%s(%s)"):format(landed, via))
  end

  print("  " .. table.concat(walked, " → "))
  print("  trail: " .. trail.breadcrumb())
  if #walked < 4 then
    table.insert(failures, ("only %d hop(s) followed"):format(#walked - 1))
  end

  -- All the way back to where it started.
  local depth = #trail.entries
  trail.back(depth - 1)
  vim.wait(10000, function()
    return not trail.restoring
  end, 25)
  local home = trail.current() and trail.current().table
  print(("  back %d step(s) lands on: %s"):format(depth - 1, tostring(home)))
  if home ~= "inquiry" then
    table.insert(failures, ("walking back landed on %s, not inquiry"):format(tostring(home)))
  end

  -- And forward again, which is the half people forget to implement.
  trail.forward(depth - 1)
  vim.wait(10000, function()
    return not trail.restoring
  end, 25)
  print(("  forward again lands on: %s"):format(tostring(trail.current() and trail.current().table)))
end

-- ---------------------------------------------------------------------------

print("")
if #failures == 0 then
  print("the graph walks in every direction")
else
  print(("%d problem(s):"):format(#failures))
  for _, entry in ipairs(failures) do
    print("  " .. entry)
  end
end

session.disconnect_all()
client.stop()
vim.cmd(#failures == 0 and "cquit 0" or "cquit 1")

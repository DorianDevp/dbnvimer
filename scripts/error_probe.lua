--- Provoke every class of error against a real server and print what the user
--- would see.
---
---   DBCLIENT_PROBE="adapter=… host=… port=… user=… password=… database=…" \
---     nvim --headless -u NONE -c "luafile scripts/error_probe.lua"
---
--- The parsers are unit tested against messages transcribed by hand, which
--- proves the parsing and not the transcription. This runs the statements and
--- reads what the server actually says, which is the only way to find out that
--- MariaDB 10.6 phrases something differently from MySQL 8.
---
--- Anything that comes back `unknown`, or with no explanation, or with a caret
--- pointing at the wrong token, is a failure — the whole point is that there is
--- no such thing as an error we merely pass along.

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.columns = 120
vim.o.lines = 60

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
local errors = require("dbclient.errors")

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

local function run(fn)
  local done, failure = false, nil
  client.async(function()
    fn()
    done = true
  end, function(err, detail)
    failure = { err = err, detail = detail }
    done = true
  end)
  vim.wait(30000, function()
    return done
  end, 25)
  return failure
end

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

local dialect = require("dbclient.replace").dialect_for(target.id)
local function ident(name)
  return require("dbclient.replace").quote_ident(name, dialect)
end

local SERIAL = dialect == "postgres" and "serial primary key" or "int primary key"
local setup = {
  "drop table if exists dbclient_err_child",
  "drop table if exists dbclient_err_parent",
  ("create table dbclient_err_parent (id %s, email varchar(80) unique)"):format(SERIAL),
  [[create table dbclient_err_child (
      id int primary key,
      parent_id int not null,
      label varchar(8) not null,
      priority int,
      constraint fk_child_parent foreign key (parent_id) references dbclient_err_parent (id),
      constraint chk_priority check (priority between 1 and 5)
    )]],
  "insert into dbclient_err_parent (id, email) values (1, 'jan@ventia.pl')",
}
run(function()
  for _, sql in ipairs(setup) do
    local ok, err = pcall(session.query, target.id, sql)
    if not ok then
      print("  setup failed: " .. sql .. "\n    " .. tostring(err))
    end
  end
end)

-- ---------------------------------------------------------------------------
-- The statements
-- ---------------------------------------------------------------------------

--- `{ label, sql, expected kind, the token the caret should land on }`
local CASES = {
  { "syntax", "select * FORM dbclient_err_parent", "syntax", "FORM" },
  { "unknown column", "select statuz from dbclient_err_parent", "undefined_column", "statuz" },
  { "unknown table", "select * from dbclient_err_nope", "undefined_table", "dbclient_err_nope" },
  { "unknown function", "select no_such_fn(1)", "undefined_function", nil },
  {
    -- Servers disagree on which of these a missing NOT NULL column is: MariaDB
    -- reports 1364 "no default value", PostgreSQL 23502. Both explanations are
    -- right, so both are accepted.
    "not null",
    "insert into dbclient_err_child (id, parent_id) values (1, 1)",
    { "not_null", "no_default" },
    nil,
  },
  {
    "foreign key",
    "insert into dbclient_err_child (id, parent_id, label) values (2, 9999, 'x')",
    "foreign_key",
    nil,
  },
  {
    "unique",
    "insert into dbclient_err_parent (id, email) values (2, 'jan@ventia.pl')",
    "unique",
    nil,
  },
  {
    "check",
    "insert into dbclient_err_child (id, parent_id, label, priority) values (3, 1, 'x', 99)",
    "check",
    nil,
  },
  {
    -- SQLite does not enforce a varchar length: `varchar(8)` is documentation
    -- there, not a constraint. That is the engine's design, not a gap.
    "value too long",
    "insert into dbclient_err_child (id, parent_id, label) values (4, 1, 'far too long for eight')",
    "string_too_long",
    nil,
    optional = true,
  },
  {
    -- On SQLite the check constraint catches this before typing does, because
    -- typing is dynamic and 'nonsense' is a perfectly good value to store.
    "bad type",
    "insert into dbclient_err_child (id, parent_id, label, priority) values (5, 1, 'x', 'nonsense')",
    { "data_type", "check" },
    nil,
  },
  -- MySQL returns NULL for this outside of a write, which is its documented
  -- behaviour rather than a gap, so it is allowed to produce nothing.
  { "division by zero", "select 1 / 0", "division_by_zero", nil, optional = true },
  {
    "duplicate object",
    "create table dbclient_err_parent (id int)",
    "duplicate_object",
    nil,
  },
}

local widest = 0
for _, case in ipairs(CASES) do
  widest = math.max(widest, #case[1])
end

print("")
print(("%s %s"):format(spec.adapter, target.info and target.info.server_version or "?"))
print(string.rep("═", 100))

for _, case in ipairs(CASES) do
  local label, sql, token = case[1], case[2], case[4]
  local expected = type(case[3]) == "table" and case[3] or { case[3] }
  local failure = run(function()
    session.query(target.id, sql)
  end)

  print("")
  print(("── %s "):format(label) .. string.rep("─", math.max(0, 92 - #label)))

  if not failure then
    if not case.optional then
      table.insert(failures, label .. ": the statement succeeded, so nothing was tested")
    end
    print("  (no error — this server does not treat it as one)")
  else
    local err = errors.normalise(failure.err, failure.detail)

    if not vim.tbl_contains(expected, err.kind) then
      -- `unknown` is the specific outcome this module exists to prevent.
      table.insert(
        failures,
        ("%s: kind %s, expected %s"):format(label, err.kind, table.concat(expected, " or "))
      )
    end
    if err.kind ~= "unknown" and errors.summary(err.kind) == errors.summary("unknown") then
      table.insert(failures, label .. ": no explanation for kind " .. err.kind)
    end
    if token then
      if not err.position then
        table.insert(failures, ("%s: no position, so no caret"):format(label))
      else
        local at = errors.locate(err, sql, 1)
        local landed = at and sql:sub(at.col + 1, at.end_col) or ""
        if landed:lower() ~= token:lower() then
          table.insert(
            failures,
            ("%s: caret landed on %q, expected %q"):format(label, landed, token)
          )
        end
      end
    end

    for _, line in ipairs((errors.render(err, { source = sql, width = 92 }))) do
      print("  " .. line)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Multi-statement scripts
-- ---------------------------------------------------------------------------

print("")
print("── an error in the middle of a script " .. string.rep("─", 62))
local script = table.concat({
  "select 1;",
  "",
  "-- a comment that moves the line numbers",
  "select 2;",
  "",
  "select * FORM dbclient_err_parent;",
}, "\n")

local failure = run(function()
  client.call("execute-script", { sql = script }, target.id)
end)

if not failure or not failure.detail then
  table.insert(failures, "script: no structured error")
  print("  no structured error")
else
  local err = errors.normalise(failure.err, failure.detail)
  print(("  statement %s, position %s"):format(
    tostring(err.statement_index),
    tostring(err.position)
  ))
  local at = errors.locate(err, script, 1)
  if not at then
    table.insert(failures, "script: no position in the file")
  else
    local line = vim.split(script, "\n")[at.line + 1]
    print(("  file line %d, column %d: %q"):format(at.line + 1, at.col, line))
    print(("  under the cursor: %q"):format(line:sub(at.col + 1, at.end_col)))
    if at.line ~= 5 then
      table.insert(
        failures,
        ("script: reported file line %d, the failing statement is on line 6"):format(at.line + 1)
      )
    end
    if line:sub(at.col + 1, at.end_col):upper() ~= "FORM" then
      table.insert(failures, "script: the caret is not on FORM")
    end
  end
end

-- ---------------------------------------------------------------------------
-- Did you mean
-- ---------------------------------------------------------------------------

print("")
print("── the identifier you probably meant " .. string.rep("─", 63))

local suggestion_failure = run(function()
  -- Warm the metadata the suggestion draws on, the way opening the sidebar or
  -- the completion source would.
  session.tables(target.id, schema)
  session.columns(target.id, schema, "dbclient_err_child")
end)
if suggestion_failure then
  table.insert(failures, "could not warm the metadata cache: " .. tostring(suggestion_failure.err))
end

for _, attempt in ipairs({
  { "select priorty from dbclient_err_child", "priority" },
  { "select * from dbclient_err_chil", "dbclient_err_child" },
}) do
  local sql, wanted = attempt[1], attempt[2]
  local failure = run(function()
    session.query(target.id, sql)
  end)
  if not failure then
    table.insert(failures, "suggestion: " .. sql .. " did not fail")
  else
    local err = errors.normalise(failure.err, failure.detail)
    err.session_id = target.id
    local wrong = err.column or err.table or err.near
    local names = errors.suggest(wrong or "", errors.candidates(err, target.id))
    print(("  %s"):format(sql))
    print(("    → %s"):format(#names > 0 and table.concat(names, ", ") or "(nothing suggested)"))
    if not vim.tbl_contains(names, wanted) then
      table.insert(
        failures,
        ("suggestion for %q: got %s, wanted %s"):format(
          wrong or "?",
          #names > 0 and table.concat(names, ", ") or "nothing",
          wanted
        )
      )
    end
  end
end

-- ---------------------------------------------------------------------------
-- Refusals that never reach the server
-- ---------------------------------------------------------------------------

print("")
print("── a write on a read-only connection " .. string.rep("─", 63))
local readonly
session.connect_spec = nil
local read_spec = vim.tbl_extend("force", spec, { access = "read" })
require("dbclient.config").get().connections.probe_ro = read_spec
session.connect("probe_ro", function(result, err)
  readonly = result or err
end)
vim.wait(20000, function()
  return readonly ~= nil
end, 25)

if type(readonly) == "table" then
  local refused = run(function()
    session.query(readonly.id, "delete from dbclient_err_parent")
  end)
  if refused then
    local err = errors.normalise(refused.err, refused.detail)
    if err.kind ~= "access_refused" then
      table.insert(failures, "read-only: kind " .. err.kind .. ", expected access_refused")
    end
    for _, line in ipairs((errors.render(err, { width = 92 }))) do
      print("  " .. line)
    end
  else
    table.insert(failures, "read-only: the delete was not refused")
  end
end

-- ---------------------------------------------------------------------------

run(function()
  pcall(session.query, target.id, "drop table if exists dbclient_err_child")
  pcall(session.query, target.id, "drop table if exists dbclient_err_parent")
end)

print("")
print(string.rep("═", 100))
if #failures == 0 then
  print("every case classified, explained and located")
else
  print(("%d problem(s):"):format(#failures))
  for _, entry in ipairs(failures) do
    print("  " .. entry)
  end
end

session.disconnect_all()
client.stop()
vim.cmd(#failures == 0 and "cquit 0" or "cquit 1")

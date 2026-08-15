--- Exercise the schema-file, drift and schema-wide-search features against a
--- real database.
---
---   DBCLIENT_PROBE="host=… port=… user=… password=… database=…" \
---   DBCLIENT_SCHEMA=public DBCLIENT_NEEDLE="some text" \
---     nvim --headless -u NONE -c "luafile scripts/schema_probe.lua"
---
--- Read only, by construction: the connection is opened with `access = "read"`
--- so the core refuses a write even if this script asked for one, and the
--- replacement half of the feature is deliberately not exercised here. Files go
--- to a temporary directory, never into the project being read.

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.columns = 160
vim.o.lines = 50

local core = vim.fn.getcwd() .. "/rust/dbclient-core/target/release/dbclient-core"
local dsn = vim.env.DBCLIENT_PROBE or ""
local spec = { adapter = "mariadb", access = "read" }
for key, value in dsn:gmatch("([%w_]+)=(%S+)") do
  spec[key] = key == "port" and tonumber(value) or value
end

local sandbox = vim.fn.tempname() .. "/dbclient"
vim.fn.mkdir(sandbox, "p")

require("dbclient").setup({
  core = { command = core },
  detect = { enabled = false },
  store = { enabled = false },
  history = { enabled = false, path = sandbox .. "/history.jsonl" },
  export = { dir = sandbox .. "/exports" },
  connections = { probe = spec },
})

local client = require("dbclient.core.client")
local session = require("dbclient.session")
-- On PostgreSQL the database and the schema are different things, so the one
-- to walk is named separately.
local schema = vim.env.DBCLIENT_SCHEMA or spec.database

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

local failures = 0
local function run(label, fn)
  local done, failure = false, nil
  client.async(function()
    fn()
    done = true
  end, function(err)
    failure, done = err, true
  end)
  if
    not vim.wait(180000, function()
      return done
    end, 25)
  then
    failure = "timed out"
  end
  if failure then
    failures = failures + 1
    print(("  ERROR in %s: %s"):format(label, failure))
  end
end

local function section(title)
  print("")
  print("── " .. title .. " " .. string.rep("─", math.max(0, 66 - #title)))
end

local schemafiles = require("dbclient.schemafiles")
local dir = sandbox .. "/schema"

-- ---------------------------------------------------------------------------

section("the write guard actually holds")
run("read-only", function()
  local ok = pcall(session.query, target.id, "create table dbclient_probe_scratch (id int)")
  print("  a create on a read-only connection is refused: " .. tostring(not ok))
  if ok then
    failures = failures + 1
  end
end)

section("dump the schema as files")
run("dump", function()
  local started = vim.uv.hrtime()
  local result = schemafiles.dump({ session_id = target.id, schema = schema, dir = dir })
  print(("  %d files written in %.0f ms"):format(
    #result.written,
    (vim.uv.hrtime() - started) / 1e6
  ))
  print(("  %d unchanged, %d failed"):format(result.unchanged, #result.failed))
  for _, failure in ipairs(result.failed) do
    print(("    %s %s: %s"):format(failure.kind, failure.name, failure.error))
  end

  local sizes = {}
  for _, path in ipairs(result.written) do
    table.insert(sizes, vim.fn.getfsize(path))
  end
  table.sort(sizes)
  if #sizes > 0 then
    print(("  smallest %d bytes, largest %d bytes"):format(sizes[1], sizes[#sizes]))
  end
end)

section("a second dump writes nothing")
run("stability", function()
  local again = schemafiles.dump({ session_id = target.id, schema = schema, dir = dir })
  print(("  written %d, unchanged %d"):format(#again.written, again.unchanged))
  if #again.written > 0 then
    failures = failures + 1
    print("  ERROR: the dump is not byte-stable, so every dump would be a diff")
    for _, path in ipairs(again.written) do
      print("    " .. path)
    end
  end
end)

section("drift against what was just written")
run("drift", function()
  local report = schemafiles.drift({ session_id = target.id, schema = schema, dir = dir })
  print(("  %d objects checked, %d finding(s)"):format(report.checked, #report.findings))
  for _, finding in ipairs(report.findings) do
    failures = failures + 1
    print(("  ERROR: %s %s %s"):format(finding.status, finding.kind, finding.name))
  end
end)

section("drift after the repository falls behind")
run("drift-detects", function()
  -- Delete one file and truncate another: the two things that actually happen.
  local files = vim.fn.glob(dir .. "/" .. schema .. "/tables/*.sql", false, true)
  table.sort(files)
  if #files < 2 then
    print("  not enough tables to test with")
    return
  end
  vim.fn.delete(files[1])
  vim.fn.writefile({ "create table wrong (id int);" }, files[2])

  local report = schemafiles.drift({ session_id = target.id, schema = schema, dir = dir })
  local statuses = {}
  for _, finding in ipairs(report.findings) do
    statuses[finding.status] = (statuses[finding.status] or 0) + 1
  end
  print(("  untracked %d, changed %d, dropped %d"):format(
    statuses.untracked or 0,
    statuses.changed or 0,
    statuses.dropped or 0
  ))
  if (statuses.untracked or 0) < 1 or (statuses.changed or 0) < 1 then
    failures = failures + 1
    print("  ERROR: drift did not notice")
  end

  for _, line in ipairs((schemafiles.render_drift(report, schema))) do
    print("  " .. line)
  end
end)

section("find across every text column")
run("search", function()
  local replace = require("dbclient.replace")
  local needle = vim.env.DBCLIENT_NEEDLE or "a"

  local started = vim.uv.hrtime()
  local groups = replace.text_columns({ session_id = target.id, schema = schema })
  local columns = 0
  for _, group in ipairs(groups) do
    columns = columns + #group.columns
  end
  print(("  %d tables with %d text columns, listed in %.0f ms"):format(
    #groups,
    columns,
    (vim.uv.hrtime() - started) / 1e6
  ))

  started = vim.uv.hrtime()
  local report = replace.search({ session_id = target.id, schema = schema, needle = needle })
  print(("  searched %d tables for %q in %.0f ms"):format(
    report.searched,
    needle,
    (vim.uv.hrtime() - started) / 1e6
  ))

  for index, line in ipairs((replace.render(report, { needle = needle, schema = schema }))) do
    if index <= 14 then
      print("  " .. line)
    end
  end
  -- A skipped table is a failure here, not a footnote. The first run of this
  -- probe skipped all 175 of them — `escape '\\'` is an unterminated string on
  -- MySQL — and reported success, because nothing had thrown.
  if #report.skipped > 0 then
    failures = failures + 1
    print(("  ERROR: %d of %d table(s) could not be searched"):format(
      #report.skipped,
      #groups
    ))
    for index, entry in ipairs(report.skipped) do
      if index <= 3 then
        print(("    %s: %s"):format(entry.table, entry.error))
      end
    end
  end

  -- The generated UPDATE is printed rather than run: this connection is
  -- read-only and the point is to read what it would have done.
  if #report.hits > 0 then
    print("")
    print("  the statement it would run, unexecuted:")
    print("    " .. replace.update_sql(report.hits[1], {
      needle = needle,
      replacement = "REPLACED",
      schema = schema,
      dialect = replace.dialect_for(target.id),
    }))
  end
end)

print("")
print(("%d failure(s)"):format(failures))
session.disconnect_all()
client.stop()
vim.cmd(failures == 0 and "cquit 0" or "cquit 1")

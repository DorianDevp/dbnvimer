--- Run the migration reviewer over a real directory of migrations.
---
---   DBCLIENT_MIGRATIONS=../ventia-wsparcie/api/migrations \
---     nvim --headless -u NONE -c "luafile scripts/migration_probe.lua"
---
--- Unit tests cover statements this was written against. This covers statements
--- it was not: every migration a real project has accumulated, checked for
--- whether the extractor finds the SQL at all and whether the rules say
--- anything that would embarrass us.

vim.opt.runtimepath:prepend(vim.fn.getcwd())

require("dbclient").setup({
  detect = { enabled = false },
  store = { enabled = false },
  history = { enabled = false },
})

local migration = require("dbclient.migration")

local dir = vim.env.DBCLIENT_MIGRATIONS or "migrations"
local files = vim.fn.glob(dir .. "/*.php", false, true)
vim.list_extend(files, vim.fn.glob(dir .. "/*.sql", false, true))
table.sort(files)

if #files == 0 then
  print("no migrations under " .. dir)
  vim.cmd("cquit 1")
end

local totals = {
  files = 0,
  empty = 0,
  statements = 0,
  unclassified = 0,
  blocking = 0,
  caution = 0,
  note = 0,
}
local by_rule = {}
local unclassified_examples = {}

--- Two servers a year apart, so a difference in verdict is visible.
local SERVERS = {
  old = migration.server_profile({ adapter = "mariadb", server_version = "5.5.5-10.2.44-MariaDB" }),
  new = migration.server_profile({ adapter = "mariadb", server_version = "5.5.5-10.11.6-MariaDB" }),
}

local differed = {}

for _, path in ipairs(files) do
  totals.files = totals.files + 1
  local statements = migration.extract(vim.fn.readfile(path), path)

  if #statements == 0 then
    totals.empty = totals.empty + 1
  end
  totals.statements = totals.statements + #statements

  for _, statement in ipairs(statements) do
    local at = migration.classify(statement.sql)
    if at.kind == "other" then
      totals.unclassified = totals.unclassified + 1
      if #unclassified_examples < 8 then
        table.insert(unclassified_examples, statement.sql:sub(1, 100))
      end
    end
  end

  local verdicts = {}
  for name, server in pairs(SERVERS) do
    verdicts[name] = migration.analyse({ statements = statements, server = server })
  end

  for _, finding in ipairs(verdicts.old) do
    totals[finding.severity] = (totals[finding.severity] or 0) + 1
    by_rule[finding.rule] = (by_rule[finding.rule] or 0) + 1
  end

  -- The point of the feature: the same file, judged differently.
  local function fingerprint(findings)
    local parts = {}
    for _, finding in ipairs(findings) do
      table.insert(parts, finding.index .. finding.severity)
    end
    table.sort(parts)
    return table.concat(parts, ",")
  end
  if fingerprint(verdicts.old) ~= fingerprint(verdicts.new) and #differed < 5 then
    table.insert(differed, { path = path, old = verdicts.old, new = verdicts.new })
  end
end

print(("%d files, %d statements"):format(totals.files, totals.statements))
print(("  %d file(s) yielded nothing"):format(totals.empty))
print(("  %d statement(s) unclassified"):format(totals.unclassified))
print(("  findings on MariaDB 10.2: %d blocking, %d caution, %d note"):format(
  totals.blocking,
  totals.caution,
  totals.note
))

print("")
print("by rule")
local names = vim.tbl_keys(by_rule)
table.sort(names, function(a, b)
  return by_rule[a] > by_rule[b]
end)
for _, name in ipairs(names) do
  print(("  %-34s %d"):format(name, by_rule[name]))
end

if #unclassified_examples > 0 then
  print("")
  print("unclassified, for a look:")
  for _, sql in ipairs(unclassified_examples) do
    print("  " .. sql)
  end
end

print("")
print(("%d file(s) judged differently on 10.2 and 10.11"):format(#differed))
for _, entry in ipairs(differed) do
  print("")
  print("  " .. vim.fn.fnamemodify(entry.path, ":t"))
  for _, label in ipairs({ "old", "new" }) do
    local counts = { blocking = 0, caution = 0, note = 0 }
    for _, finding in ipairs(entry[label]) do
      counts[finding.severity] = counts[finding.severity] + 1
    end
    print(("    %-4s %d blocking  %d caution  %d note"):format(
      label == "old" and "10.2" or "10.11",
      counts.blocking,
      counts.caution,
      counts.note
    ))
  end
end

-- A migration set where nothing parses means the extractor is broken, which is
-- worth failing over rather than reporting as zero findings.
vim.cmd(totals.statements > 0 and "cquit 0" or "cquit 1")

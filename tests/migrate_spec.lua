local t = require("tests.init")
local migrate = require("dbclient.ddl.migrate")

local BEFORE = [[
create table "public"."users" (
  "id" integer not null,
  "name" character varying(255) not null,
  "email" character varying(255),
  constraint "users_pkey" PRIMARY KEY (id)
);
]]

t.describe("ddl parsing", {
  ["splits the column list"] = function()
    local parsed = migrate.parse(BEFORE)
    t.eq(parsed.order, { "id", "name", "email" })
    t.eq(parsed.columns.name.definition, "character varying(255) not null")
    t.eq(#parsed.constraints, 1)
  end,

  ["does not split inside parentheses"] = function()
    local items = migrate.split_items("a numeric(10, 2), b text")
    t.eq(items, { "a numeric(10, 2)", "b text" })
  end,

  ["does not split inside quotes"] = function()
    local items = migrate.split_items("a text default 'x, y', b text")
    t.eq(items, { "a text default 'x, y'", "b text" })
  end,

  ["handles MySQL backtick style"] = function()
    local parsed = migrate.parse([[
CREATE TABLE `users` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
]])
    t.eq(parsed.order, { "id", "name" })
    t.eq(#parsed.constraints, 1)
  end,
})

t.describe("migration derivation", {
  ["adds a column"] = function()
    local after = BEFORE:gsub('  "email" character varying%(255%),',
      '  "email" character varying(255),\n  "phone" text,')
    local result = migrate.compute({
      before = BEFORE,
      after = after,
      adapter = "postgres",
      schema = "public",
      table = "users",
    })
    t.eq(#result.statements, 1)
    t.matches(result.statements[1], 'add column "phone" text')
  end,

  ["drops a column"] = function()
    local after = BEFORE:gsub('  "email" character varying%(255%),\n', "")
    local result = migrate.compute({
      before = BEFORE,
      after = after,
      adapter = "postgres",
      schema = "public",
      table = "users",
    })
    t.eq(#result.statements, 1)
    t.matches(result.statements[1], 'drop column "email"')
  end,

  ["changes nullability on postgres"] = function()
    local after = BEFORE:gsub('"email" character varying%(255%)',
      '"email" character varying(255) not null')
    local result = migrate.compute({
      before = BEFORE,
      after = after,
      adapter = "postgres",
      schema = "public",
      table = "users",
    })
    local text = table.concat(result.statements, "\n")
    t.matches(text, "set not null")
  end,

  ["uses MODIFY COLUMN on mariadb"] = function()
    local before = "create table `t` (\n  `a` int NOT NULL\n)"
    local after = "create table `t` (\n  `a` bigint NOT NULL\n)"
    local result = migrate.compute({
      before = before,
      after = after,
      adapter = "mariadb",
      schema = "shop",
      table = "t",
    })
    t.eq(#result.statements, 1)
    t.matches(result.statements[1], "modify column `a` bigint")
  end,

  ["reports a possible rename instead of guessing"] = function()
    local after = BEFORE:gsub('"email"', '"contact_email"')
    local result = migrate.compute({
      before = BEFORE,
      after = after,
      adapter = "postgres",
      schema = "public",
      table = "users",
    })
    local notes = table.concat(result.notes, "\n")
    t.matches(notes, "rename")
    t.matches(notes, "rename column")
    -- The literal interpretation is still offered, so nothing is silently
    -- decided on the user's behalf.
    local statements = table.concat(result.statements, "\n")
    t.matches(statements, "add column")
    t.matches(statements, "drop column")
  end,

  ["says so when nothing changed"] = function()
    local result = migrate.compute({
      before = BEFORE,
      after = BEFORE,
      adapter = "postgres",
      schema = "public",
      table = "users",
    })
    t.eq(result.statements, {})
    t.matches(result.notes[1], "no differences")
  end,

  ["refuses to alter columns on sqlite"] = function()
    local before = 'create table t (\n  a integer,\n  b text\n)'
    local after = 'create table t (\n  a text,\n  b text\n)'
    local result = migrate.compute({
      before = before,
      after = after,
      adapter = "sqlite",
      schema = "main",
      table = "t",
    })
    t.matches(table.concat(result.notes, "\n"), "SQLite cannot alter")
  end,

  ["adds a new constraint"] = function()
    local after = BEFORE:gsub('  constraint "users_pkey" PRIMARY KEY %(id%)',
      '  constraint "users_pkey" PRIMARY KEY (id),\n  constraint "users_email_key" UNIQUE (email)')
    local result = migrate.compute({
      before = BEFORE,
      after = after,
      adapter = "postgres",
      schema = "public",
      table = "users",
    })
    t.matches(table.concat(result.statements, "\n"), "add constraint \"users_email_key\" UNIQUE")
  end,
})

local t = require("tests.init")

local keymap = require("dbclient.keymap")
local migration = require("dbclient.migration")
local replace = require("dbclient.replace")
local schemafiles = require("dbclient.schemafiles")
local session = require("dbclient.session")

-- ---------------------------------------------------------------------------
-- Keymap hygiene
-- ---------------------------------------------------------------------------

t.describe("mapping table", {
  ["binds no key twice within a group"] = function()
    local duplicates = keymap.duplicates()
    local described = {}
    for _, entry in ipairs(duplicates) do
      table.insert(
        described,
        ("%s %q claimed by both %s and %s"):format(
          entry.group,
          entry.lhs,
          entry.actions[1],
          entry.actions[2]
        )
      )
    end
    t.eq(described, {}, "a second binding silently replaces the first")
  end,
})

-- ---------------------------------------------------------------------------
-- Migration review
-- ---------------------------------------------------------------------------

local function server(adapter, version)
  return migration.server_profile({ adapter = adapter, server_version = version })
end

--- Find one finding by rule name.
---@return table|nil
local function find(findings, rule)
  for _, finding in ipairs(findings) do
    if finding.rule == rule then
      return finding
    end
  end
  return nil
end


t.describe("server versions", {
  ["read a plain MySQL version"] = function()
    local profile = server("mariadb", "5.7.44")
    t.eq(profile.family, "mysql")
    t.eq(profile.version[1], 5)
    t.eq(profile.version[2], 7)
  end,

  ["read past MariaDB's protocol prefix"] = function()
    -- MariaDB reports "5.5.5-10.6.16-MariaDB" so old clients keep working.
    -- Reading the first triple is how a tool ends up applying 5.5 rules to a
    -- server from 2023.
    local profile = server("mariadb", "5.5.5-10.6.16-MariaDB-1:10.6.16+maria~ubu2004")
    t.ok(profile.mariadb, "recognised as MariaDB")
    t.eq(profile.version[1], 10)
    t.eq(profile.version[2], 6)
  end,

  ["tell MySQL from MariaDB by the version, not the adapter"] = function()
    -- DBClient's adapter is called `mariadb` for both servers, so the adapter
    -- name says nothing. A real MySQL server never puts "MariaDB" in its
    -- version string; MariaDB always does.
    local mysql = server("mariadb", "8.0.35")
    t.falsy(mysql.mariadb, "8.0.35 is MySQL")
    t.eq(mysql.version[1], 8)

    local maria = server("mariadb", "5.5.5-10.6.16-MariaDB")
    t.ok(maria.mariadb, "and this one is not")
  end,

  ["apply the 8.0 boundary to MySQL behind the mariadb adapter"] = function()
    local statements = {
      { sql = "ALTER TABLE inquiry ADD COLUMN priority INT NOT NULL DEFAULT 0", line = 1 },
    }
    local findings = migration.analyse({
      statements = statements,
      server = server("mariadb", "8.0.35"),
    })
    -- Treating this as MariaDB would compare 8.0 against the 10.3 boundary and
    -- call an instant operation a table rewrite.
    t.eq(find(findings, "mysql_add_column_default").severity, "note")
  end,

  ["read a PostgreSQL version"] = function()
    local profile = server("postgres", "16.2 (Debian 16.2-1.pgdg120+2)")
    t.eq(profile.family, "postgres")
    t.eq(profile.version[1], 16)
  end,

  ["compare versions"] = function()
    t.ok(migration.at_least({ 8, 0, 35 }, 8, 0))
    t.ok(migration.at_least({ 8, 4, 0 }, 8, 0))
    t.ok(migration.at_least({ 9, 0, 0 }, 8, 0))
    t.falsy(migration.at_least({ 5, 7, 44 }, 8, 0))
    t.falsy(migration.at_least({ 10, 2, 0 }, 10, 3))
    t.ok(migration.at_least({ 10, 3, 0 }, 10, 3))
  end,
})

t.describe("classifying statements", {
  ["an added column with a default"] = function()
    local at = migration.classify("ALTER TABLE inquiry ADD COLUMN priority INT NOT NULL DEFAULT 0")
    t.eq(at.kind, "alter")
    t.eq(at.table, "inquiry")
    t.ok(vim.tbl_contains(at.actions, "add_column_default"))
  end,

  ["a quoted and schema-qualified table"] = function()
    local at = migration.classify('ALTER TABLE "shop"."order_item" DROP COLUMN legacy_ref')
    t.eq(at.table, "order_item")
    t.ok(vim.tbl_contains(at.actions, "drop_column"))
  end,

  ["a backticked table"] = function()
    local at = migration.classify("ALTER TABLE `ps_product` ADD `weight` DECIMAL(20,6) DEFAULT 0")
    t.eq(at.table, "ps_product")
    t.ok(vim.tbl_contains(at.actions, "add_column_default"))
  end,

  ["an index"] = function()
    local at = migration.classify("CREATE INDEX idx_a ON inquiry (priority)")
    t.eq(at.kind, "create_index")
    t.eq(at.table, "inquiry")
    t.falsy(vim.tbl_contains(at.actions, "concurrent"))

    local concurrent =
      migration.classify("CREATE INDEX CONCURRENTLY idx_a ON inquiry (priority)")
    t.ok(vim.tbl_contains(concurrent.actions, "concurrent"))
  end,

  ["a foreign key"] = function()
    local at = migration.classify(
      "ALTER TABLE device ADD CONSTRAINT fk_dev_addr FOREIGN KEY (address_id) REFERENCES address (id)"
    )
    t.ok(vim.tbl_contains(at.actions, "add_foreign_key"))
  end,

  ["a comment does not hide the statement"] = function()
    local at = migration.classify([[
      -- add the priority flag
      /* ticket 4412 */
      ALTER TABLE inquiry ADD COLUMN priority INT DEFAULT 0
    ]])
    t.eq(at.kind, "alter")
    t.eq(at.table, "inquiry")
  end,

  ["an explicit algorithm is noticed"] = function()
    local at = migration.classify(
      "ALTER TABLE inquiry ADD INDEX idx_p (priority), ALGORITHM=INPLACE, LOCK=NONE"
    )
    t.ok(vim.tbl_contains(at.actions, "explicit_lock_none"))
  end,

  ["a destructive statement, with the table it names"] = function()
    local dropped = migration.classify("DROP TABLE legacy_import")
    t.eq(dropped.kind, "drop_table")
    t.eq(dropped.table, "legacy_import")

    local truncated = migration.classify("TRUNCATE TABLE session_cache")
    t.eq(truncated.kind, "truncate")
    t.eq(truncated.table, "session_cache")
    t.eq(migration.classify("TRUNCATE session_cache").table, "session_cache")
    t.eq(migration.classify("DROP TABLE IF EXISTS old_thing").table, "old_thing")
  end,

  ["a created table, with its name"] = function()
    -- Getting this wrong is silent: the name is only used to decide that a
    -- table is brand new, so a mis-read one just means the suppression never
    -- fires and the report fills up with findings about empty tables.
    t.eq(migration.classify("CREATE TABLE device (id INT NOT NULL)").table, "device")
    t.eq(
      migration.classify("CREATE TABLE IF NOT EXISTS `ps_stock` (id INT)").table,
      "ps_stock"
    )
    t.eq(migration.classify("INSERT INTO audit_log (a) VALUES (1)").table, "audit_log")
    t.eq(migration.classify("DELETE FROM session_cache WHERE id = 1").table, "session_cache")
    t.eq(migration.classify("UPDATE inquiry SET priority = 0").table, "inquiry")
  end,
})

t.describe("lock rules", {
    ["the same statement is blocking on 5.7 and a note on 8.0"] = function()
      local statements = {
        { sql = "ALTER TABLE inquiry ADD COLUMN priority INT NOT NULL DEFAULT 0", line = 1 },
      }

      local old = migration.analyse({ statements = statements, server = server("mysql", "5.7.44") })
      local new = migration.analyse({ statements = statements, server = server("mysql", "8.0.35") })

      t.eq(find(old, "mysql_add_column_default").severity, "blocking")
      t.eq(find(new, "mysql_add_column_default").severity, "note")
    end,

    ["MariaDB 10.3 is the boundary, not 8.0"] = function()
      local statements = {
        { sql = "ALTER TABLE inquiry ADD COLUMN priority INT DEFAULT 0", line = 1 },
      }
      local before = migration.analyse({
        statements = statements,
        server = server("mariadb", "5.5.5-10.2.44-MariaDB"),
      })
      local after = migration.analyse({
        statements = statements,
        server = server("mariadb", "5.5.5-10.6.16-MariaDB"),
      })
      t.eq(find(before, "mysql_add_column_default").severity, "blocking")
      t.eq(find(after, "mysql_add_column_default").severity, "note")
    end,

    ["PostgreSQL 11 is the boundary for a defaulted column"] = function()
      local statements = {
        { sql = "ALTER TABLE inquiry ADD COLUMN priority integer DEFAULT 0", line = 1 },
      }
      local ten = migration.analyse({
        statements = statements,
        server = server("postgres", "10.23"),
      })
      local sixteen = migration.analyse({
        statements = statements,
        server = server("postgres", "16.2"),
      })
      t.eq(find(ten, "postgres_add_column_default").severity, "blocking")
      t.eq(find(sixteen, "postgres_add_column_default").severity, "note")
    end,

    ["a plain CREATE INDEX is blocking on PostgreSQL"] = function()
      local findings = migration.analyse({
        statements = { { sql = "CREATE INDEX idx_a ON inquiry (priority)", line = 1 } },
        server = server("postgres", "16.2"),
      })
      t.eq(find(findings, "postgres_create_index").severity, "blocking")
    end,

    ["CONCURRENTLY turns it into a note"] = function()
      local findings = migration.analyse({
        statements = {
          { sql = "CREATE INDEX CONCURRENTLY idx_a ON inquiry (priority)", line = 1 },
        },
        server = server("postgres", "16.2"),
      })
      t.eq(find(findings, "postgres_create_index").severity, "note")
    end,

    ["MySQL rules do not fire on PostgreSQL"] = function()
      local findings = migration.analyse({
        statements = {
          { sql = "ALTER TABLE inquiry ADD COLUMN priority INT NOT NULL DEFAULT 0", line = 1 },
        },
        server = server("postgres", "16.2"),
      })
      t.falsy(find(findings, "mysql_add_column_default"), "no MySQL finding on PostgreSQL")
      t.ok(find(findings, "postgres_add_column_default"), "the PostgreSQL rule fired instead")
    end,

    ["a foreign key is flagged on either server"] = function()
      local statements = {
        {
          sql = "ALTER TABLE device ADD CONSTRAINT fk FOREIGN KEY (address_id) REFERENCES address (id)",
          line = 1,
        },
      }
      for _, profile in ipairs({ server("mysql", "8.0.35"), server("postgres", "16.2") }) do
        t.ok(find(migration.analyse({ statements = statements, server = profile }), "add_foreign_key"))
      end
    end,

    ["findings sort blocking first"] = function()
      local findings = migration.analyse({
        statements = {
          { sql = "ALTER TABLE a DROP COLUMN old_ref", line = 1 },
          { sql = "CREATE INDEX idx ON b (c)", line = 2 },
        },
        server = server("postgres", "16.2"),
      })
      t.ok(#findings >= 2)
      t.eq(findings[1].severity, "blocking")
    end,

    ["row counts reach the finding"] = function()
      local findings = migration.analyse({
        statements = {
          { sql = "ALTER TABLE inquiry ADD COLUMN priority INT NOT NULL DEFAULT 0", line = 1 },
        },
        server = server("mysql", "5.7.44"),
        row_counts = { inquiry = 1200000 },
      })
      t.eq(find(findings, "mysql_add_column_default").rows, 1200000)
    end,

  ["says nothing about a table this migration just created"] = function()
    -- The shape every framework emits: create the table, then add its keys.
    -- Both statements touch an empty table, so neither can block anything.
    local findings = migration.analyse({
      statements = {
        { sql = "CREATE TABLE device (id INT NOT NULL, address_id INT NOT NULL)", line = 1 },
        {
          sql = "ALTER TABLE device ADD CONSTRAINT fk FOREIGN KEY (address_id) REFERENCES address (id)",
          line = 2,
        },
        { sql = "CREATE INDEX idx_a ON device (address_id)", line = 3 },
      },
      server = server("mariadb", "5.5.5-10.2.44-MariaDB"),
    })
    t.eq(findings, {})
  end,

  ["still speaks up about a table that already existed"] = function()
    local findings = migration.analyse({
      statements = {
        { sql = "CREATE TABLE device (id INT NOT NULL)", line = 1 },
        {
          sql = "ALTER TABLE inquiry ADD CONSTRAINT fk FOREIGN KEY (device_id) REFERENCES device (id)",
          line = 2,
        },
      },
      server = server("mariadb", "5.5.5-10.2.44-MariaDB"),
    })
    t.ok(find(findings, "add_foreign_key"), "inquiry was not created here")
  end,

  ["says nothing about a table the server reports as empty"] = function()
    local statements = {
      { sql = "ALTER TABLE staging ADD COLUMN priority INT NOT NULL DEFAULT 0", line = 1 },
    }
    t.eq(
      migration.analyse({
        statements = statements,
        server = server("mariadb", "5.5.5-10.2.44-MariaDB"),
        row_counts = { staging = 0 },
      }),
      {}
    )
    t.ok(
      find(
        migration.analyse({
          statements = statements,
          server = server("mariadb", "5.5.5-10.2.44-MariaDB"),
          row_counts = { staging = 40000 },
        }),
        "mysql_add_column_default"
      ),
      "40 000 rows is a different answer"
    )
  end,

  ["a clean migration produces nothing"] = function()
    local findings = migration.analyse({
      statements = { { sql = "CREATE TABLE fresh (id integer primary key)", line = 1 } },
      server = server("postgres", "16.2"),
    })
    t.eq(findings, {})
  end,
})

t.describe("extracting statements", {
  ["from a Doctrine migration"] = function()
    local statements = migration.extract({
      "<?php",
      "final class Version20260315 extends AbstractMigration",
      "{",
      "    public function up(Schema $schema): void",
      "    {",
      "        $this->addSql('ALTER TABLE inquiry ADD priority INT DEFAULT 0 NOT NULL');",
      "        $this->addSql('CREATE INDEX idx_p ON inquiry (priority)');",
      "    }",
      "}",
    }, "migrations/Version20260315.php")

    t.eq(#statements, 2)
    t.matches(statements[1].sql, "^ALTER TABLE inquiry")
    t.eq(statements[1].line, 6, "the line points at the addSql call")
    t.eq(statements[2].line, 7)
  end,

  ["with an escaped quote inside the SQL"] = function()
    local statements = migration.extract({
      [[$this->addSql('UPDATE settings SET label = \'ACME S.A.\' WHERE id = 1');]],
    }, "Version1.php")
    t.eq(#statements, 1)
    t.matches(statements[1].sql, "ACME S%.A%.")
  end,

  ["from a plain .sql file"] = function()
    local statements = migration.extract({
      "alter table inquiry add column priority int default 0;",
      "create index idx_p on inquiry (priority);",
    }, "0042_priority.sql")
    t.eq(#statements, 2)
  end,

  ["ignores a file with no SQL in it"] = function()
    local statements = migration.extract({ "<?php", "// nothing here yet", "" }, "Empty.php")
    t.eq(#statements, 0)
  end,
})

t.describe("the migration report", {
  ["names the server it was judged against"] = function()
    local statements = {
      { sql = "ALTER TABLE inquiry ADD COLUMN priority INT NOT NULL DEFAULT 0", line = 6 },
    }
    local profile = server("mysql", "5.7.44")
    local lines = migration.render({
      findings = migration.analyse({ statements = statements, server = profile }),
      statements = statements,
      server = profile,
      path = "migrations/Version20260315.php",
    })
    t.matches(lines[1], "Version20260315%.php")
    t.matches(lines[1], "5%.7")
    t.matches(table.concat(lines, "\n"), "rewrites the whole table")
  end,

  ["says so when there is nothing to flag"] = function()
    local statements = { { sql = "CREATE TABLE fresh (id integer primary key)", line = 1 } }
    local profile = server("postgres", "16.2")
    local lines = migration.render({
      findings = migration.analyse({ statements = statements, server = profile }),
      statements = statements,
      server = profile,
    })
    t.matches(table.concat(lines, "\n"), "nothing to flag")
  end,
})

-- ---------------------------------------------------------------------------
-- Schema-wide replace
-- ---------------------------------------------------------------------------

t.describe("replace SQL generation", {
  ["quotes identifiers per dialect"] = function()
    t.eq(replace.quote_ident("order", "mysql"), "`order`")
    t.eq(replace.quote_ident("order", "postgres"), '"order"')
    t.eq(replace.quote_ident("we`ird", "mysql"), "`we``ird`")
    t.eq(replace.quote_ident('we"ird', "postgres"), '"we""ird"')
  end,

  ["doubles a quote in a literal"] = function()
    t.eq(replace.quote_literal("O'Brien"), "'O''Brien'")
    t.eq(replace.quote_literal("plain"), "'plain'")
  end,

  ["doubles a backslash only where the server reads it as an escape"] = function()
    -- MySQL and MariaDB treat a backslash in a string literal as an escape;
    -- PostgreSQL with standard_conforming_strings does not, so doubling there
    -- would put a real backslash into the data.
    t.eq(replace.quote_literal("a\\b", "mysql"), "'a\\\\b'")
    t.eq(replace.quote_literal("a\\b", "postgres"), "'a\\b'")
  end,

  ["never puts a backslash in the escape clause"] = function()
    -- `escape '\\'` is an unterminated string on MySQL, which turned every
    -- table in a 286-table schema into a syntax error.
    local _, clause = replace.like_pattern("anything")
    t.falsy(clause:find("\\", 1, true), "the escape clause is backslash free: " .. clause)

    local sql = replace.count_sql(
      { table = "t", columns = { "c" } },
      "ACME",
      "mysql",
      "s"
    )
    t.falsy(sql:find("\\", 1, true), "and so is the generated query")
  end,

  ["defangs LIKE wildcards in the needle"] = function()
    -- Searching for "100%" must not match every row.
    t.eq((replace.like_pattern("100%")), "%100!%%")
    t.eq((replace.like_pattern("a_b")), "%a!_b%")
    t.eq((replace.like_pattern("plain")), "%plain%")
    -- The escape character has to escape itself, or a needle containing one
    -- silently eats the next character.
    t.eq((replace.like_pattern("wow!")), "%wow!!%")
  end,

  ["counts every text column in one query"] = function()
    local sql = replace.count_sql(
      { table = "customer", columns = { "company", "note" } },
      "ACME",
      "mysql",
      "shop"
    )
    t.matches(sql, "^select ")
    t.matches(sql, "`company` like '%%ACME%%' escape '!'")
    t.matches(sql, "`note` like '%%ACME%%' escape '!'")
    t.matches(sql, "from `shop`%.`customer`$")
    t.eq(select(2, sql:gsub("from", "")), 1, "one query, not one per column")
  end,

  ["only rewrites rows that match"] = function()
    local sql = replace.update_sql({ table = "customer", column = "company" }, {
      needle = "ACME Corp",
      replacement = "ACME S.A.",
      schema = "shop",
      dialect = "mysql",
    })
    t.matches(sql, "^update `shop`%.`customer` set `company` = replace%(")
    t.matches(sql, "'ACME Corp'")
    t.matches(sql, "'ACME S%.A%.'")
    -- Without the WHERE, replace() would touch every row in the table.
    t.matches(sql, "where `company` like '%%ACME Corp%%'")
  end,

  ["carries an apostrophe through both halves"] = function()
    local sql = replace.update_sql({ table = "t", column = "c" }, {
      needle = "O'Brien",
      replacement = "O'Brian",
      schema = "s",
      dialect = "postgres",
    })
    t.matches(sql, "'O''Brien'")
    t.matches(sql, "'O''Brian'")
  end,
})

t.describe("the replace report", {
  ["lists the biggest tables first"] = function()
    local lines = replace.render({
      hits = {
        { table = "message", column = "body", count = 2 },
        { table = "address", column = "company", count = 11 },
        { table = "customer", column = "company", count = 3 },
      },
      total = 16,
      searched = 286,
      skipped = {},
    }, { needle = "ACME Corp", replacement = "ACME S.A.", schema = "shop" })

    local text = table.concat(lines, "\n")
    t.matches(lines[1], "ACME Corp")
    t.matches(lines[1], "ACME S%.A%.")
    t.matches(text, "16 rows across 3 columns in 3 tables %(286 tables searched%)")
  end,

  ["reports the tables it could not read"] = function()
    local lines = replace.render({
      hits = { { table = "a", column = "b", count = 1 } },
      total = 1,
      searched = 2,
      skipped = { { table = "broken_view", error = "permission denied" } },
    }, { needle = "x", schema = "s" })
    local text = table.concat(lines, "\n")
    t.matches(text, "1 table%(s%) could not be searched")
    t.matches(text, "broken_view: permission denied")
  end,

  ["says so when nothing matched"] = function()
    local lines = replace.render(
      { hits = {}, total = 0, searched = 286, skipped = {} },
      { needle = "nothing", schema = "shop" }
    )
    t.matches(table.concat(lines, "\n"), "no matches in 286 tables")
  end,
})

-- ---------------------------------------------------------------------------
-- Schema as files
-- ---------------------------------------------------------------------------

t.describe("schema file paths", {
  ["leave an ordinary name alone"] = function()
    t.eq(schemafiles.encode_name("ps_product"), "ps_product")
    t.eq(schemafiles.encode_name("Order_Item.v2"), "Order_Item.v2")
  end,

  ["escape what a filesystem would object to"] = function()
    t.eq(schemafiles.encode_name("odd/name"), "odd%2fname")
    t.eq(schemafiles.encode_name("a b"), "a%20b")
    t.eq(schemafiles.decode_name(schemafiles.encode_name("odd/name")), "odd/name")
    t.eq(schemafiles.decode_name(schemafiles.encode_name("a b")), "a b")
  end,

  ["place each kind in its own directory"] = function()
    t.eq(schemafiles.path_for("/db", "shop", "table", "customer"), "/db/shop/tables/customer.sql")
    t.eq(schemafiles.path_for("/db", "shop", "view", "active"), "/db/shop/views/active.sql")
    t.eq(schemafiles.path_for("/db", "shop", "routine", "recalc"), "/db/shop/routines/recalc.sql")
  end,
})

t.describe("dumping and drift", (function()
  --- Stand in for a live connection.
  local objects = {
    tables = {
      { name = "customer", kind = "BASE TABLE" },
      { name = "active_customer", kind = "VIEW" },
    },
    routines = { { name = "recalc" } },
    ddl = {
      customer = "create table customer (\n  id int primary key\n);",
      active_customer = "create view active_customer as select * from customer;",
      recalc = "create procedure recalc() begin end;",
    },
  }

  local saved = {}
  local function install()
    saved.tables, saved.routines, saved.ddl = session.tables, session.routines, session.ddl
    session.tables = function()
      return objects.tables
    end
    session.routines = function()
      return objects.routines
    end
    session.ddl = function(_, _, _, name)
      local ddl = objects.ddl[name]
      if not ddl then
        error("no ddl for " .. name)
      end
      -- Trailing whitespace on purpose: the dump has to normalise it away, or
      -- two dumps of an unchanged object would not be byte-identical.
      return ddl .. "   \n\n"
    end
  end
  local function restore()
    session.tables, session.routines, session.ddl = saved.tables, saved.routines, saved.ddl
  end

  local dir = vim.fn.tempname() .. "/schema"

  return {
    { "writes one file per object", function()
      install()
      local result = schemafiles.dump({ session_id = "s", schema = "shop", dir = dir })
      restore()

      t.eq(#result.written, 3, "table, view and routine")
      t.eq(vim.fn.filereadable(dir .. "/shop/tables/customer.sql"), 1)
      t.eq(vim.fn.filereadable(dir .. "/shop/views/active_customer.sql"), 1)
      t.eq(vim.fn.filereadable(dir .. "/shop/routines/recalc.sql"), 1)
    end },

    { "writes no header, so a diff means something", function()
      local text = table.concat(vim.fn.readfile(dir .. "/shop/tables/customer.sql"), "\n")
      t.falsy(text:find("generated"), "no generated-on line")
      t.falsy(text:find("%d%d%d%d%-%d%d%-%d%d"), "no timestamp")
      t.matches(text, "^create table customer")
    end },

    { "is byte-stable across runs", function()
      install()
      local again = schemafiles.dump({ session_id = "s", schema = "shop", dir = dir })
      restore()
      t.eq(again.written, {}, "nothing rewritten")
      t.eq(again.unchanged, 3, "all three matched what was on disk")
    end },

    { "reports no drift when nothing changed", function()
      install()
      local report = schemafiles.drift({ session_id = "s", schema = "shop", dir = dir })
      restore()
      t.eq(report.findings, {})
      t.eq(report.checked, 3)
    end },

    { "spots an object changed on the server", function()
      install()
      objects.ddl.customer = "create table customer (\n  id int primary key,\n  hotfix int\n);"
      local report = schemafiles.drift({ session_id = "s", schema = "shop", dir = dir })
      restore()

      t.eq(#report.findings, 1)
      t.eq(report.findings[1].status, "changed")
      t.eq(report.findings[1].name, "customer")
    end },

    { "spots an object missing from the repository", function()
      install()
      objects.tables[#objects.tables + 1] = { name = "audit_log", kind = "BASE TABLE" }
      objects.ddl.audit_log = "create table audit_log (id int);"
      local report = schemafiles.drift({ session_id = "s", schema = "shop", dir = dir })
      restore()

      local statuses = {}
      for _, finding in ipairs(report.findings) do
        statuses[finding.name] = finding.status
      end
      t.eq(statuses.audit_log, "untracked")
    end },

    { "spots a file with nothing behind it", function()
      install()
      objects.tables = { { name = "customer", kind = "BASE TABLE" } }
      objects.routines = {}
      local report = schemafiles.drift({ session_id = "s", schema = "shop", dir = dir })
      restore()

      local statuses = {}
      for _, finding in ipairs(report.findings) do
        statuses[finding.name] = finding.status
      end
      t.eq(statuses.active_customer, "dropped")
      t.eq(statuses.recalc, "dropped")
    end },

    { "prunes files for objects that are gone", function()
      install()
      local result = schemafiles.dump({ session_id = "s", schema = "shop", dir = dir })
      restore()
      t.eq(#result.removed, 2, "the view and the routine were deleted")
      t.eq(vim.fn.filereadable(dir .. "/shop/views/active_customer.sql"), 0)
    end },

    { "keeps stale files when told to", function()
      install()
      objects.tables = { { name = "customer", kind = "BASE TABLE" } }
      objects.routines = { { name = "recalc" } }
      schemafiles.dump({ session_id = "s", schema = "shop", dir = dir })
      objects.routines = {}
      local result = schemafiles.dump({ session_id = "s", schema = "shop", dir = dir, prune = false })
      restore()
      t.eq(result.removed, {})
      t.eq(vim.fn.filereadable(dir .. "/shop/routines/recalc.sql"), 1)
    end },

    { "one object that will not describe itself does not lose the rest", function()
      install()
      objects.tables = {
        { name = "customer", kind = "BASE TABLE" },
        { name = "broken", kind = "BASE TABLE" },
      }
      objects.routines = {}
      local result = schemafiles.dump({
        session_id = "s",
        schema = "shop",
        dir = dir .. "-partial",
      })
      restore()

      t.eq(#result.failed, 1)
      t.eq(result.failed[1].name, "broken")
      t.eq(vim.fn.filereadable(dir .. "-partial/shop/tables/customer.sql"), 1)
    end },

    { "renders a drift report", function()
      local lines = schemafiles.render_drift({
        dir = "/repo/db/schema",
        checked = 65,
        findings = {
          { status = "changed", kind = "table", name = "inquiry", path = "x" },
          { status = "untracked", kind = "table", name = "hotfix_notes", path = "y" },
        },
      }, "wsparcie")
      local text = table.concat(lines, "\n")
      t.matches(text, "changed on the server %(1%)")
      t.matches(text, "missing from the repository %(1%)")
      t.matches(text, "inquiry")
      t.matches(text, "hotfix_notes")
      t.matches(text, "65 objects checked")
    end },

    { "says so when there is no drift", function()
      local lines = schemafiles.render_drift({ dir = "/x", checked = 65, findings = {} }, "wsparcie")
      t.matches(table.concat(lines, "\n"), "no drift: 65 objects match")
    end },
  }
end)())

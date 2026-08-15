--- Adapter tests against real database servers.
---
---   DBCLIENT_TEST_POSTGRES="host=127.0.0.1 port=5432 user=postgres password=pw dbname=shop" \
---     nvim --headless -u NONE -i NONE -c "luafile tests/adapters.lua"
---
--- Each adapter is exercised on the things that differ between backends and
--- that a viewer gets wrong most easily: type rendering, NULL handling, wide
--- numerics, binary columns, identifier quoting, DDL, transactions and
--- cancellation. Skipped when the matching environment variable is unset.

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local t = require("tests.init")

local core = vim.fn.getcwd() .. "/rust/dbclient-core/target/release/dbclient-core"
if vim.fn.executable(core) ~= 1 then
  core = vim.fn.getcwd() .. "/rust/dbclient-core/target/debug/dbclient-core"
end
if vim.fn.executable(core) ~= 1 then
  print("dbclient-core is not built")
  vim.cmd("cquit 1")
end

local client = require("dbclient.core.client")
local config = require("dbclient.config")
local session = require("dbclient.session")

config.setup({
  core = { command = core },
  detect = { enabled = false },
  store = { enabled = false },
  history = { enabled = false },
  connections = {},
})

local function wait_for(predicate, label)
  if not vim.wait(20000, predicate, 25) then
    error("timed out waiting for " .. (label or "condition"), 2)
  end
end

local function run(fn)
  local done, failure = false, nil
  client.async(function()
    fn()
    done = true
  end, function(err)
    failure = err
    done = true
  end)
  wait_for(function()
    return done
  end, "async call")
  if failure then
    error(failure, 2)
  end
end

--- Turn a `key=value key=value` string into a connection spec.
local function parse_spec(text, adapter)
  local spec = { adapter = adapter }
  for key, value in text:gmatch("([%w_]+)=(%S+)") do
    if key == "host" then
      spec.host = value
    elseif key == "port" then
      spec.port = tonumber(value)
    elseif key == "user" then
      spec.user = value
    elseif key == "password" then
      spec.password = value
    elseif key == "dbname" or key == "database" then
      spec.database = value
    end
  end
  return spec
end

local function connect(name, spec)
  config.get().connections[name] = spec
  local result
  session.connect(name, function(target, err)
    result = target or err
  end)
  wait_for(function()
    return result ~= nil
  end, "connect " .. name)
  if type(result) ~= "table" then
    error("could not connect: " .. tostring(result), 2)
  end
  return result
end

--- The shared shape used by both server suites.
local FIXTURES = {
  postgres = {
    drop = {
      "drop table if exists dbclient_orders",
      "drop table if exists dbclient_items",
    },
    create = {
      [[create table dbclient_items (
          id bigserial primary key,
          name text not null,
          "odd Name" text,
          amount numeric(38,10),
          ratio double precision,
          active boolean,
          tags text[],
          payload jsonb,
          picture bytea,
          created_at timestamptz,
          day date,
          note text
        )]],
      [[create table dbclient_orders (
          id bigserial primary key,
          item_id bigint references dbclient_items(id),
          quantity integer not null default 1
        )]],
      [[insert into dbclient_items
          (name, "odd Name", amount, ratio, active, tags, payload, picture, created_at, day, note)
        values
          ('Łódź', 'quoted', 12345678901234567890.1234567890, 0.5, true,
           array['a','b'], '{"k":[1,2]}'::jsonb, '\x00ff10'::bytea,
           '2026-01-02 03:04:05+00', '2026-01-02', NULL),
          ('NULL', NULL, NULL, NULL, false, NULL, NULL, NULL, NULL, NULL, 'literal')]],
      "insert into dbclient_orders (item_id, quantity) values (1, 3), (1, 4)",
    },
    schema = "public",
    sleep = "select pg_sleep(30)",
  },

  mariadb = {
    drop = {
      "drop table if exists dbclient_orders",
      "drop table if exists dbclient_items",
    },
    create = {
      [[create table dbclient_items (
          id bigint auto_increment primary key,
          name varchar(255) not null,
          `odd Name` varchar(64),
          amount decimal(38,10),
          ratio double,
          active tinyint(1),
          payload json,
          picture blob,
          created_at datetime,
          day date,
          note text
        ) engine=InnoDB default charset=utf8mb4]],
      [[create table dbclient_orders (
          id bigint auto_increment primary key,
          item_id bigint,
          quantity int not null default 1,
          constraint fk_items foreign key (item_id) references dbclient_items(id)
        ) engine=InnoDB]],
      [[insert into dbclient_items
          (name, `odd Name`, amount, ratio, active, payload, picture, created_at, day, note)
        values
          ('Łódź', 'quoted', 12345678901234567890.1234567890, 0.5, 1,
           '{"k":[1,2]}', x'00ff10', '2026-01-02 03:04:05', '2026-01-02', NULL),
          ('NULL', NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, 'literal')]],
      "insert into dbclient_orders (item_id, quantity) values (1, 3), (1, 4)",
    },
    sleep = "select sleep(30)",
  },
}

local function column_index(result, name)
  for index, column in ipairs(result.columns) do
    if column.name == name then
      return index
    end
  end
end

local function suite(adapter, spec)
  local fixture = FIXTURES[adapter]
  local target = connect("test_" .. adapter, spec)
  local schema = fixture.schema or spec.database

  run(function()
    for _, statement in ipairs(fixture.drop) do
      pcall(session.query, target.id, statement)
    end
    for _, statement in ipairs(fixture.create) do
      session.query(target.id, statement)
    end
  end)

  t.describe(adapter .. ": metadata", {
    { "reports the server version", function()
      t.ok(#target.info.server_version > 0)
      t.ok(target.info.backend_pid ~= nil, "a backend pid is needed for cancellation")
    end },

    { "lists the fixture tables", function()
      run(function()
        local names = {}
        for _, entry in ipairs(session.tables(target.id, schema)) do
          names[entry.name] = true
        end
        t.ok(names.dbclient_items, "dbclient_items should be listed")
        t.ok(names.dbclient_orders)
      end)
    end },

    { "marks the primary key", function()
      run(function()
        t.eq(session.primary_key(target.id, schema, "dbclient_items"), { "id" })
      end)
    end },

    { "classifies column types", function()
      run(function()
        local classes = {}
        for _, column in ipairs(session.columns(target.id, schema, "dbclient_items")) do
          classes[column.name] = column.class
        end
        t.eq(classes.id, "number")
        t.eq(classes.name, "text")
        t.eq(classes.amount, "number")
        t.eq(classes.day, "temporal")
        t.eq(classes.created_at, "temporal")
        t.eq(classes.payload, "json")
        t.eq(classes.picture, "binary")
      end)
    end },

    { "finds foreign keys in both directions", function()
      run(function()
        local forward = session.foreign_keys(target.id, schema, "dbclient_orders")
        t.ok(#forward > 0, "dbclient_orders should have a foreign key")
        t.eq(forward[1].ref_table, "dbclient_items")

        local reverse = session.referencing_keys(target.id, schema, "dbclient_items")
        t.ok(#reverse > 0)
        t.eq(reverse[1].table, "dbclient_orders")
      end)
    end },

    { "lists indexes", function()
      run(function()
        local indexes = session.indexes(target.id, schema, "dbclient_items")
        t.ok(#indexes > 0)
      end)
    end },
  })

  t.describe(adapter .. ": values", {
    { "keeps NULL and the text NULL apart", function()
      run(function()
        local result = session.preview(target.id, {
          schema = schema,
          table = "dbclient_items",
        })
        local name = column_index(result, "name")
        local note = column_index(result, "note")

        t.eq(result.rows[1][note], vim.NIL, "a real NULL must arrive as JSON null")
        t.eq(result.rows[2][name], "NULL", "the literal string must survive")
        t.eq(result.rows[2][note], "literal")
      end)
    end },

    { "keeps full precision on wide numerics", function()
      run(function()
        local result = session.preview(target.id, { schema = schema, table = "dbclient_items" })
        local amount = result.rows[1][column_index(result, "amount")]
        t.matches(tostring(amount), "^12345678901234567890%.123456789")
      end)
    end },

    { "renders multibyte text intact", function()
      run(function()
        local result = session.preview(target.id, { schema = schema, table = "dbclient_items" })
        t.eq(result.rows[1][column_index(result, "name")], "Łódź")
      end)
    end },

    { "renders binary as hex", function()
      run(function()
        local result = session.preview(target.id, { schema = schema, table = "dbclient_items" })
        local picture = result.rows[1][column_index(result, "picture")]
        t.matches(tostring(picture), "^\\x00ff10$")
      end)
    end },

    { "renders a date without inventing a time", function()
      run(function()
        local result = session.preview(target.id, { schema = schema, table = "dbclient_items" })
        local day = result.rows[1][column_index(result, "day")]
        t.eq(tostring(day), "2026-01-02", "a DATE column must not gain a time component")
      end)
    end },

    { "handles quoted identifiers", function()
      run(function()
        local result = session.preview(target.id, { schema = schema, table = "dbclient_items" })
        t.ok(column_index(result, "odd Name") ~= nil, "a column with a space must round-trip")
      end)
    end },
  })

  t.describe(adapter .. ": querying", {
    { "orders previews by primary key", function()
      run(function()
        local first = session.preview(target.id, { schema = schema, table = "dbclient_items" })
        local second = session.preview(target.id, { schema = schema, table = "dbclient_items" })
        t.eq(first.rows[1][1], second.rows[1][1])
      end)
    end },

    { "applies filters, sorts and offsets", function()
      run(function()
        local filtered = session.preview(target.id, {
          schema = schema,
          table = "dbclient_items",
          filter = "name = 'Łódź'",
        })
        t.eq(#filtered.rows, 1)

        local sorted = session.preview(target.id, {
          schema = schema,
          table = "dbclient_items",
          order = { { column = "id", dir = "desc" } },
        })
        t.eq(sorted.rows[1][1], "2")

        local paged = session.preview(target.id, {
          schema = schema,
          table = "dbclient_items",
          limit = 1,
          offset = 1,
        })
        t.eq(#paged.rows, 1)
        t.eq(paged.rows[1][1], "2")
      end)
    end },

    { "counts rows", function()
      run(function()
        t.eq(session.count(target.id, { schema = schema, table = "dbclient_items" }), 2)
      end)
    end },

    { "rejects a filter that smuggles in a second statement", function()
      run(function()
        local ok = pcall(session.preview, target.id, {
          schema = schema,
          table = "dbclient_items",
          filter = "1=1; drop table dbclient_items",
        })
        t.falsy(ok)
      end)
    end },

    { "reports timings", function()
      run(function()
        local result = session.query(target.id, "select 1 as one")
        t.ok(result.elapsed_ms ~= nil)
        t.eq(result.rows[1][1], "1")
      end)
    end },
  })

  t.describe(adapter .. ": writing", {
    { "applies an update with an optimistic check", function()
      run(function()
        local change = {
          op = "update",
          schema = schema,
          table = "dbclient_items",
          set = { note = "written" },
          pk = { id = "1" },
          expect = { note = vim.NIL },
        }
        local outcome = session.apply_changes(target.id, { change })
        t.eq(outcome.affected_rows, 1)

        local result = session.preview(target.id, {
          schema = schema,
          table = "dbclient_items",
          filter = "id = 1",
        })
        t.eq(result.rows[1][column_index(result, "note")], "written")
      end)
    end },

    { "reports how many rows a plain statement touched", function()
      run(function()
        -- `affected_rows` belongs to the result set the driver is positioned
        -- on, and MariaDB's adapter used to read it *after* draining the row
        -- iterator — which had already moved past that set, so every UPDATE run
        -- through `query` reported zero while changing everything.
        local update = session.query(
          target.id,
          ("update %s.dbclient_items set note = 'counted' where id in (1, 2)"):format(schema)
        )
        t.eq(update.affected_rows, 2, "two rows matched, two reported")

        local none = session.query(
          target.id,
          ("update %s.dbclient_items set note = 'x' where id = -1"):format(schema)
        )
        t.eq(none.affected_rows, 0, "and nothing matched means nothing reported")

        -- A SELECT alongside it, to be sure the fix did not simply move the
        -- wrong number somewhere else.
        local rows = session.query(
          target.id,
          ("select id from %s.dbclient_items where note = 'counted' order by id"):format(schema)
        )
        t.eq(#rows.rows, 2, "the update really did land")

        -- Put the fixture back: the suite is ordered and the transaction tests
        -- below assert on these same rows.
        session.query(
          target.id,
          ("update %s.dbclient_items set note = 'written' where id = 1"):format(schema)
        )
        session.query(
          target.id,
          ("update %s.dbclient_items set note = null where id = 2"):format(schema)
        )
      end)
    end },

    { "refuses a stale update", function()
      run(function()
        local change = {
          op = "update",
          schema = schema,
          table = "dbclient_items",
          set = { note = "again" },
          pk = { id = "1" },
          expect = { note = "this was never the value" },
        }
        t.falsy(pcall(session.apply_changes, target.id, { change }))
      end)
    end },

    { "inserts and deletes", function()
      run(function()
        local insert = {
          op = "insert",
          schema = schema,
          table = "dbclient_items",
          values = { name = "inserted" },
        }
        session.apply_changes(target.id, { insert })
        t.eq(session.count(target.id, { schema = schema, table = "dbclient_items" }), 3)

        local result = session.preview(target.id, {
          schema = schema,
          table = "dbclient_items",
          filter = "name = 'inserted'",
        })
        local id = result.rows[1][1]
        session.apply_changes(target.id, {
          {
            op = "delete",
            schema = schema,
            table = "dbclient_items",
            pk = { id = id },
          },
        })
        t.eq(session.count(target.id, { schema = schema, table = "dbclient_items" }), 2)
      end)
    end },

    { "previews the SQL it would run", function()
      run(function()
        local statements = client.call("preview-changes", {
          changes = {
            {
              op = "update",
              schema = schema,
              table = "dbclient_items",
              set = { note = "peek" },
              pk = { id = "1" },
            },
          },
        }, target.id).statements
        t.eq(#statements, 1)
        t.matches(statements[1]:lower(), "update")
        t.matches(statements[1], "peek", "literals must be inlined in the preview")
      end)
    end },
  })

  t.describe(adapter .. ": transactions", {
    { "rolls back", function()
      run(function()
        session.begin(target.id)
        session.query(target.id, "update dbclient_items set note = 'tx' where id = 1")
        session.rollback(target.id)

        local result = session.preview(target.id, {
          schema = schema,
          table = "dbclient_items",
          filter = "id = 1",
        })
        t.eq(result.rows[1][column_index(result, "note")], "written")
      end)
    end },

    { "commits", function()
      run(function()
        session.begin(target.id)
        session.query(target.id, "update dbclient_items set note = 'committed' where id = 1")
        session.commit(target.id)

        local result = session.preview(target.id, {
          schema = schema,
          table = "dbclient_items",
          filter = "id = 1",
        })
        t.eq(result.rows[1][column_index(result, "note")], "committed")
      end)
    end },
  })

  t.describe(adapter .. ": introspection", {
    { "returns table DDL", function()
      run(function()
        local ddl = session.ddl(target.id, "table", schema, "dbclient_items")
        t.matches(ddl:lower(), "create table")
        t.matches(ddl, "dbclient_items")
      end)
    end },

    { "returns column statistics", function()
      run(function()
        local stats = session.column_stats(target.id, schema, "dbclient_items", "name")
        t.eq(stats.total, "2")
        t.ok(#stats.top > 0)
      end)
    end },

    { "explains a statement", function()
      run(function()
        local plan = session.explain(target.id, "select * from dbclient_items where id = 1", false)
        local lines = require("dbclient.ui.explain").render(plan)
        t.ok(#lines > 0)
      end)
    end },

    { "explains with analyze without leaving changes behind", function()
      run(function()
        session.explain(target.id, "update dbclient_items set note = note where id = 1", true)
        local result = session.preview(target.id, {
          schema = schema,
          table = "dbclient_items",
          filter = "id = 1",
        })
        t.eq(result.rows[1][column_index(result, "note")], "committed")
      end)
    end },

    { "lists server activity", function()
      run(function()
        local activity = session.activity(target.id)
        t.ok(#activity.columns > 0)
      end)
    end },

    { "reports table sizes", function()
      run(function()
        local sizes = session.table_sizes(target.id, schema)
        t.ok(#sizes.columns > 0)
      end)
    end },
  })

  t.describe(adapter .. ": blast radius and validation", {
    { "previews the rows a delete would remove", function()
      run(function()
        local report = client.call(
          "blast-radius",
          { sql = "delete from dbclient_items where name = 'Łódź'" },
          target.id
        )
        t.ok(report.supported)
        t.eq(report.count, 1)
        t.eq(#report.result.rows, 1)

        -- Previewing must not have changed anything.
        t.eq(session.count(target.id, { schema = schema, table = "dbclient_items" }), 2)
      end)
    end },

    { "previews the rows an update would touch", function()
      run(function()
        local report = client.call(
          "blast-radius",
          { sql = "update dbclient_items set note = 'x'" },
          target.id
        )
        t.ok(report.supported)
        t.eq(report.count, 2, "an unfiltered update touches every row")
      end)
    end },

    { "declines to preview what it cannot rewrite", function()
      run(function()
        local report = client.call(
          "blast-radius",
          { sql = "select * from dbclient_items" },
          target.id
        )
        t.falsy(report.supported)
      end)
    end },

    { "accepts a valid statement", function()
      run(function()
        local response = client.call(
          "validate",
          { sql = "select id, name from dbclient_items where id = 1" },
          target.id
        )
        t.eq(response.diagnostics, {})
      end)
    end },

    { "rejects an unknown column, without running anything", function()
      run(function()
        local response = client.call(
          "validate",
          { sql = "select no_such_column from dbclient_items" },
          target.id
        )
        t.eq(#response.diagnostics, 1)
        t.matches(response.diagnostics[1].message:lower(), "no_such_column")
      end)
    end },

    { "rejects an unknown table", function()
      run(function()
        local response = client.call(
          "validate",
          { sql = "select * from no_such_table_here" },
          target.id
        )
        t.eq(#response.diagnostics, 1)
      end)
    end },

    { "reports the offending statement of a script", function()
      run(function()
        local response = client.call(
          "validate",
          { sql = "select 1;\nselect * from no_such_table_here;" },
          target.id
        )
        t.eq(#response.diagnostics, 1)
        t.ok(response.diagnostics[1].start > 5, "the position points past the valid statement")
      end)
    end },

    { "does not execute what it validates", function()
      run(function()
        local before = session.count(target.id, { schema = schema, table = "dbclient_items" })
        client.call("validate", { sql = "delete from dbclient_items" }, target.id)
        t.eq(session.count(target.id, { schema = schema, table = "dbclient_items" }), before)
      end)
    end },
  })

  t.describe(adapter .. ": export", {
    { "streams a large result without loading it", function()
      run(function()
        -- Enough rows that a batch boundary is crossed several times, which is
        -- what exercises the cursor on PostgreSQL and the iterator elsewhere.
        session.query(target.id, "drop table if exists dbclient_big")
        session.query(
          target.id,
          adapter == "postgres"
            and "create table dbclient_big (id bigserial primary key, label text, amount numeric(12,2))"
            or "create table dbclient_big (id bigint auto_increment primary key, label varchar(64), amount decimal(12,2))"
        )
        for batch = 0, 4 do
          local values = {}
          for index = 1, 1000 do
            local id = batch * 1000 + index
            table.insert(values, ("('row %d', %d.25)"):format(id, id))
          end
          session.query(
            target.id,
            ("insert into dbclient_big (label, amount) values %s"):format(
              table.concat(values, ",")
            )
          )
        end

        local path = vim.fn.tempname() .. "/big"
        local outcome = client.call("export", {
          format = "csv",
          destination = path,
          sql = "select id, label, amount from dbclient_big order by id",
          batch_size = 250,
          manifest = false,
        }, target.id)

        t.eq(outcome.rows, 5000)
        local written = vim.fn.readfile(outcome.files[1].path)
        t.eq(#written, 5001, "a header plus every row")
        t.eq(written[1], "id,label,amount")
        t.matches(written[2], "^1,row 1,1%.25$")
        t.matches(written[#written], "^5000,row 5000,5000%.25$")
      end)
    end },

    { "keeps NULL apart from an empty string and from the text NULL", function()
      run(function()
        -- Built in the statement so the test does not depend on what earlier
        -- steps left in the table: one real NULL, one empty string, and one
        -- row whose value is the literal text "NULL".
        local path = vim.fn.tempname() .. "/nulls"
        local outcome = client.call("export", {
          format = "csv",
          destination = path,
          sql = table.concat({
            "select 'a' as label, cast(null as char(4)) as value",
            "union all select 'b', ''",
            "union all select 'c', 'NULL'",
          }, " "),
          null_as = "\\N",
          manifest = false,
        }, target.id)

        local written = vim.fn.readfile(outcome.files[1].path)
        table.sort(written)
        local text = table.concat(written, "|")
        t.matches(text, "a,\\N", "a real NULL uses the sentinel")
        t.matches(text, "b,|", "an empty string stays empty")
        t.matches(text, "c,NULL", "the literal string NULL is written as itself")
      end)
    end },

    { "writes a manifest with a checksum", function()
      run(function()
        local path = vim.fn.tempname() .. "/manifest"
        local outcome = client.call("export", {
          format = "csv",
          destination = path,
          sql = "select id, name from dbclient_items order by id",
          manifest = true,
          checksum = true,
        }, target.id)

        t.ok(outcome.manifest)
        local manifest = vim.json.decode(
          table.concat(vim.fn.readfile(outcome.manifest), "\n")
        )
        t.eq(manifest.rows, outcome.rows)
        t.eq(manifest.statement, "select id, name from dbclient_items order by id")
        t.eq(#manifest.columns, 2)
        t.matches(manifest.files[1].sha256, "^%x+$")
        t.eq(#manifest.files[1].sha256, 64)
      end)
    end },

    { "partitions by a column value", function()
      run(function()
        local path = vim.fn.tempname() .. "/parts"
        local outcome = client.call("export", {
          format = "csv",
          destination = path,
          sql = "select name, note from dbclient_items",
          partition_by = "name",
          manifest = false,
        }, target.id)

        t.eq(#outcome.files, 2, "one file per distinct value")
        for _, file in ipairs(outcome.files) do
          t.ok(file.partition ~= nil)
          t.eq(file.rows, 1)
        end
      end)
    end },

    { "exports a table with a filter, not just a statement", function()
      run(function()
        local path = vim.fn.tempname() .. "/table"
        local outcome = client.call("export", {
          format = "jsonl",
          destination = path,
          schema = schema,
          table = "dbclient_items",
          filter = "name = 'NULL'",
          manifest = false,
        }, target.id)

        t.eq(outcome.rows, 1)
        local line = vim.fn.readfile(outcome.files[1].path)[1]
        t.eq(vim.json.decode(line).name, "NULL")
      end)
    end },

    { "writes an xlsx that unzips", function()
      run(function()
        local path = vim.fn.tempname() .. "/book.xlsx"
        local outcome = client.call("export", {
          format = "xlsx",
          destination = path,
          sql = "select id, name, amount from dbclient_items order by id",
          manifest = false,
        }, target.id)

        local bytes = table.concat(vim.fn.readfile(outcome.files[1].path, "b"), "\n")
        t.matches(bytes:sub(1, 2), "PK", "an xlsx is a zip")
        t.ok(outcome.files[1].bytes > 500)
      end)
    end },

    { "previews without writing anything", function()
      run(function()
        local path = vim.fn.tempname() .. "/never.csv"
        local outcome = client.call("export", {
          format = "csv",
          destination = path,
          sql = "select id, name from dbclient_items",
          preview = true,
          preview_rows = 1,
        }, target.id)

        t.ok(outcome.preview ~= nil)
        t.eq(vim.fn.filereadable(path), 0, "a preview writes no file")
      end)
    end },

    { "refuses to overwrite unless told to", function()
      run(function()
        local path = vim.fn.tempname() .. "/once.csv"
        local settings = {
          format = "csv",
          destination = path,
          sql = "select 1 as one",
          manifest = false,
        }
        client.call("export", settings, target.id)
        t.falsy(pcall(client.call, "export", settings, target.id))

        settings.overwrite = true
        t.ok(pcall(client.call, "export", settings, target.id))
      end)
    end },

    { "cleans up the big fixture", function()
      run(function()
        session.query(target.id, "drop table if exists dbclient_big")
      end)
    end },
  })

  t.describe(adapter .. ": safety and cancellation", {
    { "cancels a long running statement", function()
      local finished, failed = false, nil
      client.async(function()
        session.query(target.id, fixture.sleep)
        finished = true
      end, function(err)
        failed = err
        finished = true
      end)

      -- Give the statement time to reach the server, then cancel it.
      vim.wait(700, function()
        return false
      end, 50)
      session.cancel(target.id)

      wait_for(function()
        return finished
      end, "cancellation")
      t.ok(failed ~= nil, "a cancelled statement should surface an error, not succeed")
    end },

    { "read-only sessions refuse writes", function()
      local readonly = connect(
        "readonly_" .. adapter,
        vim.tbl_extend("force", spec, { access = "read" })
      )
      run(function()
        session.query(readonly.id, "select 1")
        t.falsy(pcall(session.query, readonly.id, "delete from dbclient_items"))
      end)
      session.disconnect(readonly.id)
    end },

    { "sandbox sessions roll their writes back", function()
      local sandbox = connect(
        "sandbox_" .. adapter,
        vim.tbl_extend("force", spec, { access = "sandbox" })
      )
      run(function()
        session.apply_changes(sandbox.id, {
          {
            op = "update",
            schema = schema,
            table = "dbclient_items",
            set = { note = "sandboxed" },
            pk = { id = "1" },
          },
        })
        local result = session.preview(target.id, {
          schema = schema,
          table = "dbclient_items",
          filter = "id = 1",
        })
        t.eq(result.rows[1][column_index(result, "note")], "committed", "the write must not stick")
      end)
      session.disconnect(sandbox.id)
    end },
  })

  run(function()
    for _, statement in ipairs(fixture.drop) do
      pcall(session.query, target.id, statement)
    end
  end)
  session.disconnect(target.id)
end

local ran = false

if vim.env.DBCLIENT_TEST_POSTGRES then
  suite("postgres", parse_spec(vim.env.DBCLIENT_TEST_POSTGRES, "postgres"))
  ran = true
end

if vim.env.DBCLIENT_TEST_MARIADB then
  suite("mariadb", parse_spec(vim.env.DBCLIENT_TEST_MARIADB, "mariadb"))
  ran = true
end

if not ran then
  print("no adapter targets configured")
  print("set DBCLIENT_TEST_POSTGRES and/or DBCLIENT_TEST_MARIADB")
  vim.cmd("cquit 0")
end

client.stop()
local ok = t.report()
vim.cmd(ok and "cquit 0" or "cquit 1")

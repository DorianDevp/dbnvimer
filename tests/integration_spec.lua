--- End-to-end test: real daemon, real SQLite database, real buffers.
---
--- Skipped with a warning when the core binary has not been built, so the
--- suite still runs on a fresh checkout.

local t = require("tests.init")

local core = vim.fn.getcwd() .. "/rust/dbclient-core/target/release/dbclient-core"
if vim.fn.executable(core) ~= 1 then
  core = vim.fn.getcwd() .. "/rust/dbclient-core/target/debug/dbclient-core"
end

if vim.fn.executable(core) ~= 1 then
  print("\nintegration\n  SKIP  dbclient-core is not built (cargo build --release)")
  return
end

local client = require("dbclient.core.client")
local config = require("dbclient.config")
local data = require("dbclient.ui.data")
local grid = require("dbclient.ui.grid")
local keymap = require("dbclient.keymap")
local session = require("dbclient.session")

--- Pump the event loop until `predicate` holds.
local function wait_for(predicate, timeout, label)
  local ok = vim.wait(timeout or 8000, predicate, 20)
  if not ok then
    error("timed out waiting for " .. (label or "condition"), 2)
  end
end

--- Run a coroutine-style call and wait for it.
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
  end, 8000, "async call")
  if failure then
    error(failure, 2)
  end
end

local workdir = vim.fn.tempname()
vim.fn.mkdir(workdir, "p")
local db_path = workdir .. "/shop.db"

--- Build a throwaway database with the awkward values that used to break
--- rendering: multibyte text, embedded newlines, a pipe, a real NULL and the
--- literal string "NULL".
local function seed()
  local sql = table.concat({
    "create table customers (",
    "  id integer primary key,",
    "  name text not null,",
    "  city text,",
    "  note text",
    ");",
    "insert into customers (id, name, city, note) values",
    "  (1, 'Łódź', 'PL', NULL),",
    "  (2, 'NULL', 'DE', 'literal null'),",
    "  (3, 'Kraków', 'PL', 'has | pipe'),",
    "  (4, 'Gdańsk', NULL, 'two" .. "\n" .. "lines');",
    "create table orders (",
    "  id integer primary key,",
    "  customer_id integer references customers(id),",
    "  total real",
    ");",
    "insert into orders values (10, 1, 99.5), (11, 1, 10.0), (12, 3, 5.25);",
  }, "\n")

  local script = workdir .. "/seed.sql"
  vim.fn.writefile(vim.split(sql, "\n"), script)
  local result = vim.system({ "sqlite3", db_path }, { stdin = sql, text = true }):wait()
  if result.code ~= 0 then
    -- No sqlite3 binary: build the database through the core instead.
    return false
  end
  return true
end

local seeded = seed()

config.setup({
  core = { command = core },
  detect = { enabled = false },
  store = { enabled = false },
  history = { enabled = false, path = workdir .. "/history.jsonl" },
  connections = {
    testdb = { adapter = "sqlite", path = db_path },
  },
})

if not seeded then
  -- Fall back to creating the schema over the protocol.
  local target
  session.connect("testdb", function(result)
    target = result
  end)
  wait_for(function()
    return target ~= nil
  end, 8000, "connection")
  run(function()
    for _, statement in ipairs({
      "create table customers (id integer primary key, name text not null, city text, note text)",
      "insert into customers values (1, 'Łódź', 'PL', NULL)",
      "insert into customers values (2, 'NULL', 'DE', 'literal null')",
      "insert into customers values (3, 'Kraków', 'PL', 'has | pipe')",
      "insert into customers values (4, 'Gdańsk', NULL, 'two" .. "\n" .. "lines')",
      "create table orders (id integer primary key, customer_id integer references customers(id), total real)",
      "insert into orders values (10, 1, 99.5), (11, 1, 10.0), (12, 3, 5.25)",
    }) do
      session.query(target.id, statement)
    end
  end)
  session.disconnect(target.id)
end

-- ---------------------------------------------------------------------------

local connected
t.describe("integration: connection", {
  { "opens a session against the core daemon", function()
    session.connect("testdb", function(target, err)
      connected = target or err
    end)
    wait_for(function()
      return connected ~= nil
    end, 8000, "connect")
    t.ok(type(connected) == "table", "connect failed: " .. tostring(connected))
    t.eq(connected.name, "testdb")
    t.matches(connected.info.server_version, "SQLite")
  end },

  { "reports the core version", function()
    t.ok(client.version ~= nil, "the daemon should have announced its version")
  end },})

t.describe("integration: metadata", {
  { "lists schemas, tables and columns", function()
    run(function()
      local schemas = session.schemas(connected.id)
      t.ok(#schemas > 0)

      local tables = {}
      for _, entry in ipairs(session.tables(connected.id, "main")) do
        table.insert(tables, entry.name)
      end
      table.sort(tables)
      t.eq(tables, { "customers", "orders" })

      local columns = session.columns(connected.id, "main", "customers")
      t.eq(columns[1].name, "id")
      t.eq(columns[1].key, "PRI")
      t.eq(session.primary_key(connected.id, "main", "customers"), { "id" })
    end)
  end },

  { "finds foreign keys in both directions", function()
    run(function()
      local forward = session.foreign_keys(connected.id, "main", "orders")
      t.eq(forward[1].ref_table, "customers")

      local reverse = session.referencing_keys(connected.id, "main", "customers")
      t.eq(reverse[1].table, "orders")
    end)
  end },})

-- ---------------------------------------------------------------------------

local view

t.describe("integration: data buffer", {
  { "renders awkward values without corrupting the grid", function()
    data.open({ session_id = connected.id, schema = "main", table = "customers" })
    wait_for(function()
      for _, candidate in pairs(data.views) do
        if candidate.table == "customers" and (candidate.generation or 0) > 0 then
          view = candidate
          return true
        end
      end
      return false
    end, 8000, "data buffer")
    t.eq(#view.rows, 4)

    local lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
    t.eq(#lines, data.HEADER_LINES + 4)

    for _, line in ipairs(lines) do
      t.falsy(line:find("\n"), "no rendered line may contain a raw newline")
    end

    -- Every data line has the same display width, which is what proves the
    -- multibyte names did not shift their columns.
    local widths = {}
    for index = data.HEADER_LINES + 1, #lines do
      widths[#widths + 1] = vim.fn.strdisplaywidth(lines[index])
    end
    for _, width in ipairs(widths) do
      t.eq(width, widths[1], "rows must align")
    end
  end },

  { "distinguishes SQL NULL from the text NULL", function()
    local lines = vim.api.nvim_buf_get_lines(view.bufnr, data.HEADER_LINES, -1, false)
    local first = grid.parse_row(lines[1])
    local second = grid.parse_row(lines[2])

    t.eq(first[2], "Łódź")
    t.eq(first[4], config.get().ui.null_display, "a real NULL renders as the placeholder")
    t.eq(second[2], "NULL", "the literal string NULL renders verbatim")
    t.eq(grid.parse_value(first[4], view.columns[4]), vim.NIL)
    t.eq(grid.parse_value(second[2], view.columns[2]), "NULL")
  end },

  { "escapes separators and newlines reversibly", function()
    local lines = vim.api.nvim_buf_get_lines(view.bufnr, data.HEADER_LINES, -1, false)
    local third = grid.parse_row(lines[3])
    local fourth = grid.parse_row(lines[4])

    t.eq(grid.parse_value(third[4], view.columns[4]), "has | pipe")
    t.eq(grid.parse_value(fourth[4], view.columns[4]), "two\nlines")
  end },

  { "reports no pending changes for an untouched buffer", function()
    local pending = data.pending(view)
    t.eq(pending.changes, {})
    t.eq(pending.errors, {})
  end },})

t.describe("integration: editing", {
  { "an edited cell becomes an UPDATE and reaches the database", function()
    local line_number = data.HEADER_LINES + 1
    local line = vim.api.nvim_buf_get_lines(view.bufnr, line_number - 1, line_number, false)[1]
    local edited = line:gsub("Łódź", "Ł0dź", 1)
    vim.api.nvim_buf_set_lines(view.bufnr, line_number - 1, line_number, false, { edited })

    local pending = data.pending(view)
    t.eq(#pending.changes, 1)
    t.eq(pending.changes[1].op, "update")
    t.eq(pending.changes[1].set.name, "Ł0dź")
    t.eq(pending.changes[1].pk, { id = "1" })

    run(function()
      local outcome = session.apply_changes(connected.id, pending.changes)
      t.eq(outcome.affected_rows, 1)
      local result = session.preview(connected.id, {
        schema = "main",
        table = "customers",
        filter = "id = 1",
      })
      t.eq(result.rows[1][2], "Ł0dź")
    end)
  end },

  { "deleting a line becomes a DELETE", function()
    run(function()
      data.render(view) -- resync the snapshot after the update above
    end)

    local line_number = data.HEADER_LINES + 2
    vim.api.nvim_buf_set_lines(view.bufnr, line_number - 1, line_number, false, {})

    local pending = data.pending(view)
    t.eq(#pending.changes, 1)
    t.eq(pending.changes[1].op, "delete")
    t.eq(pending.changes[1].pk, { id = "2" })
  end },

  { "a new line becomes an INSERT", function()
    data.render(view)

    local sizes = view.sizes
    local new_line = grid.render_row({ "99", "Nowy", "PL", vim.NIL }, view.columns, sizes)
    local count = vim.api.nvim_buf_line_count(view.bufnr)
    vim.api.nvim_buf_set_lines(view.bufnr, count, count, false, { new_line })

    local pending = data.pending(view)
    t.eq(#pending.changes, 1)
    t.eq(pending.changes[1].op, "insert")
    t.eq(pending.changes[1].values.id, "99")
    t.eq(pending.changes[1].values.name, "Nowy")

    run(function()
      session.apply_changes(connected.id, pending.changes)
      local total = session.count(connected.id, { schema = "main", table = "customers" })
      t.eq(total, 5)
    end)
  end },

  { "a stale expectation is refused instead of overwriting", function()
    run(function()
      local change = {
        op = "update",
        schema = "main",
        table = "customers",
        set = { city = "CZ" },
        pk = { id = "3" },
        expect = { city = "this was never the value" },
      }
      local ok = pcall(session.apply_changes, connected.id, { change })
      t.falsy(ok, "a conflicting update must fail loudly")
    end)
  end },})

t.describe("integration: filtering, sorting and paging", {
  { "filters restrict the rows", function()
    run(function()
      local result = session.preview(connected.id, {
        schema = "main",
        table = "customers",
        filter = "city = 'PL'",
      })
      t.eq(#result.rows, 3)
    end)
  end },

  { "sorting is explicit and stable", function()
    run(function()
      local result = session.preview(connected.id, {
        schema = "main",
        table = "customers",
        order = { { column = "id", dir = "desc" } },
      })
      t.eq(result.rows[1][1], "99")
    end)
  end },

  { "previews are ordered by primary key by default", function()
    run(function()
      local first = session.preview(connected.id, { schema = "main", table = "customers" })
      local second = session.preview(connected.id, { schema = "main", table = "customers" })
      t.eq(first.rows[1][1], second.rows[1][1], "row order must be stable between fetches")
    end)
  end },

  { "paging uses offset", function()
    run(function()
      local page = session.preview(connected.id, {
        schema = "main",
        table = "customers",
        limit = 2,
        offset = 2,
      })
      t.eq(#page.rows, 2)
    end)
  end },})

t.describe("integration: transactions", {
  { "a rollback undoes the change", function()
    run(function()
      session.begin(connected.id)
      t.ok(connected.in_transaction)
      session.query(connected.id, "update customers set city = 'XX' where id = 3")
      session.rollback(connected.id)
      t.falsy(connected.in_transaction)

      local result = session.preview(connected.id, {
        schema = "main",
        table = "customers",
        filter = "id = 3",
      })
      t.eq(result.rows[1][3], "PL")
    end)
  end },})

t.describe("integration: safety", {
  { "read-only sessions refuse writes", function()
    config.get().connections.readonly_db = {
      adapter = "sqlite",
      path = db_path,
      access = "read",
    }

    local readonly
    session.connect("readonly_db", function(target, err)
      readonly = target or err
    end)
    wait_for(function()
      return readonly ~= nil
    end, 8000, "read-only connect")
    t.ok(type(readonly) == "table", tostring(readonly))

    run(function()
      session.query(readonly.id, "select 1")
      local ok = pcall(session.query, readonly.id, "delete from customers")
      t.falsy(ok, "a read-only session must refuse a delete")
    end)

    session.disconnect(readonly.id)
  end },

  { "the linter flags an unfiltered delete", function()
    run(function()
      local response = client.call("lint-sql", { sql = "delete from customers;" })
      t.eq(response.diagnostics[1].code, "unfiltered-write")
    end)
  end },})

t.describe("integration: derived views", {
  { "column statistics come back with a top-values list", function()
    run(function()
      local stats = session.column_stats(connected.id, "main", "customers", "city")
      t.ok(tonumber(stats.total) >= 4)
      t.ok(#stats.top > 0)
    end)
  end },

  { "DDL round-trips the table", function()
    run(function()
      local ddl = session.ddl(connected.id, "table", "main", "customers")
      t.matches(ddl:lower(), "create table customers")
    end)
  end },

  { "explain returns a plan", function()
    run(function()
      local plan = session.explain(connected.id, "select * from customers where id = 1", false)
      t.ok(plan.format ~= nil)
      local lines = require("dbclient.ui.explain").render(plan)
      t.ok(#lines > 0)
    end)
  end },})

t.describe("integration: mappings", {
  { "every mapped action has a handler", function()
    local groups = {
      data = require("dbclient.ui.data").handlers(),
      global = require("dbclient").handlers(),
    }
    for group, handlers in pairs(groups) do
      local missing = keymap.missing_handlers(group, handlers)
      t.eq(missing, {}, ("group `%s` is missing handlers"):format(group))
    end
  end },

  { "the data buffer registers its mappings", function()
    local mapped = {}
    for _, entry in ipairs(vim.api.nvim_buf_get_keymap(view.bufnr, "n")) do
      mapped[entry.lhs] = true
    end
    for _, entry in ipairs(keymap.groups.data.keys) do
      local lhs = entry.lhs:gsub("<leader>", vim.g.mapleader or "\\")
      t.ok(mapped[lhs] or mapped[entry.lhs], "missing mapping " .. entry.lhs)
    end
  end },

  { "text objects are registered", function()
    local mapped = {}
    for _, entry in ipairs(vim.api.nvim_buf_get_keymap(view.bufnr, "o")) do
      mapped[entry.lhs] = true
    end
    for _, lhs in ipairs({ "ic", "ac", "ir", "ar", "iC", "aC" }) do
      t.ok(mapped[lhs], "missing text object " .. lhs)
    end
  end },

  { "help renders for every group", function()
    for _, group in ipairs(keymap.order) do
      local lines = keymap.help_lines(group)
      t.ok(#lines > 3, "help for " .. group .. " is empty")
    end
  end },})

t.describe("integration: notebooks, diagrams and import", {
  { "runs a SQL block in a markdown buffer and writes the result back", function()
    local notebook = require("dbclient.notebook")
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "# analysis",
      "",
      "```sql",
      "select count(*) as total from customers;",
      "```",
    })
    vim.api.nvim_win_set_buf(0, bufnr)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })

    notebook.run_block()
    wait_for(function()
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      return vim.tbl_contains(lines, notebook.RESULT_OPEN)
    end, 8000, "notebook result")

    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    t.matches(text, "| total |", "the result is written back as a markdown table")
    t.matches(text, "row%(s%) in")

    -- Running again replaces the result rather than stacking another one.
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    notebook.run_block()
    vim.wait(1500, function()
      return false
    end, 50)
    local _, count = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
      :gsub(vim.pesc(notebook.RESULT_OPEN), "")
    t.eq(count, 1, "a re-run must replace the previous result")
  end },

  { "builds an ER diagram from the real foreign keys", function()
    local done = false
    require("dbclient.diagram").show({ session_id = connected.id, schema = "main" })
    wait_for(function()
      done = vim.fn.bufnr("dbclient://testdb/main.diagram.md") > 0
      return done
    end, 8000, "diagram")

    local bufnr = vim.fn.bufnr("dbclient://testdb/main.diagram.md")
    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    t.matches(text, "erDiagram")
    t.matches(text, "orders }o%-%-|| customers")
    t.matches(text, "PK")
  end },

  { "imports a CSV through the change-set path", function()
    local import = require("dbclient.import")
    local path = vim.fn.tempname() .. ".csv"
    vim.fn.writefile({ "id,name,city", "500,Imported,PL", "501,Second,DE" }, path)

    local data = import.read(path)
    t.eq(data.header, { "id", "name", "city" })
    t.eq(#data.rows, 2)

    -- Drive the insert directly; the interactive path only adds the prompt.
    local changes = {}
    for _, row in ipairs(data.rows) do
      table.insert(changes, {
        op = "insert",
        schema = "main",
        table = "customers",
        values = { id = row[1], name = row[2], city = row[3] },
      })
    end

    run(function()
      local before = session.count(connected.id, { schema = "main", table = "customers" })
      session.apply_changes(connected.id, changes)
      local after = session.count(connected.id, { schema = "main", table = "customers" })
      t.eq(after, before + 2)
    end)
  end },

  { "watch highlights only what changed between runs", function()
    local watch = require("dbclient.watch")
    run(function()
      local first = session.query(connected.id, "select id, city from customers order by id")
      session.query(connected.id, "update customers set city = 'ZZ' where id = 500")
      local second = session.query(connected.id, "select id, city from customers order by id")

      local changed = watch.diff_rows(first.rows, second.rows)
      local marked = 0
      for _ in pairs(changed) do
        marked = marked + 1
      end
      t.eq(marked, 1, "exactly one row differs")
    end)
  end },

  { "snapshots round-trip through a file", function()
    run(function()
      local result = session.preview(connected.id, { schema = "main", table = "customers" })
      local snapshot = require("dbclient.snapshot")
      local path = snapshot.save(result, "integration-test")
      t.ok(vim.fn.filereadable(path) == 1)

      local written = vim.fn.readfile(path)
      local body = vim.tbl_filter(function(line)
        return not line:match("^%-%-") and line ~= ""
      end, written)
      t.eq(#body, #result.rows)
      t.matches(body[1], "id=")
    end)
  end },

  { "the undo log inverts what the data buffer wrote", function()
    local undolog = require("dbclient.undolog")
    undolog.entries = {}

    local change = {
      op = "update",
      schema = "main",
      table = "customers",
      set = { city = "XX" },
      pk = { id = "500" },
      expect = { city = "ZZ" },
    }

    run(function()
      session.apply_changes(connected.id, { change })
    end)
    undolog.record({
      connection = connected.name,
      changes = { change },
      statements = { "update ..." },
    })

    local entry = undolog.entries[#undolog.entries]
    t.eq(entry.undoable, 1)

    run(function()
      local inverse = undolog.invert(change)
      session.apply_changes(connected.id, { inverse })
      local result = session.preview(connected.id, {
        schema = "main",
        table = "customers",
        filter = "id = 500",
      })
      t.eq(result.rows[1][3], "ZZ", "the compensating update restored the value")
    end)
  end },})

t.describe("integration: shutdown", {
  { "closing a session leaves the daemon healthy", function()
    session.disconnect(connected.id)
    run(function()
      local sessions = client.call("sessions").sessions
      t.eq(#sessions, 0)
    end)
    client.stop()
  end },})

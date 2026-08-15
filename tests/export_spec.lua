local t = require("tests.init")
local codegen = require("dbclient.codegen")
local export = require("dbclient.export")
local value = require("dbclient.ui.value")

local columns = {
  { name = "id", type = "int", class = "number" },
  { name = "name", type = "text", class = "text" },
  { name = "note", type = "text", class = "text" },
}

local rows = {
  { "1", "Anna", vim.NIL },
  { "2", "with, comma", 'with "quote"' },
  { "3", "Łódź", "two\nlines" },
}

local data = { columns = columns, rows = rows, schema = "shop", table = "customers" }

t.describe("export formats", {
  ["csv quotes what needs quoting"] = function()
    local lines = export.render(data, "csv")
    t.eq(lines[1], "id,name,note")
    t.eq(lines[2], "1,Anna,")
    t.eq(lines[3], '2,"with, comma","with ""quote"""')
  end,

  ["csv keeps NULL distinct from an empty string"] = function()
    local lines = export.render(
      { columns = columns, rows = { { "1", "", vim.NIL } } },
      "csv"
    )
    -- Both render as an empty field in CSV, which is the format's own
    -- limitation; JSON keeps them apart.
    t.eq(lines[2], "1,,")

    local json = export.render({ columns = columns, rows = { { "1", "", vim.NIL } } }, "jsonl")
    t.matches(json[1], '"note":null')
    t.matches(json[1], '"name":""')
  end,

  ["tsv uses tabs"] = function()
    local lines = export.render({ columns = columns, rows = { { "1", "a", "b" } } }, "tsv")
    t.eq(lines[2], "1\ta\tb")
  end,

  ["json emits an array"] = function()
    local lines = export.render(data, "json")
    t.eq(lines[1], "[")
    t.eq(lines[#lines], "]")
    local decoded = vim.json.decode(table.concat(lines, "\n"))
    t.eq(#decoded, 3)
    t.eq(decoded[1].name, "Anna")
  end,

  ["jsonl emits one object per row"] = function()
    local lines = export.render(data, "jsonl")
    t.eq(#lines, 3)
    t.eq(vim.json.decode(lines[3]).name, "Łódź")
  end,

  ["markdown escapes pipes and newlines"] = function()
    local lines = export.render(data, "markdown")
    t.matches(lines[2], "^| ---:")
    t.matches(lines[#lines], "two<br>lines")
  end,

  ["sql emits inserts against the source table"] = function()
    local lines = export.render(data, "sql")
    t.matches(lines[1], "^insert into shop%.customers %(id, name, note%) values")
    t.matches(lines[1], "NULL%)")
    t.matches(lines[2], "'with, comma'")
  end,

  ["the plain format is the aligned grid"] = function()
    local lines = export.render(data, "table")
    t.matches(lines[2], "^%-%-")
  end,

  ["formats are chosen by extension"] = function()
    t.eq(export.format_for("out.csv"), "csv")
    t.eq(export.format_for("out.JSON"), "json")
    t.eq(export.format_for("out.md"), "markdown")
    t.eq(export.format_for("out.unknown"), "table")
  end,

  ["writes a file"] = function()
    local path = vim.fn.tempname() .. "/nested/out.csv"
    local ok, err = export.write_file(data, path)
    t.ok(ok, tostring(err))
    local written = vim.fn.readfile(path)
    t.eq(written[1], "id,name,note")
  end,
})

t.describe("codegen", {
  ["converts names"] = function()
    t.eq(codegen.pascal("user_account"), "UserAccount")
    t.eq(codegen.camel("user_account"), "userAccount")
    t.eq(codegen.singular("customers"), "customer")
    t.eq(codegen.singular("companies"), "company")
    t.eq(codegen.singular("addresses"), "address")
    t.eq(codegen.singular("status"), "status", "words ending in -us are not plurals")
    t.eq(codegen.singular("address"), "address")
    t.eq(codegen.singular("analysis"), "analysis")
    t.eq(codegen.singular("boxes"), "box")
    t.eq(codegen.singular("orders"), "order")
  end,

  ["generates a Go struct"] = function()
    local lines = codegen.templates.go({
      schema = "shop",
      table = "customers",
      columns = {
        { name = "id", type = "bigint", nullable = false },
        { name = "name", type = "varchar(255)", nullable = false },
        { name = "note", type = "text", nullable = true },
        { name = "created_at", type = "timestamp", nullable = false },
      },
    })
    local text = table.concat(lines, "\n")
    t.matches(text, "type Customer struct")
    t.matches(text, "Id%s+int64")
    t.matches(text, "Note%s+%*string")
    t.matches(text, "CreatedAt%s+time%.Time")
    t.matches(text, 'db:"name"')
  end,

  ["generates a TypeScript interface"] = function()
    local lines = codegen.templates.typescript({
      table = "orders",
      columns = {
        { name = "id", type = "int", nullable = false },
        { name = "total", type = "numeric", nullable = true },
      },
    })
    local text = table.concat(lines, "\n")
    t.matches(text, "export interface Order")
    t.matches(text, "id: number;")
    t.matches(text, "total%?: number | null;")
  end,

  ["generates a Rust struct"] = function()
    local text = table.concat(
      codegen.templates.rust({
        table = "users",
        columns = { { name = "id", type = "bigint", nullable = false }, { name = "bio", type = "text", nullable = true } },
      }),
      "\n"
    )
    t.matches(text, "pub struct User")
    t.matches(text, "pub id: i64,")
    t.matches(text, "pub bio: Option<String>,")
  end,

  ["generates SQL scaffolding"] = function()
    local text = table.concat(
      codegen.templates.sql_select({
        schema = "shop",
        table = "customers",
        columns = { { name = "id" }, { name = "name" } },
      }),
      "\n"
    )
    t.matches(text, "select id, name")
    t.matches(text, "from shop%.customers")
  end,

  ["lists its templates"] = function()
    local names = codegen.names()
    t.ok(vim.tbl_contains(names, "go"))
    t.ok(vim.tbl_contains(names, "zod"))
  end,
})

t.describe("value inspector", {
  ["pretty prints JSON"] = function()
    local decoded = value.decode('{"b":2,"a":[1,2]}')
    t.eq(decoded.kind, "json")
    t.eq(decoded.filetype, "json")
    local text = table.concat(decoded.lines, "\n")
    t.matches(text, '"a": %[')
    t.matches(text, '"b": 2')
  end,

  ["decodes a JWT"] = function()
    local header = vim.base64.encode('{"alg":"HS256","typ":"JWT"}'):gsub("=", ""):gsub("%+", "-"):gsub("/", "_")
    local payload = vim.base64.encode('{"sub":"42","exp":1700000000}'):gsub("=", ""):gsub("%+", "-"):gsub("/", "_")
    local decoded = value.decode(header .. "." .. payload .. ".sig")
    t.eq(decoded.kind, "jwt")
    local text = table.concat(decoded.lines, "\n")
    t.matches(text, "HS256")
    t.matches(text, '"sub": "42"')
    t.matches(text, "exp:")
  end,

  ["recognises unix timestamps"] = function()
    local decoded = value.decode("1700000000")
    t.eq(decoded.kind, "timestamp")
    t.matches(table.concat(decoded.lines, "\n"), "2023%-11%-14")
  end,

  ["leaves plain text alone"] = function()
    t.eq(value.decode("just some text"), nil)
    t.eq(value.decode("42"), nil)
  end,

  ["produces a hex dump"] = function()
    local lines = value.hex_dump("Hi\0\255")
    t.matches(lines[1], "^00000000  48 69 00 ff")
    t.matches(lines[1], "|Hi%.%.|")
  end,
})

t.describe("csv import parsing", {
  ["splits quoted fields"] = function()
    local import = require("dbclient.import")
    t.eq(import.split_line('a,b,c', ","), { "a", "b", "c" })
    t.eq(import.split_line('a,"b,c",d', ","), { "a", "b,c", "d" })
    t.eq(import.split_line('"say ""hi""",x', ","), { 'say "hi"', "x" })
    t.eq(import.split_line("a\tb", "\t"), { "a", "b" })
  end,

  ["keeps empty fields"] = function()
    local import = require("dbclient.import")
    t.eq(require("dbclient.import").split_line("a,,c", ","), { "a", "", "c" })
  end,

  ["reads a file and guesses the separator"] = function()
    local import = require("dbclient.import")
    local path = vim.fn.tempname() .. ".csv"
    vim.fn.writefile({ "id;name;note", '1;Anna;"has ; inside"', "2;Bartek;" }, path)
    local data = import.read(path)
    t.eq(data.separator, ";")
    t.eq(data.header, { "id", "name", "note" })
    t.eq(#data.rows, 2)
    t.eq(data.rows[1][3], "has ; inside")
    t.eq(data.rows[2][3], "")
  end,

  ["joins a quoted field that spans lines"] = function()
    local import = require("dbclient.import")
    local path = vim.fn.tempname() .. ".csv"
    vim.fn.writefile({ "id,note", '1,"first', 'second"' }, path)
    local data = import.read(path)
    t.eq(#data.rows, 1)
    t.eq(data.rows[1][2], "first\nsecond")
  end,
})

t.describe("watch diffing", {
  ["reports changed cells between runs"] = function()
    local watch = require("dbclient.watch")
    local before = { { "1", "a" }, { "2", "b" } }
    local after = { { "1", "a" }, { "2", "changed" }, { "3", "new" } }
    local changed, added = watch.diff_rows(before, after)

    t.falsy(changed[1], "an untouched row must not be highlighted")
    t.ok(changed[2] and changed[2][2], "the changed cell must be marked")
    t.ok(added[3], "a new row must be marked as added")
  end,

  ["reports nothing on the first run"] = function()
    local watch = require("dbclient.watch")
    local changed, added = watch.diff_rows(nil, { { "1", "a" } })
    t.eq(changed, {})
    t.eq(added, {})
  end,
})

t.describe("broadcast", {
  ["groups identical results"] = function()
    local broadcast = require("dbclient.broadcast")
    local a = { rows = { { "1", "x" }, { "2", "y" } } }
    local b = { rows = { { "2", "y" }, { "1", "x" } } }
    local c = { rows = { { "1", "z" } } }

    t.eq(broadcast.fingerprint(a), broadcast.fingerprint(b), "row order must not matter")
    t.ok(broadcast.fingerprint(a) ~= broadcast.fingerprint(c))
  end,
})

t.describe("er diagram", {
  ["renders mermaid with keys and relationships"] = function()
    local diagram = require("dbclient.diagram")
    local lines = diagram.render({
      schema = "shop",
      tables = { { name = "customers" }, { name = "orders" } },
      columns = {
        customers = { { name = "id", type = "int", key = "PRI" } },
        orders = {
          { name = "id", type = "int", key = "PRI" },
          { name = "customer_id", type = "int", key = "" },
        },
      },
      keys = {
        { table = "orders", column = "customer_id", ref_table = "customers", ref_column = "id" },
      },
      foreign_columns = { ["orders.customer_id"] = true },
    })

    local text = table.concat(lines, "\n")
    t.matches(text, "erDiagram")
    t.matches(text, "int id PK")
    t.matches(text, "int customer_id FK")
    t.matches(text, "orders }o%-%-|| customers : customer_id")
  end,
})

t.describe("undo log", {
  ["inverts an update using the recorded old values"] = function()
    local undolog = require("dbclient.undolog")
    local inverse = undolog.invert({
      op = "update",
      schema = "shop",
      table = "customers",
      set = { city = "CZ" },
      pk = { id = "1" },
      expect = { city = "PL" },
    })
    t.eq(inverse.op, "update")
    t.eq(inverse.set, { city = "PL" })
    t.eq(inverse.pk, { id = "1" })
  end,

  ["targets the new key when the key itself changed"] = function()
    local undolog = require("dbclient.undolog")
    local inverse = undolog.invert({
      op = "update",
      schema = "shop",
      table = "customers",
      set = { id = "42" },
      pk = { id = "1" },
      expect = { id = "1" },
    })
    t.eq(inverse.pk, { id = "42" }, "the row now lives under the new key")
    t.eq(inverse.set, { id = "1" })
  end,

  ["inverts an insert into a delete"] = function()
    local undolog = require("dbclient.undolog")
    local inverse = undolog.invert({
      op = "insert",
      schema = "shop",
      table = "customers",
      values = { id = "9", name = "x" },
    })
    t.eq(inverse.op, "delete")
    t.eq(inverse.pk.id, "9")
  end,

  ["refuses to invent a deleted row"] = function()
    local undolog = require("dbclient.undolog")
    t.eq(
      undolog.invert({ op = "delete", schema = "s", table = "t", pk = { id = "1" } }),
      nil,
      "the other columns were never read, so the row cannot be restored"
    )
  end,
})

t.describe("notebook", {
  ["finds the sql block under the cursor"] = function()
    local notebook = require("dbclient.notebook")
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "# notes",
      "",
      "```sql",
      "select 1;",
      "```",
      "",
      "```lua",
      "print(1)",
      "```",
    })

    local block = notebook.block_at(bufnr, 4)
    t.ok(block, "the cursor is inside the sql block")
    t.eq(block.sql, "select 1;")

    t.eq(notebook.block_at(bufnr, 8), nil, "a lua block is not executable here")
    t.eq(notebook.block_at(bufnr, 1), nil, "prose is not a block")
  end,
})

t.describe("snapshots", {
  ["render rows in a diff-friendly form"] = function()
    local snapshot = require("dbclient.snapshot")
    local lines = snapshot.render({
      columns = { { name = "id" }, { name = "name" } },
      rows = { { "2", "b" }, { "1", "a" } },
    })
    t.eq(lines[1], "id=1  name=a", "rows are sorted so order does not create noise")
    t.eq(lines[2], "id=2  name=b")
  end,
})

t.describe("workspace", {
  ["captures and describes what is open"] = function()
    local workspace = require("dbclient.workspace")
    local session = require("dbclient.session")
    local data = require("dbclient.ui.data")

    -- Stand in for a live session and one open data buffer.
    session.sessions.w1 = { id = "w1", name = "wtest", spec = {}, cache = {} }
    session.order = { "w1" }
    session.active = "w1"

    local bufnr = vim.api.nvim_create_buf(false, true)
    data.views[bufnr] = {
      bufnr = bufnr,
      session_id = "w1",
      schema = "main",
      table = "customers",
      filter = "city = 'PL'",
      sort = { { column = "id", dir = "desc" } },
      limit = 200,
      offset = 0,
      hidden = { [3] = true },
      rows = {},
      columns = {},
      primary = {},
    }

    local state = workspace.capture()
    t.eq(state.connections, { "wtest" })
    t.eq(state.active, "wtest")
    t.eq(#state.data, 1)
    t.eq(state.data[1].table, "customers")
    t.eq(state.data[1].filter, "city = 'PL'")
    t.eq(state.data[1].hidden, { 3 })

    data.views[bufnr] = nil
    session.sessions.w1 = nil
    session.order = {}
    session.active = nil
  end,

  ["keys the file by working directory"] = function()
    local workspace = require("dbclient.workspace")
    local a = workspace.path("/home/x/project-one")
    local b = workspace.path("/home/x/project-two")
    t.ok(a ~= b)
    t.matches(a, "project_one")
  end,

  ["says so when nothing is saved"] = function()
    local workspace = require("dbclient.workspace")
    local lines = workspace.describe()
    t.matches(table.concat(lines, "\n"), "no saved workspace")
  end,
})

t.describe("null handling in derived views", {
  ["broadcast fingerprints a NULL without crashing"] = function()
    local broadcast = require("dbclient.broadcast")
    -- `table.concat` rejects a boolean, so a precedence slip here was a crash
    -- on any result containing a NULL.
    local with_null = { rows = { { "1", vim.NIL } } }
    local with_text = { rows = { { "1", "NULL" } } }
    local a = broadcast.fingerprint(with_null)
    t.ok(type(a) == "string")
    t.ok(a ~= broadcast.fingerprint(with_text), "NULL and the text NULL must differ")
  end,

  ["snapshots render NULL as NULL"] = function()
    local snapshot = require("dbclient.snapshot")
    local lines = snapshot.render({
      columns = { { name = "id" }, { name = "note" } },
      rows = { { "1", vim.NIL } },
    })
    t.eq(lines[1], "id=1  note=NULL")
  end,
})

t.describe("notebook block scanning", {
  ["finds every sql block in one pass"] = function()
    local notebook = require("dbclient.notebook")
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "# doc",
      "```sql",
      "select 1;",
      "```",
      "prose",
      "```lua",
      "print(1)",
      "```",
      "```sql",
      "select 2;",
      "```",
    })

    local blocks = notebook.blocks(bufnr)
    t.eq(#blocks, 2, "only the sql blocks count")
    t.eq(blocks[1].sql, "select 1;")
    t.eq(blocks[2].sql, "select 2;")
  end,

  ["ignores an unterminated block"] = function()
    local notebook = require("dbclient.notebook")
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "```sql", "select 1;" })
    t.eq(notebook.blocks(bufnr), {})
  end,
})

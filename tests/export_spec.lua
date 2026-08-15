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

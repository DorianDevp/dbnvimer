local t = require("tests.init")
local spec = require("dbclient.export.spec")

t.describe("export spec round trip", {
  ["renders and parses back"] = function()
    local values = spec.defaults()
    values.destination = "/tmp/out.csv"
    values.null_as = "\\N"

    local parsed = spec.parse(spec.render(values, {}))
    t.eq(parsed.destination, "/tmp/out.csv")
    t.eq(parsed.null_as, "\\N")
    t.eq(parsed.format, "csv")
  end,

  ["survives a tab delimiter"] = function()
    -- A literal tab is invisible in a settings file, so it round trips as `\t`.
    local values = spec.defaults()
    values.delimiter = "\t"
    local rendered = spec.render(values, {})
    t.ok(table.concat(rendered, "\n"):find("\\t"), "a tab is written as an escape")
    t.eq(spec.parse(rendered).delimiter, "\t")
  end,

  ["ignores comments and the header"] = function()
    local parsed = spec.parse({
      "# Export. Edit, then :w",
      "# connection: demo",
      "format = json",
      "",
      "# delimited text",
      "header = false",
    })
    t.eq(parsed.format, "json")
    t.eq(parsed.header, "false")
  end,

  ["strips a trailing hint comment"] = function()
    local parsed = spec.parse({ "format          = csv          # csv tsv json" })
    t.eq(parsed.format, "csv")
  end,
})

t.describe("export payload", {
  ["converts types"] = function()
    local values = spec.defaults()
    values.destination = "/tmp/out.csv"
    values.limit = "500"
    values.header = "false"
    values.columns = "id, name , note"
    values.table = "customers"

    local payload = spec.to_payload(values)
    t.eq(payload.limit, 500)
    t.eq(payload.header, false)
    t.eq(payload.columns, { "id", "name", "note" })
    t.eq(payload.table, "customers")
  end,

  ["drops empty settings so core defaults apply"] = function()
    local values = spec.defaults()
    values.destination = "/tmp/out.csv"
    values.table = "t"
    local payload = spec.to_payload(values)
    t.eq(payload.delimiter, nil, "an empty delimiter must not become an empty string")
    t.eq(payload.filter, nil)
  end,

  ["a table wins over a statement"] = function()
    local values = spec.defaults()
    values.destination = "/tmp/out.csv"
    values.table = "customers"
    local payload = spec.to_payload(values, { sql = "select 1" })
    t.eq(payload.table, "customers")
    t.eq(payload.sql, nil)
  end,

  ["falls back to the statement when no table is given"] = function()
    local values = spec.defaults()
    values.destination = "/tmp/out.csv"
    local payload = spec.to_payload(values, { sql = "select 1" })
    t.eq(payload.sql, "select 1")
  end,

  ["refuses without a destination"] = function()
    local _, err = spec.to_payload(spec.defaults(), { sql = "select 1" })
    t.matches(err, "destination")
  end,

  ["refuses with nothing to export"] = function()
    local values = spec.defaults()
    values.destination = "/tmp/out.csv"
    local _, err = spec.to_payload(values, {})
    t.matches(err, "nothing to export")
  end,

  ["refuses a non-numeric number"] = function()
    local values = spec.defaults()
    values.destination = "/tmp/out.csv"
    values.table = "t"
    values.limit = "lots"
    local _, err = spec.to_payload(values)
    t.matches(err, "must be a number")
  end,

  ["sends booleans that default to true even when turned off"] = function()
    local values = spec.defaults()
    values.destination = "/tmp/out.csv"
    values.table = "t"
    values.manifest = "false"
    local payload = spec.to_payload(values)
    t.eq(payload.manifest, false, "a disabled default must be sent, not omitted")
    t.eq(payload.header, true)
  end,
})

t.describe("export presets", {
  ["the Excel preset sets everything that matters together"] = function()
    -- The point of a preset: a BOM alone does not make Excel read the file
    -- correctly in a locale that writes 1,5.
    local values = spec.apply_preset(spec.defaults(), "excel")
    t.eq(values.bom, "true")
    t.eq(values.line_ending, "crlf")
    t.eq(values.decimal_separator, ",")
  end,

  ["the PostgreSQL preset keeps NULL distinguishable"] = function()
    local values = spec.apply_preset(spec.defaults(), "postgres_copy")
    t.eq(values.null_as, "\\N")
    t.eq(values.escape, "double")
  end,

  ["the MySQL preset uses backslash escapes"] = function()
    local values = spec.apply_preset(spec.defaults(), "mysql_load")
    t.eq(values.escape, "backslash")
    t.eq(values.delimiter, "\t")
    t.eq(values.header, "false")
  end,

  ["the archive preset partitions and hashes"] = function()
    local values = spec.apply_preset(spec.defaults(), "archive")
    t.eq(values.compress, "gzip")
    t.eq(values.checksum, "true")
    t.ok(tonumber(values.partition_rows) > 0)
  end,

  ["reports an unknown preset"] = function()
    local _, err = spec.apply_preset(spec.defaults(), "nope")
    t.matches(err, "unknown preset")
  end,

  ["every preset produces a valid payload"] = function()
    for _, name in ipairs(spec.preset_names()) do
      local values = spec.apply_preset(spec.defaults(), name)
      values.destination = "/tmp/out"
      values.table = "t"
      local payload, err = spec.to_payload(values)
      t.eq(err, nil, ("preset %s: %s"):format(name, tostring(err)))
      t.ok(payload.format ~= nil)
    end
  end,
})

t.describe("export destinations", {
  ["suggests a name with the connection, table and date"] = function()
    local path = spec.suggest_destination({
      dir = "/tmp/exports",
      table = "customers",
      format = "jsonl",
      connection = "prod",
    })
    t.matches(path, "^/tmp/exports/prod%-customers%-%d+%-%d+%.jsonl$")
  end,

  ["maps a file name to a format"] = function()
    t.eq(spec.format_for("a.csv"), "csv")
    t.eq(spec.format_for("a.XLSX"), "xlsx")
    t.eq(spec.format_for("a.ndjson"), "jsonl")
    t.eq(spec.format_for("a.unknown"), nil)
    t.eq(spec.format_for("noextension"), nil)
  end,
})

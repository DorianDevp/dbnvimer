--- Checking an edit against the schema before the server has to.
---
--- The rule this suite enforces on itself: a column that declares nothing
--- produces no findings. Guessing would make the client wrong on exactly the
--- schemas where it has the least information, which is the opposite of useful.

local t = require("tests.init")
local constraints = require("dbclient.constraints")

local function column(name, type_name, extra)
  return vim.tbl_extend("force", { name = name, type = type_name, nullable = true }, extra or {})
end

t.describe("reading a declared type", {
  ["takes the length off a varchar"] = function()
    local spec = constraints.parse(column("name", "varchar(80)"))
    t.eq(spec.kind, "string")
    t.eq(spec.max_length, 80)
  end,

  ["reads tinyint(1) as a boolean"] = function()
    -- It is how MySQL spells one, and treating it as an integer accepts 7.
    t.eq(constraints.parse(column("active", "tinyint(1)")).kind, "bool")
    t.eq(constraints.parse(column("age", "tinyint(4)")).kind, "integer")
    t.eq(constraints.parse(column("ok", "boolean")).kind, "bool")
  end,

  ["reads an unsigned range"] = function()
    local signed = constraints.parse(column("n", "int(10)"))
    t.eq(signed.min, "-2147483648")
    t.eq(signed.max, "2147483647")

    local unsigned = constraints.parse(column("n", "int(10) unsigned"))
    t.eq(unsigned.min, "0")
    t.eq(unsigned.max, "4294967295")
  end,

  ["reads the values of an enum"] = function()
    local spec = constraints.parse(column("status", "enum('new','open','closed')"))
    t.eq(spec.kind, "enum")
    t.eq(spec.values, { "new", "open", "closed" })
  end,

  ["reads precision and scale"] = function()
    local spec = constraints.parse(column("total", "decimal(10,2)"))
    t.eq(spec.kind, "decimal")
    t.eq(spec.precision, 10)
    t.eq(spec.scale, 2)
  end,

  ["reads PostgreSQL's spellings"] = function()
    t.eq(constraints.parse(column("a", "character varying(40)")).max_length, 40)
    t.eq(constraints.parse(column("b", "timestamp without time zone")).kind, "datetime")
    t.eq(constraints.parse(column("c", "integer")).kind, "integer")
    t.eq(constraints.parse(column("d", "jsonb")).kind, "json")
    t.eq(constraints.parse(column("e", "uuid")).kind, "uuid")
  end,

  ["says nothing about a type it does not know"] = function()
    t.eq(constraints.parse(column("x", "geometry")).kind, "other")
  end,
})

t.describe("comparing integers as strings", {
  ["handles what a double cannot"] = function()
    -- 9223372036854775807 rounds up as a double, so the largest legal bigint
    -- would be reported as out of range.
    t.eq(constraints.compare_integers("9223372036854775807", "9223372036854775807"), 0)
    t.eq(constraints.compare_integers("9223372036854775806", "9223372036854775807"), -1)
    t.eq(constraints.compare_integers("9223372036854775808", "9223372036854775807"), 1)
  end,

  ["orders across the sign"] = function()
    t.eq(constraints.compare_integers("-1", "1"), -1)
    t.eq(constraints.compare_integers("-100", "-99"), -1)
    t.eq(constraints.compare_integers("0", "-0"), 0)
    t.eq(constraints.compare_integers("007", "7"), 0)
  end,
})

t.describe("checking a value", {
  ["refuses NULL in a NOT NULL column"] = function()
    local problem = constraints.check(vim.NIL, column("name", "varchar(20)", { nullable = false }))
    t.ok(problem ~= nil)
    t.matches(problem.message, "NOT NULL")
  end,

  ["allows NULL where the column allows it"] = function()
    t.eq(constraints.check(vim.NIL, column("name", "varchar(20)")), nil)
  end,

  ["counts characters, not bytes"] = function()
    -- `Świętochłowice` is 14 characters and 19 bytes; a varchar(16) holds it.
    t.eq(constraints.check("Świętochłowice", column("city", "varchar(16)")), nil)
    t.ok(constraints.check("Świętochłowice", column("city", "varchar(8)")) ~= nil)
  end,

  ["reports the length it actually is"] = function()
    local problem = constraints.check("far too long", column("label", "varchar(8)"))
    t.matches(problem.message, "12 characters")
    t.matches(problem.message, "holds 8")
  end,

  ["refuses a non-number in an integer column"] = function()
    t.ok(constraints.check("nonsense", column("n", "int")) ~= nil)
    t.ok(constraints.check("1.5", column("n", "int")) ~= nil)
    t.eq(constraints.check("-42", column("n", "int")), nil)
  end,

  ["catches an overflow before the server does"] = function()
    local problem = constraints.check("40000", column("n", "smallint"))
    t.matches(problem.message, "beyond the range of smallint")
    t.eq(constraints.check("32767", column("n", "smallint")), nil)
  end,

  ["catches a negative in an unsigned column"] = function()
    local problem = constraints.check("-1", column("n", "int(10) unsigned"))
    t.matches(problem.message, "cannot go below 0")
    t.matches(problem.hint, "unsigned")
  end,

  ["accepts the largest legal bigint"] = function()
    t.eq(constraints.check("9223372036854775807", column("n", "bigint")), nil)
    t.ok(constraints.check("9223372036854775808", column("n", "bigint")) ~= nil)
  end,

  ["holds a decimal to its scale"] = function()
    t.eq(constraints.check("12.34", column("total", "decimal(10,2)")), nil)
    local problem = constraints.check("12.345", column("total", "decimal(10,2)"))
    t.matches(problem.message, "2 decimal places")
    t.matches(problem.hint, "rounded away")
  end,

  ["holds a decimal to its precision"] = function()
    -- decimal(4,2) is two digits before the point and two after.
    t.eq(constraints.check("99.99", column("x", "decimal(4,2)")), nil)
    t.ok(constraints.check("999.99", column("x", "decimal(4,2)")) ~= nil)
  end,

  ["checks enum membership and lists the alternatives"] = function()
    local type_name = "enum('new','open','closed')"
    t.eq(constraints.check("open", column("status", type_name)), nil)
    local problem = constraints.check("aktywny", column("status", type_name))
    t.matches(problem.message, "aktywny")
    t.matches(problem.hint, "new, open, closed")
  end,

  ["checks every member of a set"] = function()
    local type_name = "set('a','b','c')"
    t.eq(constraints.check("a,c", column("flags", type_name)), nil)
    t.ok(constraints.check("a,z", column("flags", type_name)) ~= nil)
  end,

  ["checks a date is a date, and that it exists"] = function()
    t.eq(constraints.check("2026-08-15", column("d", "date")), nil)
    t.ok(constraints.check("15/08/2026", column("d", "date")) ~= nil)

    -- The one every client lets through to the server.
    local problem = constraints.check("2026-02-30", column("d", "date"))
    t.matches(problem.message, "no such date")
    t.eq(constraints.check("2024-02-29", column("d", "date")), nil, "2024 was a leap year")
    t.ok(constraints.check("2026-02-29", column("d", "date")) ~= nil, "2026 was not")
    t.eq(constraints.check("2000-02-29", column("d", "date")), nil, "2000 was, being /400")
    t.ok(constraints.check("1900-02-29", column("d", "date")) ~= nil, "1900 was not, being /100")
  end,

  ["checks a timestamp"] = function()
    t.eq(constraints.check("2026-08-15 09:14:00", column("t", "datetime")), nil)
    t.eq(constraints.check("2026-08-15T09:14:00", column("t", "timestamp")), nil)
    t.ok(constraints.check("2026-08-15", column("t", "datetime")) ~= nil)
  end,

  ["checks that JSON parses"] = function()
    t.eq(constraints.check('{"a":1}', column("payload", "json")), nil)
    t.ok(constraints.check("{not json", column("payload", "json")) ~= nil)
  end,

  ["checks a uuid"] = function()
    t.eq(
      constraints.check("3f2504e0-4f89-11d3-9a0c-0305e82c3301", column("id", "uuid")),
      nil
    )
    t.ok(constraints.check("not-a-uuid", column("id", "uuid")) ~= nil)
  end,

  ["accepts the boolean spellings"] = function()
    for _, value in ipairs({ "0", "1", "true", "false", "t", "f" }) do
      t.eq(constraints.check(value, column("active", "tinyint(1)")), nil, value)
    end
    t.ok(constraints.check("yes", column("active", "tinyint(1)")) ~= nil)
  end,

  ["says nothing about a type it does not know"] = function()
    t.eq(constraints.check("anything at all", column("x", "geometry")), nil)
  end,
})

local columns = {
    { name = "id", type = "int", nullable = false },
    { name = "label", type = "varchar(8)", nullable = false },
    { name = "priority", type = "smallint", nullable = true },
  { name = "status", type = "enum('new','open')", nullable = true },
}

t.describe("checking a change set", {
  ["reports one finding per offending cell"] = function()
    local findings = constraints.check_changes({
      columns = columns,
      changes = {
        {
          op = "update",
          line = 4,
          set = { label = "far too long", priority = "40000" },
          cells = {
            { column = "label", column_index = 2 },
            { column = "priority", column_index = 3 },
          },
        },
      },
    })
    t.eq(#findings, 2)
    -- Sorted so the report reads in a stable order.
    t.eq(findings[1].column, "label")
    t.eq(findings[1].line, 4)
    t.eq(findings[1].column_index, 2)
    t.eq(findings[2].column, "priority")
  end,

  ["says nothing about a change that fits"] = function()
    t.eq(
      constraints.check_changes({
        columns = columns,
        changes = { { op = "update", set = { label = "short", priority = "3" } } },
      }),
      {}
    )
  end,

  ["catches a NOT NULL column left out of an insert"] = function()
    local findings = constraints.check_changes({
      columns = columns,
      changes = { { op = "insert", line = 6, values = { id = "1" } } },
    })
    t.eq(#findings, 1)
    t.eq(findings[1].column, "label")
    t.matches(findings[1].message, "NOT NULL and has no default")
  end,

  ["does not ask for a generated key"] = function()
    local findings = constraints.check_changes({
      columns = {
        { name = "id", type = "int", nullable = false, extra = "auto_increment" },
        { name = "label", type = "varchar(8)", nullable = false },
      },
      changes = { { op = "insert", values = { label = "ok" } } },
    })
    t.eq(findings, {}, "auto_increment supplies itself")

    local postgres = constraints.check_changes({
      columns = {
        { name = "id", type = "integer", nullable = false, default = "nextval('t_id_seq')" },
        { name = "label", type = "varchar(8)", nullable = false },
      },
      changes = { { op = "insert", values = { label = "ok" } } },
    })
    t.eq(postgres, {}, "and so does a sequence default")
  end,

  ["ignores a column the table does not have"] = function()
  t.eq(
    constraints.check_changes({
      columns = columns,
      changes = { { op = "update", set = { nonexistent = "x" } } },
    }),
    {}
  )
  end,
})

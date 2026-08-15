local t = require("tests.init")
local cdc = require("dbclient.cdc")
local fixture = require("dbclient.fixture")
local hypo = require("dbclient.hypo")

t.describe("fixture ordering", {
  ["puts parents before the tables that reference them"] = function()
    -- orders -> customers -> countries
    local ordered, cyclic = fixture.topological_sort(
      { "shop.orders", "shop.customers", "shop.countries" },
      {
        ["shop.orders"] = { "shop.customers" },
        ["shop.customers"] = { "shop.countries" },
        ["shop.countries"] = {},
      }
    )
    t.eq(ordered, { "shop.countries", "shop.customers", "shop.orders" })
    t.eq(cyclic, {})
  end,

  ["is stable for unrelated tables"] = function()
    local ordered = fixture.topological_sort({ "b", "a", "c" }, {})
    t.eq(ordered, { "a", "b", "c" }, "a stable order means a stable file")
  end,

  ["reports a cycle instead of inventing an order"] = function()
    local ordered, cyclic = fixture.topological_sort(
      { "a", "b", "free" },
      { a = { "b" }, b = { "a" }, free = {} }
    )
    t.eq(ordered, { "free" })
    t.eq(cyclic, { "a", "b" }, "a cycle has no linear order and must be reported")
  end,

  ["tolerates a self reference"] = function()
    -- A tree table pointing at its own parent column is orderable: the rows
    -- just have to go in the right order, not the tables.
    local ordered, cyclic = fixture.topological_sort({ "tree" }, { tree = { "tree" } })
    t.eq(ordered, { "tree" })
    t.eq(cyclic, {})
  end,
})

t.describe("fixture filters", {
  ["selects collected rows by a single key"] = function()
    local entry = {
      columns = { { name = "id" }, { name = "name" } },
      rows = { { "1", "a" }, { "7", "b" } },
    }
    t.eq(fixture.filter_for(entry, { "id" }), "id in ('1', '7')")
  end,

  ["falls back to per-row predicates for a composite key"] = function()
    local entry = {
      columns = { { name = "a" }, { name = "b" } },
      rows = { { "1", "x" } },
    }
    t.eq(fixture.filter_for(entry, { "a", "b" }), "(a = '1' and b = 'x')")
  end,

  ["handles a NULL inside a key predicate"] = function()
    local entry = {
      columns = { { name = "a" }, { name = "b" } },
      rows = { { "1", vim.NIL } },
    }
    t.eq(fixture.filter_for(entry, { "a", "b" }), "(a = '1' and b is null)")
  end,

  ["escapes a quote in a value"] = function()
    local entry = { columns = { { name = "id" } }, rows = { { "it's" } } }
    t.eq(fixture.filter_for(entry, { "id" }), "id in ('it''s')")
  end,
})

t.describe("hypothetical index reports", {
  ["reads the cost off a PostgreSQL plan"] = function()
    local plan = { plan = { { Plan = { ["Total Cost"] = 1234.5, ["Node Type"] = "Seq Scan" } } } }
    t.eq(hypo.total_cost(plan), 1234.5)
    t.eq(hypo.node_types(plan), { "Seq Scan" })
  end,

  ["walks nested plan nodes"] = function()
    local plan = {
      plan = {
        {
          Plan = {
            ["Node Type"] = "Nested Loop",
            Plans = {
              { ["Node Type"] = "Index Scan" },
              { ["Node Type"] = "Seq Scan" },
            },
          },
        },
      },
    }
    t.eq(hypo.node_types(plan), { "Nested Loop", "Index Scan", "Seq Scan" })
  end,

  ["calls a big improvement out"] = function()
    local lines = hypo.report({
      index = "create index on orders (customer_id)",
      cost_before = 45231,
      cost_after = 12.4,
      nodes_before = { "Seq Scan" },
      nodes_after = { "Index Scan" },
    })
    local text = table.concat(lines, "\n")
    t.matches(text, "cheaper")
    t.matches(text, "The planner chose the index")
    t.matches(text, "create index on orders %(customer_id%);")
  end,

  ["says so when the planner ignores it"] = function()
    local lines = hypo.report({
      index = "create index on t (x)",
      cost_before = 100,
      cost_after = 100,
      nodes_before = { "Seq Scan" },
      nodes_after = { "Seq Scan" },
    })
    local text = table.concat(lines, "\n")
    t.matches(text, "no measurable difference")
    t.matches(text, "did not choose it")
  end,

  ["always says nothing was created"] = function()
    local text = table.concat(
      hypo.report({
        index = "create index on t (x)",
        cost_before = 10,
        cost_after = 5,
        nodes_before = {},
        nodes_after = {},
      }),
      "\n"
    )
    t.matches(text, "already gone")
  end,
})

t.describe("change stream parsing", {
  ["reads PostgreSQL test_decoding output"] = function()
    local event = cdc.parse_postgres(
      "table public.customers: INSERT: id[integer]:4 name[text]:'ACME'"
    )
    t.eq(event.kind, "row")
    t.eq(event.table, "public.customers")
    t.eq(event.operation, "insert")
    t.matches(event.detail, "ACME")
  end,

  ["reads transaction boundaries"] = function()
    t.eq(cdc.parse_postgres("BEGIN 512").kind, "begin")
    t.eq(cdc.parse_postgres("COMMIT 512").kind, "commit")
  end,

  ["ignores an empty line"] = function()
    t.eq(cdc.parse_postgres("   "), nil)
  end,

  ["reads mysqlbinlog row images"] = function()
    local event = cdc.parse_mysql("### INSERT INTO `shop`.`customers`")
    t.eq(event.kind, "row")
    t.eq(event.table, "shop.customers")
    t.eq(event.operation, "insert")

    local delete = cdc.parse_mysql("### DELETE FROM `shop`.`orders`")
    t.eq(delete.operation, "delete")
    t.eq(delete.table, "shop.orders")

    local value = cdc.parse_mysql("###   @1=4 /* INT meta=0 nullable=0 */")
    t.eq(value.kind, "value")
    t.matches(value.detail, "@1=4")
  end,

  ["formats an event for the buffer"] = function()
    local text, group = cdc.format({
      kind = "row",
      table = "shop.customers",
      operation = "delete",
      detail = "id[integer]:4",
    })
    t.matches(text, "^DELETE")
    t.matches(text, "shop%.customers")
    t.eq(group, "DBClientPendingDelete")
  end,

  ["colours inserts, updates and deletes apart"] = function()
    local _, insert = cdc.format({ kind = "row", table = "t", operation = "insert" })
    local _, update = cdc.format({ kind = "row", table = "t", operation = "update" })
    local _, delete = cdc.format({ kind = "row", table = "t", operation = "delete" })
    t.ok(insert ~= update and update ~= delete and insert ~= delete)
  end,
})

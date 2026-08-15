local t = require("tests.init")
local audit = require("dbclient.audit")
local chart = require("dbclient.chart")
local joins = require("dbclient.joins")

-- ---------------------------------------------------------------------------

local function graph_of(edges)
  local graph = { nodes = {}, edges = {} }
  local function node(name)
    if not graph.edges[name] then
      graph.edges[name] = {}
      table.insert(graph.nodes, name)
    end
  end
  for _, edge in ipairs(edges) do
    node(edge[1])
    node(edge[3])
    table.insert(graph.edges[edge[1]], {
      to = edge[3],
      from_column = edge[2],
      to_column = edge[4],
    })
    table.insert(graph.edges[edge[3]], {
      to = edge[1],
      from_column = edge[4],
      to_column = edge[2],
      reverse = true,
    })
  end
  return graph
end

-- orders -> customers -> addresses -> countries, plus a shortcut.
local shop = graph_of({
  { "orders", "customer_id", "customers", "id" },
  { "customers", "address_id", "addresses", "id" },
  { "addresses", "country_id", "countries", "id" },
  { "order_items", "order_id", "orders", "id" },
})

t.describe("join paths", {
  ["finds a direct join"] = function()
    local paths = joins.paths(shop, "orders", "customers")
    t.eq(#paths >= 1, true)
    t.eq(#paths[1], 1)
    t.eq(paths[1][1].edge.to, "customers")
  end,

  ["walks several hops"] = function()
    local paths = joins.paths(shop, "orders", "countries")
    t.ok(#paths >= 1)
    local hops = {}
    for _, step in ipairs(paths[1]) do
      table.insert(hops, step.edge.to)
    end
    t.eq(hops, { "customers", "addresses", "countries" })
  end,

  ["travels a foreign key backwards"] = function()
    -- countries has no key of its own; the path exists only in reverse.
    local paths = joins.paths(shop, "countries", "orders")
    t.ok(#paths >= 1)
    t.eq(#paths[1], 3)
  end,

  ["returns the shortest path first"] = function()
    local paths = joins.paths(shop, "order_items", "addresses")
    t.ok(#paths >= 1)
    for index = 2, #paths do
      t.ok(#paths[index] >= #paths[1], "paths must be ordered by length")
    end
  end,

  ["reports nothing when the tables are unconnected"] = function()
    local isolated = graph_of({ { "a", "b_id", "b", "id" }, { "c", "d_id", "d", "id" } })
    t.eq(joins.paths(isolated, "a", "c"), {})
  end,

  ["handles a table joined to itself"] = function()
    t.eq(joins.paths(shop, "orders", "orders"), { {} })
  end,

  ["ignores tables it has never heard of"] = function()
    t.eq(joins.paths(shop, "orders", "nope"), {})
  end,
})

t.describe("join rendering", {
  ["renders a select with aliases and ON clauses"] = function()
    local path = joins.paths(shop, "orders", "countries")[1]
    local sql = table.concat(joins.render(path, { schema = "shop", from = "orders" }), "\n")

    t.matches(sql, "select o%.%*")
    t.matches(sql, "from shop%.orders o")
    t.matches(sql, "join shop%.customers c on c%.id = o%.customer_id")
    t.matches(sql, "join shop%.addresses a on a%.id = c%.address_id")
    t.matches(sql, "join shop%.countries c2 on c2%.id = a%.country_id")
  end,

  ["gives colliding names distinct aliases"] = function()
    local taken = {}
    t.eq(joins.alias("customers", taken), "c")
    t.eq(joins.alias("countries", taken), "c2")
    t.eq(joins.alias("order_items", taken), "oi")
  end,

  ["describes a path in one line"] = function()
    local path = joins.paths(shop, "orders", "countries")[1]
    local text = joins.describe(path, "orders")
    t.matches(text, "orders → customers → addresses → countries")
    t.matches(text, "3 joins")
  end,
})

-- ---------------------------------------------------------------------------

local function table_entry(overrides)
  return vim.tbl_extend("force", {
    name = "t",
    is_view = false,
    columns = {},
    primary = { "id" },
    indexes = {},
    foreign_keys = {},
  }, overrides or {})
end

t.describe("schema audit", {
  ["flags a table with no primary key"] = function()
    local findings = audit.analyse({
      name = "shop",
      tables = { table_entry({ name = "logs", primary = {} }) },
    })
    t.eq(#findings, 1)
    t.eq(findings[1].code, "no-primary-key")
    t.matches(findings[1].fix, "add primary key")
  end,

  ["does not ask a view for a primary key"] = function()
    local findings = audit.analyse({
      name = "shop",
      tables = { table_entry({ name = "v", is_view = true, primary = {} }) },
    })
    t.eq(findings, {})
  end,

  ["flags a foreign key with no index"] = function()
    local findings = audit.analyse({
      name = "shop",
      tables = {
        table_entry({
          name = "orders",
          foreign_keys = {
            { column = "customer_id", ref_table = "customers", ref_column = "id" },
          },
          indexes = { { name = "PRIMARY", columns = "id" } },
        }),
      },
    })
    t.eq(#findings, 1)
    t.eq(findings[1].code, "unindexed-foreign-key")
  end,

  ["accepts a foreign key covered by a composite index prefix"] = function()
    local findings = audit.analyse({
      name = "shop",
      tables = {
        table_entry({
          name = "orders",
          foreign_keys = {
            { column = "customer_id", ref_table = "customers", ref_column = "id" },
          },
          indexes = { { name = "idx", columns = "customer_id, placed_at" } },
        }),
      },
    })
    t.eq(findings, {})
  end,

  ["flags an index that is a prefix of another"] = function()
    local findings = audit.analyse({
      name = "shop",
      tables = {
        table_entry({
          name = "orders",
          indexes = {
            { name = "idx_a", columns = "customer_id" },
            { name = "idx_ab", columns = "customer_id, placed_at" },
          },
        }),
      },
    })
    t.eq(#findings, 1)
    t.eq(findings[1].code, "redundant-index")
    t.matches(findings[1].message, "idx_a")
  end,

  ["keeps a unique index even when it is a prefix"] = function()
    local findings = audit.analyse({
      name = "shop",
      tables = {
        table_entry({
          name = "orders",
          indexes = {
            { name = "uq", columns = "code", unique = true },
            { name = "idx", columns = "code, placed_at" },
          },
        }),
      },
    })
    t.eq(findings, {}, "a unique index enforces something the longer one does not")
  end,

  ["flags a foreign key whose types disagree"] = function()
    local findings = audit.analyse({
      name = "shop",
      tables = {
        table_entry({
          name = "orders",
          columns = { { name = "customer_id", type = "int" } },
          indexes = { { name = "i", columns = "customer_id" } },
          foreign_keys = {
            { column = "customer_id", ref_table = "customers", ref_column = "id" },
          },
        }),
        table_entry({
          name = "customers",
          columns = { { name = "id", type = "bigint" } },
        }),
      },
    })
    local codes = vim.tbl_map(function(finding)
      return finding.code
    end, findings)
    t.ok(vim.tbl_contains(codes, "foreign-key-type-mismatch"))
  end,

  ["flags always-null and never-null columns"] = function()
    local findings = audit.analyse({
      name = "shop",
      tables = {
        table_entry({
          name = "t",
          stats = {
            { name = "dead", nullable = true, total = 100, non_null = 0, distinct = 0 },
            { name = "always", nullable = true, total = 100, non_null = 100, distinct = 40 },
            { name = "constant", nullable = false, total = 100, non_null = 100, distinct = 1 },
          },
        }),
      },
    })
    local codes = {}
    for _, finding in ipairs(findings) do
      codes[finding.code] = true
    end
    t.ok(codes["always-null"])
    t.ok(codes["never-null"])
    t.ok(codes["single-value"])
  end,

  ["does not call a primary key nullable"] = function()
    local findings = audit.analyse({
      name = "shop",
      tables = {
        table_entry({
          name = "t",
          primary = { "id" },
          stats = {
            { name = "id", nullable = true, total = 10, non_null = 10, distinct = 10 },
          },
        }),
      },
    })
    t.eq(findings, {}, "SQLite calls a rowid alias nullable; that is not a finding")
  end,

  ["orders findings by severity"] = function()
    local findings = audit.analyse({
      name = "shop",
      tables = {
        table_entry({ name = "a", primary = {} }),
        table_entry({
          name = "b",
          indexes = {
            { name = "i1", columns = "x" },
            { name = "i2", columns = "x, y" },
          },
        }),
      },
    })
    t.eq(findings[1].severity, "warn")
    t.eq(findings[#findings].severity, "hint")
  end,

  ["renders a report"] = function()
    local schema = {
      name = "shop",
      tables = { table_entry({ name = "logs", primary = {} }) },
    }
    local lines = audit.report(schema, audit.analyse(schema))
    local text = table.concat(lines, "\n")
    t.matches(text, "shop")
    t.matches(text, "worth fixing")
    t.matches(text, "no primary key")
  end,

  ["says so when there is nothing to report"] = function()
    local lines = audit.report({ name = "shop", tables = {} }, {})
    t.matches(table.concat(lines, "\n"), "nothing to report")
  end,
})

-- ---------------------------------------------------------------------------

local function result(columns, rows)
  return { columns = columns, rows = rows }
end

t.describe("charts", {
  ["draws a bar proportional to the value"] = function()
    t.eq(chart.bar(10, 10, 10), "██████████")
    t.eq(chart.bar(0, 10, 10), "")
    t.eq(chart.bar(5, 10, 10), "█████")
  end,

  ["uses partial blocks for the remainder"] = function()
    local bar = chart.bar(1, 8, 4)
    t.ok(#bar > 0)
    t.falsy(bar:find("^██"), "half a cell should not round up to a full block")
  end,

  ["draws a sparkline"] = function()
    local spark = chart.sparkline({ 1, 5, 3, 9 })
    t.eq(vim.fn.strchars(spark), 4)
  end,

  ["handles a flat sparkline"] = function()
    local spark = chart.sparkline({ 5, 5, 5 })
    t.eq(vim.fn.strchars(spark), 3)
  end,

  ["formats numbers compactly"] = function()
    t.eq(chart.format(42), "42")
    t.eq(chart.format(1234), "1234")
    t.eq(chart.format(12345), "12.3k")
    t.eq(chart.format(2500000), "2.50M")
    t.eq(chart.format(1.5), "1.50")
  end,

  ["picks the label and value columns"] = function()
    local label, value = chart.pick_columns({
      { name = "city", class = "text" },
      { name = "total", class = "number" },
    })
    t.eq(label, 1)
    t.eq(value, 2)
  end,

  ["renders a chart from a result set"] = function()
    local lines, _, err = chart.render(
      result(
        { { name = "city", class = "text" }, { name = "total", class = "number" } },
        { { "PL", "1200" }, { "DE", "300" }, { "CZ", "0" } }
      ),
      { width = 60 }
    )
    t.eq(err, nil)
    local text = table.concat(lines, "\n")
    t.matches(text, "total by city")
    t.matches(text, "PL")
    t.matches(text, "█")
    t.matches(text, "3 point")
  end,

  ["puts negative values on the other side of zero"] = function()
    local lines = chart.render(
      result(
        { { name = "city", class = "text" }, { name = "balance", class = "number" } },
        { { "PL", "100" }, { "DE", "-50" } }
      ),
      { width = 60 }
    )
    local text = table.concat(lines, "\n")
    t.matches(text, "│", "a zero line is drawn when values go both ways")
    t.matches(text, "%-50")
  end,

  ["charts a column whose type the backend did not declare"] = function()
    -- `count(*)` has no declared type in SQLite, so the class arrives as
    -- unknown; the values are still numbers and still worth charting.
    local lines, _, err = chart.render(
      result(
        { { name = "city", class = "text" }, { name = "n", class = "unknown" } },
        { { "PL", "12" }, { "DE", "3" } }
      ),
      { width = 40 }
    )
    t.eq(err, nil)
    t.matches(table.concat(lines, "\n"), "n by city")
  end,

  ["does not mistake text for a measure"] = function()
    local _, _, err = chart.render(
      result(
        { { name = "a", class = "unknown" }, { name = "b", class = "unknown" } },
        { { "x", "y" } }
      )
    )
    t.matches(err, "no numeric column")
  end,

  ["refuses when there is nothing numeric"] = function()
    local _, _, err = chart.render(
      result({ { name = "a", class = "text" } }, { { "x" } })
    )
    t.matches(err, "no numeric column")
  end,

  ["refuses when there are no rows"] = function()
    local _, _, err = chart.render(
      result({ { name = "n", class = "number" } }, {})
    )
    t.matches(err, "no rows")
  end,

  ["labels a NULL bucket"] = function()
    local lines = chart.render(
      result(
        { { name = "city", class = "text" }, { name = "n", class = "number" } },
        { { vim.NIL, "5" } }
      ),
      { width = 40 }
    )
    t.matches(
      table.concat(lines, "\n"),
      vim.pesc(require("dbclient.config").get().ui.null_display)
    )
  end,
})

local buffer = require("dbclient.ui.buffer")

t.describe("where content lands", {
  ["takes the window you were in rather than splitting away from it"] = function()
    -- With a file open and the sidebar out, a table used to arrive as a
    -- full-width strip along the bottom and halve everything else.
    vim.cmd("silent! only")
    local file = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(file, 0, -1, false, { "local x = 1" })

    local data = vim.api.nvim_create_buf(false, true)
    vim.bo[data].filetype = "dbclient-data"
    local before = #vim.api.nvim_list_wins()

    buffer.show(data, "botright split", { primary = true })
    t.eq(#vim.api.nvim_list_wins(), before, "no new window was made")
    t.eq(vim.api.nvim_win_get_buf(0), data, "the content is in front of you")

    vim.api.nvim_buf_delete(data, { force = true })
  end,

  ["reuses the same window for the next thing of the same kind"] = function()
    vim.cmd("silent! only")
    local first = vim.api.nvim_create_buf(false, true)
    vim.bo[first].filetype = "dbclient-data"
    buffer.show(first, "botright split", { primary = true })

    local second = vim.api.nvim_create_buf(false, true)
    vim.bo[second].filetype = "dbclient-data"
    local before = #vim.api.nvim_list_wins()
    buffer.show(second, "botright split", { primary = true })

    -- Opening one table after another should not tile the screen; going back
    -- is the trail's job.
    t.eq(#vim.api.nvim_list_wins(), before, "the second table replaced the first")
    t.eq(vim.api.nvim_win_get_buf(0), second)

    vim.api.nvim_buf_delete(first, { force = true })
    vim.api.nvim_buf_delete(second, { force = true })
  end,

  ["never takes over a panel that reports on something else"] = function()
    vim.cmd("silent! only")
    -- Standing in a result panel and opening a table must not replace the
    -- result with the table you asked about.
    local result = vim.api.nvim_create_buf(false, true)
    vim.bo[result].filetype = "dbclient-result"
    vim.api.nvim_win_set_buf(0, result)

    local data = vim.api.nvim_create_buf(false, true)
    vim.bo[data].filetype = "dbclient-data"
    buffer.show(data, "botright split", { primary = true })

    t.ok(vim.api.nvim_win_get_buf(0) == data, "the table is in front of you")
    local still_there = false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == result then
        still_there = true
      end
    end
    t.ok(still_there, "and the result panel survived")

    vim.api.nvim_buf_delete(result, { force = true })
    vim.api.nvim_buf_delete(data, { force = true })
    vim.cmd("silent! only")
  end,

  ["leaves a panel where its caller put it"] = function()
    vim.cmd("silent! only")
    local before = #vim.api.nvim_list_wins()
    local panel = vim.api.nvim_create_buf(false, true)
    vim.bo[panel].filetype = "dbclient-result"

    -- No `primary`, so it splits: a result belongs *under* its query.
    buffer.show(panel, "botright 14split")
    t.eq(#vim.api.nvim_list_wins(), before + 1)

    vim.api.nvim_buf_delete(panel, { force = true })
    vim.cmd("silent! only")
  end,
})

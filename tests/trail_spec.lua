local t = require("tests.init")
local trail = require("dbclient.trail")

local function place(table_name, filter)
  return {
    session_id = "s1",
    connection = "demo",
    schema = "shop",
    table = table_name,
    filter = filter,
  }
end

local function reset()
  trail.clear()
  trail.restoring = false
end

t.describe("navigation trail", {
  ["records each place in order"] = function()
    reset()
    trail.push(place("customers"))
    trail.push(place("orders", "customer_id = '4'"))
    trail.push(place("order_items", "order_id = '10'"))

    t.eq(#trail.entries, 3)
    t.eq(trail.index, 3)
    t.eq(trail.current().table, "order_items")
  end,

  ["walks back one step at a time"] = function()
    reset()
    trail.push(place("customers"))
    trail.push(place("orders"))
    trail.push(place("order_items"))

    local entry = trail.step(-1)
    t.eq(entry.table, "orders")
    entry = trail.step(-1)
    t.eq(entry.table, "customers")
  end,

  ["jumps back several steps with a count"] = function()
    reset()
    trail.push(place("customers"))
    trail.push(place("orders"))
    trail.push(place("order_items"))

    -- x > y > z, and from z straight to x.
    local entry = trail.step(-2)
    t.eq(entry.table, "customers")
    t.eq(trail.index, 1)
  end,

  ["clamps rather than failing when the count overshoots"] = function()
    reset()
    trail.push(place("a"))
    trail.push(place("b"))
    local entry = trail.step(-10)
    t.eq(entry.table, "a")

    entry = trail.step(10)
    t.eq(entry.table, "b")
  end,

  ["reports when there is nowhere to go"] = function()
    reset()
    trail.push(place("a"))
    local entry, err = trail.step(-1)
    t.eq(entry, nil)
    t.matches(err, "start of the trail")

    local forward, forward_err = trail.step(1)
    t.eq(forward, nil)
    t.matches(forward_err, "end of the trail")
  end,

  ["goes forward again after going back"] = function()
    reset()
    trail.push(place("a"))
    trail.push(place("b"))
    trail.push(place("c"))

    trail.step(-2)
    t.eq(trail.current().table, "a")
    local entry = trail.step(1)
    t.eq(entry.table, "b")
    t.ok(trail.can_go_forward())
  end,

  ["navigating from a rewound position drops the forward branch"] = function()
    reset()
    trail.push(place("a"))
    trail.push(place("b"))
    trail.push(place("c"))

    trail.step(-1) -- now on b
    trail.push(place("d"))

    t.eq(#trail.entries, 3, "c is gone, the way a browser drops it")
    t.eq(trail.entries[3].table, "d")
    t.falsy(trail.can_go_forward())
  end,

  ["jumps straight to any position"] = function()
    reset()
    trail.push(place("a"))
    trail.push(place("b"))
    trail.push(place("c"))

    local entry = trail.goto_index(1)
    t.eq(entry.table, "a")
    t.eq(trail.index, 1)
  end,

  ["re-opening the same place updates rather than stacking"] = function()
    reset()
    trail.push(place("orders"))
    trail.push(place("orders")) -- paging or sorting the same view
    t.eq(#trail.entries, 1)

    -- A different filter is a different place.
    trail.push(place("orders", "status = 'new'"))
    t.eq(#trail.entries, 2)
  end,

  ["ignores pushes while restoring"] = function()
    reset()
    trail.push(place("a"))
    trail.restoring = true
    trail.push(place("b"))
    trail.restoring = false
    t.eq(#trail.entries, 1, "restoring must not extend the trail")
  end,

  ["caps its length"] = function()
    reset()
    local previous = trail.limit
    trail.limit = 3
    for index = 1, 6 do
      trail.push(place("t" .. index))
    end
    t.eq(#trail.entries, 3)
    t.eq(trail.entries[1].table, "t4", "the oldest places fall off")
    t.eq(trail.index, 3)
    trail.limit = previous
  end,
})

t.describe("trail labels and breadcrumbs", {
  ["labels a place with its filter"] = function()
    t.eq(trail.label(place("orders")), "shop.orders")
    t.eq(trail.label(place("orders", "customer_id = '4'")), "shop.orders[customer_id = '4']")
  end,

  ["shortens a long filter"] = function()
    local label = trail.label(place("orders", string.rep("x", 60)))
    t.ok(#label < 60)
    t.matches(label, "…%]$")
  end,

  ["renders the trail with the current place marked"] = function()
    reset()
    trail.push(place("customers"))
    trail.push(place("orders"))
    local crumb = trail.breadcrumb()
    t.eq(crumb, "shop.customers › [shop.orders]")
  end,

  ["elides the middle when the trail is long"] = function()
    reset()
    for index = 1, 8 do
      trail.push(place("table" .. index))
    end
    trail.goto_index(5)

    local crumb = trail.breadcrumb({ width = 40 })
    t.ok(vim.fn.strdisplaywidth(crumb) <= 60, "the breadcrumb must stay short")
    t.matches(crumb, "%[shop%.table5%]", "the current place is always shown")
    t.matches(crumb, "…", "the rest is elided")
  end,

  ["is empty when nothing has been visited"] = function()
    reset()
    t.eq(trail.breadcrumb(), "")
  end,

  ["lists positions for the picker"] = function()
    reset()
    trail.push(place("a"))
    trail.push(place("b"))
    local list = trail.list()
    t.eq(#list, 2)
    t.eq(list[2].current, true)
    t.matches(list[2].label, "▸")
  end,
})

t.describe("trail restore fidelity", {
  ["an entry with no filter restores as unfiltered"] = function()
    -- A nil filter left the previous one in place, so going back to the whole
    -- table still showed one row. The restore has to be exact.
    reset()
    local opened = {}
    local data = require("dbclient.ui.data")
    local session = require("dbclient.session")
    local original = data.open
    data.open = function(opts)
      opened = opts
    end
    -- `restore` refuses to reopen a place whose connection is gone, so the
    -- session has to exist for the restore to get as far as the data buffer.
    session.sessions.s1 = { id = "s1", name = "demo", spec = {}, cache = {} }

    trail.push(place("customers"))
    trail.push(place("customers", "id = '1'"))
    trail.step(-1)
    trail.restore(trail.current())

    data.open = original
    session.sessions.s1 = nil
    trail.restoring = false

    t.eq(opened.filter, "", "an empty string clears the filter; nil would not")
    t.eq(opened.sort, {})
    t.eq(opened.offset, 0)
  end,
})

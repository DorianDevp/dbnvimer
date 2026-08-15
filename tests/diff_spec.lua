local t = require("tests.init")
local config = require("dbclient.config")
local diff = require("dbclient.data.diff")
local grid = require("dbclient.ui.grid")

config.setup({ connections = {}, ui = { null_display = "∅", max_cell_width = 48 } })

local columns = {
  { name = "id", class = "number" },
  { name = "name", class = "text" },
  { name = "note", class = "text" },
}

--- Build the snapshot the data buffer would hand to `compute`.
local function snapshot(rows)
  local sizes = grid.widths(columns, rows)
  local result = {}
  for index, values in ipairs(rows) do
    local rendered = {}
    for column_index, column in ipairs(columns) do
      rendered[column_index] = vim.trim(grid.pad(
        (grid.display(values[column_index], column)),
        sizes[column_index],
        grid.alignment(column.class)
      ))
    end
    result[index] = { values = values, rendered = rendered }
  end
  return result
end

local base_rows = {
  { "1", "Anna", vim.NIL },
  { "2", "Bartek", "note" },
}

local function compute(entries, opts)
  return diff.compute(vim.tbl_extend("force", {
    schema = "shop",
    table = "customers",
    columns = columns,
    primary = { "id" },
    snapshot = snapshot(base_rows),
    entries = entries,
  }, opts or {}))
end

t.describe("data diff", {
  ["reports nothing when the buffer is untouched"] = function()
    local result = compute({
      { id = 1, cells = { "1", "Anna", "∅" } },
      { id = 2, cells = { "2", "Bartek", "note" } },
    })
    t.eq(result.changes, {})
    t.eq(result.errors, {})
  end,

  ["detects a changed cell"] = function()
    local result = compute({
      { id = 1, cells = { "1", "Ania", "∅" } },
      { id = 2, cells = { "2", "Bartek", "note" } },
    })
    t.eq(#result.changes, 1)
    local change = result.changes[1]
    t.eq(change.op, "update")
    t.eq(change.set, { name = "Ania" })
    t.eq(change.pk, { id = "1" })
    t.eq(change.expect, { name = "Anna" })
  end,

  ["only sends the columns that changed"] = function()
    local result = compute({
      { id = 2, cells = { "2", "Bartek", "changed" } },
      { id = 1, cells = { "1", "Anna", "∅" } },
    })
    t.eq(#result.changes, 1)
    t.eq(result.changes[1].set, { note = "changed" })
  end,

  ["writing the placeholder sets SQL NULL"] = function()
    local result = compute({
      { id = 1, cells = { "1", "Anna", "∅" } },
      { id = 2, cells = { "2", "Bartek", "∅" } },
    })
    t.eq(#result.changes, 1)
    t.eq(result.changes[1].set.note, vim.NIL)
  end,

  ["writing the text NULL stores a string"] = function()
    local result = compute({
      { id = 1, cells = { "1", "Anna", "NULL" } },
      { id = 2, cells = { "2", "Bartek", "note" } },
    })
    t.eq(#result.changes, 1)
    t.eq(result.changes[1].set.note, "NULL")
  end,

  ["a removed line becomes a delete"] = function()
    local result = compute({
      { id = 1, cells = { "1", "Anna", "∅" } },
    })
    t.eq(#result.changes, 1)
    t.eq(result.changes[1].op, "delete")
    t.eq(result.changes[1].pk, { id = "2" })
  end,

  ["a new line becomes an insert"] = function()
    local result = compute({
      { id = 1, cells = { "1", "Anna", "∅" } },
      { id = 2, cells = { "2", "Bartek", "note" } },
      { id = nil, cells = { "3", "Celina", "fresh" } },
    })
    t.eq(#result.changes, 1)
    t.eq(result.changes[1].op, "insert")
    t.eq(result.changes[1].values, { id = "3", name = "Celina", note = "fresh" })
  end,

  ["empty cells on an insert fall back to column defaults"] = function()
    local result = compute({
      { id = 1, cells = { "1", "Anna", "∅" } },
      { id = 2, cells = { "2", "Bartek", "note" } },
      { id = nil, cells = { "", "Celina", "" } },
    })
    t.eq(result.changes[1].values, { name = "Celina" })
  end,

  ["a blank new line is ignored"] = function()
    local result = compute({
      { id = 1, cells = { "1", "Anna", "∅" } },
      { id = 2, cells = { "2", "Bartek", "note" } },
      { id = nil, cells = { "", "", "" } },
    })
    t.eq(result.changes, {})
  end,

  ["updates, inserts and deletes combine"] = function()
    local result = compute({
      { id = 1, cells = { "1", "Ania", "∅" } },
      { id = nil, cells = { "9", "New", "row" } },
    })
    local ops = vim.tbl_map(function(change)
      return change.op
    end, result.changes)
    table.sort(ops)
    t.eq(ops, { "delete", "insert", "update" })
  end,

  ["reordering rows changes nothing"] = function()
    local result = compute({
      { id = 2, cells = { "2", "Bartek", "note" } },
      { id = 1, cells = { "1", "Anna", "∅" } },
    })
    t.eq(result.changes, {})
  end,

  ["editing the primary key keeps the original key in the predicate"] = function()
    local result = compute({
      { id = 1, cells = { "42", "Anna", "∅" } },
      { id = 2, cells = { "2", "Bartek", "note" } },
    })
    t.eq(result.changes[1].set, { id = "42" })
    t.eq(result.changes[1].pk, { id = "1" }, "the WHERE clause must use the old key")
  end,

  ["refuses to write back a truncated cell"] = function()
    local long = string.rep("x", 80)
    local rows = { { "1", long, "note" } }
    local result = diff.compute({
      schema = "shop",
      table = "customers",
      columns = columns,
      primary = { "id" },
      snapshot = snapshot(rows),
      entries = { { id = 1, cells = { "1", "edited value", "note" } } },
    })
    t.eq(result.changes, {})
    t.eq(#result.errors, 1)
    t.matches(result.errors[1], "truncated")
  end,

  ["hidden columns are skipped but still keyed"] = function()
    local result = compute({
      { id = 1, cells = { "1", "Ania" } },
      { id = 2, cells = { "2", "Bartek" } },
    }, { hidden = { [3] = true } })
    t.eq(#result.changes, 1)
    t.eq(result.changes[1].set, { name = "Ania" })
  end,

  ["reports an error when the table has no primary key"] = function()
    local result = compute({
      { id = 1, cells = { "1", "Ania", "∅" } },
      { id = 2, cells = { "2", "Bartek", "note" } },
    }, { primary = {} })
    t.eq(result.changes, {})
    t.matches(result.errors[1], "primary key")
  end,
})

t.describe("data diff preview", {
  ["describes a mixed change set"] = function()
    local result = compute({
      { id = 1, cells = { "1", "Ania", "∅" } },
      { id = nil, cells = { "9", "New", "row" } },
    })
    local lines = diff.describe(result, "shop.customers")
    local text = table.concat(lines, "\n")

    t.matches(text, "shop%.customers")
    t.matches(text, "1 update")
    t.matches(text, "1 insert")
    t.matches(text, "1 delete")
    t.matches(text, "name: 'Anna' → 'Ania'")
  end,

  ["renders NULL transitions readably"] = function()
    local result = compute({
      { id = 1, cells = { "1", "Anna", "filled" } },
      { id = 2, cells = { "2", "Bartek", "note" } },
    })
    local text = table.concat(diff.describe(result, "shop.customers"), "\n")
    t.matches(text, "note: NULL → 'filled'")
  end,
})

t.describe("data diff reconciliation", {
  ["matches rows by primary key when the mark is lost"] = function()
    -- A line-wise edit can destroy or shift an extmark. The key still
    -- identifies the row, so the edit must land on it rather than becoming a
    -- delete plus an insert.
    local result = compute({
      { id = nil, cells = { "1", "Ania", "∅" } },
      { id = nil, cells = { "2", "Bartek", "note" } },
    })
    t.eq(#result.changes, 1)
    t.eq(result.changes[1].op, "update")
    t.eq(result.changes[1].pk, { id = "1" })
  end,

  ["a mark pointing at the wrong row does not win over the key"] = function()
    local result = compute({
      { id = 2, cells = { "1", "Ania", "∅" } },
      { id = 1, cells = { "2", "Bartek", "note" } },
    })
    t.eq(#result.changes, 1)
    t.eq(result.changes[1].pk, { id = "1" }, "the key must decide, not the mark")
    t.eq(result.changes[1].set, { name = "Ania" })
  end,

  ["falls back to the mark when the key itself was edited"] = function()
    local result = compute({
      { id = 1, cells = { "42", "Anna", "∅" } },
      { id = 2, cells = { "2", "Bartek", "note" } },
    })
    t.eq(#result.changes, 1)
    t.eq(result.changes[1].set, { id = "42" })
    t.eq(result.changes[1].pk, { id = "1" })
  end,

  ["duplicate keys fall back to marks instead of guessing"] = function()
    local snapshot = {
      [1] = { values = { "1", "same", "a" }, rendered = { "1", "same", "a" } },
      [2] = { values = { "1", "same", "b" }, rendered = { "1", "same", "b" } },
    }
    local result = diff.compute({
      schema = "shop",
      table = "customers",
      columns = columns,
      primary = { "id" },
      snapshot = snapshot,
      entries = {
        { id = 1, cells = { "1", "same", "A" } },
        { id = 2, cells = { "1", "same", "b" } },
      },
    })
    t.eq(#result.changes, 1)
    t.eq(result.changes[1].set, { note = "A" })
  end,

  ["a genuinely new row is still an insert"] = function()
    local result = compute({
      { id = nil, cells = { "1", "Anna", "∅" } },
      { id = nil, cells = { "2", "Bartek", "note" } },
      { id = nil, cells = { "7", "Nowa", "x" } },
    })
    t.eq(#result.changes, 1)
    t.eq(result.changes[1].op, "insert")
  end,

  ["works when the table has no primary key"] = function()
    local result = compute({
      { id = 1, cells = { "1", "Ania", "∅" } },
      { id = 2, cells = { "2", "Bartek", "note" } },
    }, { primary = {} })
    t.matches(result.errors[1], "primary key")
  end,
})

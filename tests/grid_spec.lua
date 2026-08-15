local t = require("tests.init")
local config = require("dbclient.config")
local grid = require("dbclient.ui.grid")

config.setup({ connections = {}, ui = { null_display = "∅", max_cell_width = 48 } })

local function columns(...)
  local list = {}
  for _, spec in ipairs({ ... }) do
    table.insert(list, { name = spec[1], class = spec[2] or "text" })
  end
  return list
end

t.describe("grid escaping", {
  ["escapes control characters"] = function()
    t.eq(grid.escape("a\nb"), "a\\nb")
    t.eq(grid.escape("a\tb"), "a\\tb")
    t.eq(grid.escape("a|b"), "a\\|b")
    t.eq(grid.escape("a\\b"), "a\\\\b")
  end,

  ["round trips every escape"] = function()
    for _, value in ipairs({
      "plain",
      "a\nb",
      "a\tb",
      "pipe | inside",
      "back\\slash",
      "mixed \\| \n \t end",
      "Łódź żółć",
      "",
    }) do
      t.eq(grid.unescape(grid.escape(value)), value, "round trip failed for " .. vim.inspect(value))
    end
  end,

  ["leaves unknown escapes alone"] = function()
    t.eq(grid.unescape("a\\qb"), "a\\qb")
  end,
})

t.describe("grid widths", {
  ["measures display width, not bytes"] = function()
    -- Every one of these is 4 display columns but more than 4 bytes.
    t.eq(grid.width("Łódź"), 4)
    t.eq(grid.width("żółć"), 4)
    t.eq(#"Łódź" > 4, true, "the byte length should differ from the display width")
  end,

  ["pads multibyte text to the right width"] = function()
    local padded = grid.pad("Łódź", 8, "left")
    t.eq(grid.width(padded), 8)
    t.eq(padded, "Łódź    ")
  end,

  ["right aligns numbers"] = function()
    t.eq(grid.pad("42", 5, "right"), "   42")
  end,

  ["truncates without splitting a codepoint"] = function()
    local cut = grid.truncate("Łódź żółć", 5)
    t.eq(grid.width(cut), 5)
    -- The result must still be valid UTF-8 that Neovim can put in a buffer.
    t.eq(vim.fn.strchars(cut) > 0, true)
    t.matches(cut, "…$")
  end,

  ["column widths account for the header"] = function()
    local cols = columns({ "identifier", "text" })
    local sizes = grid.widths(cols, { { "a" } })
    t.eq(sizes[1], 10)
  end,

  ["column widths are capped"] = function()
    config.setup({ connections = {}, ui = { max_cell_width = 6 } })
    local cols = columns({ "c", "text" })
    local sizes = grid.widths(cols, { { "a very long value indeed" } })
    t.eq(sizes[1], 6)
    config.setup({ connections = {}, ui = { null_display = "∅", max_cell_width = 48 } })
  end,
})

t.describe("grid null handling", {
  ["renders SQL NULL with the placeholder"] = function()
    local text, is_null = grid.display(vim.NIL, { class = "text" })
    t.eq(text, "∅")
    t.ok(is_null)
  end,

  ["renders the literal string NULL verbatim"] = function()
    local text, is_null = grid.display("NULL", { class = "text" })
    t.eq(text, "NULL")
    t.falsy(is_null)
  end,

  ["parses the placeholder back to NULL"] = function()
    t.eq(grid.parse_value("∅", { class = "text" }), vim.NIL)
    t.eq(grid.parse_value("NULL", { class = "text" }), "NULL")
  end,
})

t.describe("grid rows", {
  ["renders and parses a row"] = function()
    local cols = columns({ "id", "number" }, { "name", "text" }, { "note", "text" })
    local values = { "1", "Łódź", vim.NIL }
    local sizes = grid.widths(cols, { values })
    local line = grid.render_row(values, cols, sizes)
    local parsed = grid.parse_row(line)

    t.eq(#parsed, 3)
    t.eq(parsed[1], "1")
    t.eq(parsed[2], "Łódź")
    t.eq(grid.parse_value(parsed[3], cols[3]), vim.NIL)
  end,

  ["survives values containing the separator"] = function()
    local cols = columns({ "a", "text" }, { "b", "text" })
    local values = { "left | right", "second" }
    local sizes = grid.widths(cols, { values })
    local line = grid.render_row(values, cols, sizes)
    local parsed = grid.parse_row(line)

    t.eq(#parsed, 2)
    t.eq(grid.parse_value(parsed[1], cols[1]), "left | right")
    t.eq(grid.parse_value(parsed[2], cols[2]), "second")
  end,

  ["survives values containing newlines"] = function()
    local cols = columns({ "a", "text" })
    local values = { "first\nsecond" }
    local sizes = grid.widths(cols, { values })
    local line = grid.render_row(values, cols, sizes)

    t.falsy(line:find("\n"), "a rendered line must never contain a raw newline")
    t.eq(grid.parse_value(grid.parse_row(line)[1], cols[1]), "first\nsecond")
  end,

  ["reports NULL spans for highlighting"] = function()
    local cols = columns({ "a", "text" }, { "b", "text" })
    local sizes = grid.widths(cols, { { "x", vim.NIL } })
    local _, nulls = grid.render_row({ "x", vim.NIL }, cols, sizes)
    t.eq(#nulls, 1)
  end,

  ["skips hidden columns"] = function()
    local cols = columns({ "a", "text" }, { "b", "text" }, { "c", "text" })
    local values = { "1", "2", "3" }
    local sizes = grid.widths(cols, { values }, { [2] = true })
    local line = grid.render_row(values, cols, sizes, { [2] = true })
    local parsed = grid.parse_row(line)
    t.eq(#parsed, 2)
    t.eq(parsed[1], "1")
    t.eq(parsed[2], "3")
  end,
})

t.describe("grid spans", {
  ["locate the column under a byte offset"] = function()
    local cols = columns({ "aaa", "text" }, { "bbb", "text" })
    local sizes = grid.widths(cols, { { "1", "2" } })
    local spans = grid.spans(cols, sizes)

    t.eq(grid.column_at(spans, 0), 1)
    t.eq(grid.column_at(spans, spans[2].start), 2)
  end,

  ["report the start of a column"] = function()
    local cols = columns({ "aaa", "text" }, { "bbb", "text" })
    local sizes = grid.widths(cols, { { "1", "2" } })
    local spans = grid.spans(cols, sizes)
    t.eq(grid.column_start(spans, 1), 0)
    t.eq(grid.column_start(spans, 2), 3 + #grid.SEPARATOR)
  end,
})

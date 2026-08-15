local t = require("tests.init")
local config = require("dbclient.config")
local grid = require("dbclient.ui.grid")

config.setup({ connections = {}, max_cell_width = 48 })

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
    config.setup({ connections = {} })
  end,
})

t.describe("grid null handling", {
  ["renders SQL NULL as NULL, like every other client"] = function()
    local text, is_null = grid.display(vim.NIL, { class = "text" })
    t.eq(text, "NULL")
    t.ok(is_null)
  end,

  ["escapes a value that would render exactly like it"] = function()
    -- The grid is editable and round trips through text, so the SQL value and
    -- the four-letter string cannot be the same characters. One backslash is a
    -- smaller price than an unfamiliar symbol.
    local text, is_null = grid.display("NULL", { class = "text" })
    t.eq(text, "\\NULL")
    t.falsy(is_null)
  end,

  ["round-trips both of them"] = function()
    t.eq(grid.parse_value("NULL", { class = "text" }), vim.NIL)
    t.eq(grid.parse_value("\\NULL", { class = "text" }), "NULL")

    for _, value in ipairs({ vim.NIL, "NULL", "\\NULL", "null", "NULLED" }) do
      local rendered = grid.display(value, { class = "text" })
      t.eq(
        grid.parse_value(rendered, { class = "text" }),
        value,
        ("%s survived the round trip as %q"):format(tostring(value), rendered)
      )
    end
  end,

  ["follows the sentinel when it is configured to something else"] = function()
    config.setup({ connections = {}, ui = { null_display = "∅" } })
    t.eq((grid.display(vim.NIL, { class = "text" })), "∅")
    t.eq(grid.parse_value("∅", { class = "text" }), vim.NIL)
    -- And the collision moves with it: "NULL" is now an ordinary string.
    t.eq((grid.display("NULL", { class = "text" })), "NULL")
    t.eq(grid.parse_value("NULL", { class = "text" }), "NULL")
    config.setup({ connections = {} })
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
    -- Spans are display cells, so the separator counts as its width, not
    -- its byte length.
    t.eq(grid.column_start(spans, 2), 3 + grid.width(grid.SEPARATOR))
  end,
})

t.describe("spans against a real line", {
  --- The bug this guards: `spans` are display cells and every consumer feeds
  --- them to something that wants bytes. On a row holding "Łódź" the two
  --- differ, so highlights landed on the separator and following a foreign key
  --- read the neighbouring column.
  ["resolve to byte offsets on a multibyte row"] = function()
    local cols = columns({ "city", "text" }, { "n", "number" })
    local sizes = { 8, 3 }
    local line = grid.render_row({ "Łódź", "42" }, cols, sizes)
    local spans = grid.line_spans(line, grid.spans(cols, sizes))

    t.eq(line:sub(spans[1].start + 1, spans[1].finish), "Łódź    ")
    t.eq(line:sub(spans[2].start + 1, spans[2].finish), " 42")
  end,

  ["resolve on a row of double-width characters"] = function()
    local cols = columns({ "name", "text" }, { "n", "number" })
    local sizes = { 6, 3 }
    local line = grid.render_row({ "東京都", "7" }, cols, sizes)
    local spans = grid.line_spans(line, grid.spans(cols, sizes))

    t.eq(line:sub(spans[1].start + 1, spans[1].finish), "東京都")
    t.eq(line:sub(spans[2].start + 1, spans[2].finish), "  7")
  end,

  ["pass a pure-ASCII row straight through"] = function()
    local cols = columns({ "a", "text" }, { "b", "text" })
    local sizes = { 3, 3 }
    -- The rule glyph itself is multibyte, so an all-ASCII *row* is only
    -- unchanged under the ascii style.
    grid.use_style("ascii")
    local line = grid.render_row({ "xy", "z" }, cols, sizes)
    local spans = grid.spans(cols, sizes)
    t.eq(grid.line_spans(line, spans), spans)
    grid.use_style("line")
  end,

  ["find the column under a byte offset inside multibyte text"] = function()
    local cols = columns({ "city", "text" }, { "n", "number" })
    local sizes = { 8, 3 }
    local line = grid.render_row({ "Łódź", "42" }, cols, sizes)
    local spans = grid.line_spans(line, grid.spans(cols, sizes))

    -- A byte offset in the middle of the second column must not report the
    -- first, which is what happened before spans were resolved per line.
    t.eq(grid.column_at(spans, spans[2].start + 1), 2)
    t.eq(grid.column_at(spans, 0), 1)
  end,
})

t.describe("rule styles", {
  ["round-trip a value through either style"] = function()
    local cols = columns({ "note", "text" })
    for _, style in ipairs({ "line", "ascii" }) do
      grid.use_style(style)
      for _, value in ipairs({
        "plain",
        "has | a pipe",
        "has │ a bar",
        "back\\slash",
        "two\nlines",
      }) do
        local sizes = grid.widths(cols, { { value } })
        local line = grid.render_row({ value }, cols, sizes)
        local parsed = grid.parse_row(line)
        t.eq(#parsed, 1, style .. ": " .. value .. " stayed in one cell")
        t.eq(grid.parse_value(parsed[1], cols[1]), value, style .. ": " .. value)
      end
    end
    grid.use_style("line")
  end,

  ["store the same text whichever style is drawing"] = function()
    local cols = columns({ "note", "text" })
    grid.use_style("line")
    local drawn = grid.display("a | b │ c", cols[1])
    grid.use_style("ascii")
    t.eq(grid.display("a | b │ c", cols[1]), drawn, "escaping does not depend on the style")
    grid.use_style("line")
  end,

  ["draw the header rule in the active glyph"] = function()
    local cols = columns({ "id", "number" }, { "name", "text" })
    local sizes = { 2, 4 }

    grid.use_style("line")
    local _, underline = grid.render_header(cols, sizes)
    t.eq(underline, "──" .. "─┼─" .. "────")

    grid.use_style("ascii")
    local _, ascii = grid.render_header(cols, sizes)
    t.eq(ascii, "--" .. "-+-" .. "----")
    grid.use_style("line")
  end,

  ["fall back to the line style for an unknown name"] = function()
    grid.use_style("nonsense")
    t.eq(grid.SEPARATOR, grid.STYLES.line.separator)
    grid.use_style(nil)
    t.eq(grid.SEPARATOR, grid.STYLES.line.separator)
  end,
})

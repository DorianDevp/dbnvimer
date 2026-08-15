--- Shared grid rendering and parsing.
---
--- Three properties matter here and all three were broken before:
---
--- * Widths are measured in display cells, not bytes, so `Łódź` and CJK text
---   line up instead of shifting every column after them.
--- * Control characters are escaped rather than embedded, because a value
---   containing a newline used to make `nvim_buf_set_lines` fail and take the
---   whole buffer with it.
--- * SQL `NULL` renders differently from the literal text `"NULL"`, and the
---   round trip through the buffer preserves the difference.
---
--- Rendering is reversible: `parse_row(render_row(values))` returns the same
--- values. That is what makes the data buffer editable as plain text.

local config = require("dbclient.config")

local M = {}

--- How the grid draws its rules.
---
--- `line` is the default and is what makes a result set look like a table
--- rather than like terminal output; `ascii` exists for terminals and fonts
--- that mangle box-drawing characters.
---
--- Switching styles is safe at any time because escaping does not depend on it:
--- both candidate delimiters are always escaped in stored text, so a value is
--- rendered and parsed identically either way.
M.STYLES = {
  line = { separator = " │ ", corner = "─┼─", delimiter = "│", rule = "─" },
  ascii = { separator = " | ", corner = "-+-", delimiter = "|", rule = "-" },
}

M.SEPARATOR = M.STYLES.line.separator
M.CORNER = M.STYLES.line.corner
M.DELIMITER = M.STYLES.line.delimiter
M.RULE = M.STYLES.line.rule

--- Adopt a rule style. Called from `setup()`; safe to call at any time.
---@param name string|nil
function M.use_style(name)
  local style = M.STYLES[name or "line"] or M.STYLES.line
  M.SEPARATOR, M.CORNER = style.separator, style.corner
  M.DELIMITER, M.RULE = style.delimiter, style.rule
end

--- Escape sequences, as `character = code`. Codes are always one ASCII byte,
--- so an escape is always exactly two bytes and the parser never has to decode
--- UTF-8 to find a boundary.
local ESCAPES = {
  ["\\"] = "\\",
  ["\n"] = "n",
  ["\r"] = "r",
  ["\t"] = "t",
  ["|"] = "|",
  ["│"] = "v",
}

local UNESCAPES = {}
for character, code in pairs(ESCAPES) do
  UNESCAPES[code] = character
end

--- Escape a value for display inside one grid cell.
---
--- Backslash, both candidate column separators and the control characters that
--- would break a single-line buffer entry are escaped, so the text stays on one
--- line and can be parsed back unambiguously.
---@param text string
---@return string
function M.escape(text)
  return (
    text
      :gsub("\\", "\\\\")
      :gsub("\n", "\\n")
      :gsub("\r", "\\r")
      :gsub("\t", "\\t")
      :gsub("|", "\\|")
      :gsub("│", "\\v")
  )
end

--- Inverse of `M.escape`.
---@param text string
---@return string
function M.unescape(text)
  local out = {}
  local index = 1
  local length = #text
  while index <= length do
    local char = text:sub(index, index)
    if char == "\\" and index < length then
      local mapped = UNESCAPES[text:sub(index + 1, index + 1)]
      if mapped then
        table.insert(out, mapped)
        index = index + 2
      else
        table.insert(out, char)
        index = index + 1
      end
    else
      table.insert(out, char)
      index = index + 1
    end
  end
  return table.concat(out)
end

--- Display width in terminal cells.
---@param text string
---@return integer
function M.width(text)
  return vim.fn.strdisplaywidth(text)
end

--- Cut `text` to at most `width` display cells, marking the cut with an ellipsis.
---@param text string
---@param width integer
---@return string
function M.truncate(text, width)
  if width <= 0 then
    return ""
  end
  if M.width(text) <= width then
    return text
  end

  local out = {}
  local used = 0
  local count = vim.fn.strchars(text)
  for index = 0, count - 1 do
    local char = vim.fn.strcharpart(text, index, 1)
    local char_width = M.width(char)
    if used + char_width > width - 1 then
      break
    end
    table.insert(out, char)
    used = used + char_width
  end
  return table.concat(out) .. "…"
end

--- Pad `text` to `width` display cells.
---@param text string
---@param width integer
---@param align "left"|"right"
---@return string
function M.pad(text, width, align)
  local text_width = M.width(text)
  if text_width > width then
    text = M.truncate(text, width)
    text_width = M.width(text)
  end
  local fill = string.rep(" ", math.max(0, width - text_width))
  if align == "right" then
    return fill .. text
  end
  return text .. fill
end

--- How a column of this class should be aligned.
---@param class string|nil
---@return "left"|"right"
function M.alignment(class)
  return class == "number" and "right" or "left"
end

--- Render one value as display text.
---
--- Returns the text plus a flag saying whether the cell is a SQL NULL, which
--- the caller uses to pick a highlight group.
---
--- A value that would render exactly like the NULL sentinel is prefixed with a
--- backslash. The sentinel says `NULL` because that is what every client says
--- and there is no reason to be different; but this grid is editable and round
--- trips through text, so the SQL value and the four-letter string have to be
--- distinguishable, and one escaped character is a smaller price than an
--- unfamiliar symbol.
---@param value any
---@param column table|nil
---@return string text, boolean is_null
function M.display(value, column)
  if value == nil or value == vim.NIL then
    return config.get().ui.null_display, true
  end

  if type(value) == "boolean" then
    local labels = config.get().ui.bool_display
    return value and labels[1] or labels[2], false
  end

  local text = tostring(value)

  if column and column.class == "bool" then
    local labels = config.get().ui.bool_display
    if text == "1" or text == "t" or text == "true" then
      return labels[1], false
    end
    if text == "0" or text == "f" or text == "false" then
      return labels[2], false
    end
  end

  local escaped = M.escape(text)
  if escaped == config.get().ui.null_display then
    escaped = "\\" .. escaped
  end
  return escaped, false
end

--- Turn display text back into a value.
---
--- The null placeholder maps back to `vim.NIL`; everything else is a string,
--- because the core coerces to the column's real type.
---@param text string
---@param column table|nil
---@return any
function M.parse_value(text, column)
  local settings = config.get().ui
  if text == settings.null_display then
    return vim.NIL
  end
  -- The escaped sentinel is the literal string, not the SQL value. Checked
  -- before `unescape`, which knows nothing about the sentinel.
  if text == "\\" .. settings.null_display then
    return settings.null_display
  end

  if column and column.class == "bool" then
    if text == settings.bool_display[1] then
      return "true"
    end
    if text == settings.bool_display[2] then
      return "false"
    end
  end

  return M.unescape(text)
end

--- Column widths for a result set, capped by `ui.max_cell_width`.
---@param columns table[]
---@param rows table[]
---@param hidden table<integer, boolean>|nil
---@return integer[]
function M.widths(columns, rows, hidden)
  local max_cell = config.get().ui.max_cell_width
  local sizes = {}

  for index, column in ipairs(columns) do
    if not (hidden and hidden[index]) then
      sizes[index] = math.min(max_cell, M.width(column.name or tostring(column)))
    end
  end

  for _, row in ipairs(rows) do
    for index in ipairs(columns) do
      if not (hidden and hidden[index]) then
        local text = M.display(row[index], columns[index])
        sizes[index] = math.min(max_cell, math.max(sizes[index] or 0, M.width(text)))
      end
    end
  end

  return sizes
end

--- Where each visible column sits, measured in display cells.
---
--- Cells, not bytes, because that is what alignment is in and it is the same
--- for every row. Extmarks and the cursor want bytes, which differ per row as
--- soon as any value leaves ASCII — run the span through `M.line_spans` with
--- the line in question before using it as an offset.
---@param columns table[]
---@param sizes integer[]
---@param hidden table<integer, boolean>|nil
---@return table[] spans  measured in display cells; see `M.line_spans`
function M.spans(columns, sizes, hidden)
  local spans = {}
  local offset = 0
  local separator = M.width(M.SEPARATOR)
  for index in ipairs(columns) do
    if not (hidden and hidden[index]) then
      local width = sizes[index] or 0
      spans[index] = { start = offset, finish = offset + width, width = width }
      offset = offset + width + separator
    end
  end
  return spans
end

--- Render the header and its underline.
---@param columns table[]
---@param sizes integer[]
---@param hidden table<integer, boolean>|nil
---@return string header, string underline
function M.render_header(columns, sizes, hidden)
  local header, underline = {}, {}
  for index, column in ipairs(columns) do
    if not (hidden and hidden[index]) then
      local width = sizes[index] or 0
      table.insert(header, M.pad(column.name or tostring(column), width, "left"))
      table.insert(underline, string.rep(M.RULE, width))
    end
  end
  return table.concat(header, M.SEPARATOR), table.concat(underline, M.CORNER)
end

--- Render one data row.
---@param values table
---@param columns table[]
---@param sizes integer[]
---@param hidden table<integer, boolean>|nil
---@return string line, table[] nulls  cell spans of NULL cells, as `M.spans`
function M.render_row(values, columns, sizes, hidden)
  local cells = {}
  local nulls = {}
  local offset = 0
  local separator = M.width(M.SEPARATOR)

  for index, column in ipairs(columns) do
    if not (hidden and hidden[index]) then
      local width = sizes[index] or 0
      local text, is_null = M.display(values[index], column)
      local padded = M.pad(text, width, M.alignment(column.class))
      table.insert(cells, padded)
      if is_null then
        table.insert(nulls, { start = offset, finish = offset + width })
      end
      offset = offset + width + separator
    end
  end

  return table.concat(cells, M.SEPARATOR), nulls
end

--- Split a rendered line back into per-column display text.
---
--- An escaped separator is not a split point, which is what makes the round
--- trip safe for values containing the delimiter. Escapes are always two bytes,
--- so skipping one can never land inside a multi-byte delimiter.
---@param line string
---@param delimiter? string  defaults to the active style's
---@return string[]
function M.parse_row(line, delimiter)
  delimiter = delimiter or M.DELIMITER
  local size = #delimiter
  local cells = {}
  local current = {}
  local index = 1
  local length = #line

  while index <= length do
    local char = line:sub(index, index)
    if char == "\\" and index < length then
      table.insert(current, line:sub(index, index + 1))
      index = index + 2
    elseif line:sub(index, index + size - 1) == delimiter then
      table.insert(cells, table.concat(current))
      current = {}
      index = index + size
    else
      table.insert(current, char)
      index = index + 1
    end
  end
  table.insert(cells, table.concat(current))

  for position, cell in ipairs(cells) do
    cells[position] = vim.trim(cell)
  end
  return cells
end

--- Resolve display-cell spans to byte offsets within one concrete line.
---
--- `M.spans` measures in display cells because that is what alignment is in;
--- extmarks and `nvim_win_set_cursor` want bytes. On any row containing text
--- outside ASCII the two disagree — a row holding "Łódź" put every span two
--- bytes early, so highlights landed on the separator and following a foreign
--- key read the wrong column. Anything using a span against a real line has to
--- come through here.
---@param line string
---@param spans table[]
---@return table[]
function M.line_spans(line, spans)
  -- Overwhelmingly the common case, and worth taking: when the line is pure
  -- ASCII its byte offsets and its cell offsets are the same numbers.
  if #line == M.width(line) then
    return spans
  end

  local byte_of = {}
  local cell, bytes = 0, 0
  for _, char in ipairs(vim.fn.split(line, "\\zs")) do
    local width = M.width(char)
    -- A double-width character occupies two cells; both map to its first byte.
    for step = 0, math.max(0, width - 1) do
      byte_of[cell + step] = bytes
    end
    cell = cell + width
    bytes = bytes + #char
  end
  byte_of[cell] = bytes

  local resolved = {}
  for index, span in pairs(spans) do
    local start = byte_of[span.start] or #line
    local finish = byte_of[span.finish] or #line
    resolved[index] = { start = start, finish = finish, width = span.width }
  end
  return resolved
end

--- Which column a byte offset falls into.
---@param spans table[]
---@param byte_offset integer
---@return integer|nil
function M.column_at(spans, byte_offset)
  local best
  for index, span in pairs(spans) do
    if byte_offset >= span.start and byte_offset <= span.finish then
      return index
    end
    if span.start <= byte_offset then
      best = index
    end
  end
  return best
end

--- Byte offset of the start of a column, for cursor placement.
---@param spans table[]
---@param column integer
---@return integer
function M.column_start(spans, column)
  local span = spans[column]
  return span and span.start or 0
end

return M

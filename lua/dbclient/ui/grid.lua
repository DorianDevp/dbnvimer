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

M.SEPARATOR = " | "
M.CORNER = "-+-"

--- Escape a value for display inside one grid cell.
---
--- Backslash, the column separator and the control characters that would break
--- a single-line buffer entry are escaped so the text stays on one line and can
--- be parsed back unambiguously.
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
      local next_char = text:sub(index + 1, index + 1)
      local mapped = ({ n = "\n", r = "\r", t = "\t", ["\\"] = "\\", ["|"] = "|" })[next_char]
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

  return M.escape(text), false
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

--- Visible byte spans for each column in a rendered line.
---
--- Spans are byte offsets so they can be handed straight to extmarks; the
--- cursor helpers convert to and from them.
---@param columns table[]
---@param sizes integer[]
---@param hidden table<integer, boolean>|nil
---@return table[] spans
function M.spans(columns, sizes, hidden)
  local spans = {}
  local offset = 0
  for index in ipairs(columns) do
    if not (hidden and hidden[index]) then
      local width = sizes[index] or 0
      spans[index] = { start = offset, finish = offset + width, width = width }
      offset = offset + width + #M.SEPARATOR
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
      table.insert(underline, string.rep("-", width))
    end
  end
  return table.concat(header, M.SEPARATOR), table.concat(underline, M.CORNER)
end

--- Render one data row.
---@param values table
---@param columns table[]
---@param sizes integer[]
---@param hidden table<integer, boolean>|nil
---@return string line, table[] nulls  byte spans of NULL cells
function M.render_row(values, columns, sizes, hidden)
  local cells = {}
  local nulls = {}
  local offset = 0

  for index, column in ipairs(columns) do
    if not (hidden and hidden[index]) then
      local width = sizes[index] or 0
      local text, is_null = M.display(values[index], column)
      local padded = M.pad(text, width, M.alignment(column.class))
      table.insert(cells, padded)
      if is_null then
        table.insert(nulls, { start = offset, finish = offset + #padded })
      end
      offset = offset + #padded + #M.SEPARATOR
    end
  end

  return table.concat(cells, M.SEPARATOR), nulls
end

--- Split a rendered line back into per-column display text.
---
--- Escaped separators (`\|`) are not split points, which is what makes the
--- round trip safe for values containing a pipe.
---@param line string
---@return string[]
function M.parse_row(line)
  local cells = {}
  local current = {}
  local index = 1
  local length = #line

  while index <= length do
    local char = line:sub(index, index)
    if char == "\\" and index < length then
      table.insert(current, line:sub(index, index + 1))
      index = index + 2
    elseif char == "|" then
      table.insert(cells, table.concat(current))
      current = {}
      index = index + 1
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

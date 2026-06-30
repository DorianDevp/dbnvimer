local config = require("dbclient.config")
local buffer = require("dbclient.ui.buffer")
local highlights = require("dbclient.ui.highlights")
local window = require("dbclient.ui.window")

local M = {}

local function stringify(value)
  if value == nil or value == vim.NIL then
    return "NULL"
  end
  return tostring(value)
end

local function widths(columns, rows)
  local max_cell = config.get().ui.max_cell_width
  local result = {}

  for index, column in ipairs(columns) do
    result[index] = math.min(max_cell, #column)
  end

  for _, row in ipairs(rows) do
    for index, value in ipairs(row) do
      result[index] = math.min(max_cell, math.max(result[index] or 0, #stringify(value)))
    end
  end

  return result
end

local function pad(value, width)
  value = stringify(value)
  if #value > width then
    value = value:sub(1, math.max(1, width - 1)) .. "~"
  end
  return value .. string.rep(" ", width - #value)
end

local function render_table(result)
  local columns = result.columns or {}
  local rows = result.rows or {}

  if #columns == 0 then
    return { "OK. affected rows: " .. tostring(result.affected_rows or 0) }
  end

  local sizes = widths(columns, rows)
  local lines = {}
  local header = {}
  local separator = {}

  for index, column in ipairs(columns) do
    header[index] = pad(column, sizes[index])
    separator[index] = string.rep("-", sizes[index])
  end

  table.insert(lines, table.concat(header, " | "))
  table.insert(lines, table.concat(separator, "-+-"))

  for _, row in ipairs(rows) do
    local cells = {}
    for index in ipairs(columns) do
      cells[index] = pad(row[index], sizes[index])
    end
    table.insert(lines, table.concat(cells, " | "))
  end

  return lines
end

function M.show(result)
  local height = config.get().ui.result_height
  local buf = buffer.open_or_create("DBClient Results", "botright " .. height .. "new")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "dbclient-result"
  buf = buffer.set_name(buf, "DBClient Results")
  local lines = render_table(result)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.wo.cursorline = true
  highlights.table(buf, #lines)
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, silent = true })
  vim.keymap.set("n", "F", window.toggle_fullscreen, { buffer = buf, silent = true })
end

return M

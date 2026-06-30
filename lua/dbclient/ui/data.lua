local config = require("dbclient.config")
local state = require("dbclient.state")
local window = require("dbclient.ui.window")

local M = {
  buf = nil,
  view = nil,
}

local function stringify(value)
  if value == nil or value == vim.NIL then
    return "NULL"
  end
  return tostring(value)
end

local function widths(columns, rows)
  local max_cell = config.get().ui.max_cell_width
  local sizes = {}

  for index, column in ipairs(columns) do
    sizes[index] = math.min(max_cell, #column)
  end

  for _, row in ipairs(rows) do
    for index, value in ipairs(row) do
      sizes[index] = math.min(max_cell, math.max(sizes[index] or 0, #stringify(value)))
    end
  end

  return sizes
end

local function pad(value, width)
  value = stringify(value)
  if #value > width then
    value = value:sub(1, math.max(1, width - 1)) .. "~"
  end
  return value .. string.rep(" ", width - #value)
end

local function primary_columns(columns_meta)
  local primary = {}
  for _, column in ipairs(columns_meta) do
    if column.key == "PRI" then
      table.insert(primary, column.name)
    end
  end
  return primary
end

local function row_map(view, row)
  local values = {}
  for index, column in ipairs(view.columns) do
    values[column] = row[index]
  end
  return values
end

local function pk_for_row(view, row)
  local values = row_map(view, row)
  local pk = {}
  for _, column in ipairs(view.primary) do
    pk[column] = values[column]
  end
  return pk
end

local function render(view)
  local lines = {
    view.schema .. "." .. view.table .. "  rows:" .. #view.rows .. "  limit:" .. view.limit,
  }
  local sizes = widths(view.columns, view.rows)
  local spans = {}
  local header = {}
  local separator = {}
  local col = 1

  for index, column in ipairs(view.columns) do
    header[index] = pad(column, sizes[index])
    separator[index] = string.rep("-", sizes[index])
    spans[index] = { start = col, finish = col + sizes[index] - 1 }
    col = col + sizes[index] + 3
  end

  table.insert(lines, table.concat(header, " | "))
  table.insert(lines, table.concat(separator, "-+-"))

  for _, row in ipairs(view.rows) do
    local cells = {}
    for index in ipairs(view.columns) do
      cells[index] = pad(row[index], sizes[index])
    end
    table.insert(lines, table.concat(cells, " | "))
  end

  view.spans = spans
  return lines
end

local function current_cell()
  local view = M.view
  if not view then
    return nil
  end

  local row_nr, col_nr = unpack(vim.api.nvim_win_get_cursor(0))
  local data_index = row_nr - 3
  if data_index < 1 or data_index > #view.rows then
    return nil
  end

  col_nr = col_nr + 1
  for index, span in ipairs(view.spans) do
    if col_nr >= span.start and col_nr <= span.finish then
      return {
        row_index = data_index,
        column_index = index,
        column = view.columns[index],
        row = view.rows[data_index],
        span = span,
      }
    end
  end
end

local function move_to_cell(row_index, column_index)
  local view = M.view
  if not view then
    return
  end
  row_index = math.max(1, math.min(row_index, #view.rows))
  column_index = math.max(1, math.min(column_index, #view.columns))
  local span = view.spans[column_index]
  vim.api.nvim_win_set_cursor(0, { row_index + 3, span.start - 1 })
end

function M.move_column(delta)
  local cell = current_cell()
  if cell then
    move_to_cell(cell.row_index, cell.column_index + delta)
  end
end

function M.move_row(delta)
  local cell = current_cell()
  if cell then
    move_to_cell(cell.row_index + delta, cell.column_index)
  end
end

function M.edit_cell()
  local cell = current_cell()
  if not cell then
    vim.notify("DBClient: move onto a data cell first", vim.log.levels.WARN)
    return
  end

  if #M.view.primary == 0 then
    vim.notify("DBClient: table has no primary key; refusing blind update", vim.log.levels.WARN)
    return
  end

  local old = stringify(cell.row[cell.column_index])
  vim.ui.input({ prompt = cell.column .. " = ", default = old }, function(input)
    if input == nil then
      return
    end

    local value = input == "NULL" and vim.NIL or input
    local ok, err = pcall(state.update_cell, M.view.schema, M.view.table, cell.column, value, pk_for_row(M.view, cell.row))
    if not ok then
      vim.notify("DBClient update failed: " .. err, vim.log.levels.ERROR)
      return
    end

    M.open(M.view.schema, M.view.table, M.view.limit)
  end)
end

function M.refresh()
  if M.view then
    M.open(M.view.schema, M.view.table, M.view.limit)
  end
end

function M.open(schema, table_name, limit)
  limit = limit or config.get().ui.preview_limit
  local result = state.preview(schema, table_name, limit)
  local columns_meta = state.columns(schema, table_name, false)

  M.view = {
    schema = schema,
    table = table_name,
    limit = limit,
    columns = result.columns or {},
    rows = result.rows or {},
    primary = primary_columns(columns_meta),
    spans = {},
  }

  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    vim.cmd("enew")
    M.buf = vim.api.nvim_get_current_buf()
  elseif not window.focus(M.buf) then
    vim.cmd("split")
    vim.api.nvim_win_set_buf(0, M.buf)
  end

  vim.bo[M.buf].buftype = "nofile"
  vim.bo[M.buf].bufhidden = "hide"
  vim.bo[M.buf].swapfile = false
  vim.bo[M.buf].filetype = "dbclient-data"
  vim.api.nvim_buf_set_name(M.buf, "DBClient Data - " .. schema .. "." .. table_name)
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, render(M.view))
  vim.bo[M.buf].modifiable = false

  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = M.buf, silent = true })
  vim.keymap.set("n", "r", M.refresh, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "E", M.edit_cell, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "]c", function() M.move_column(1) end, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "[c", function() M.move_column(-1) end, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "]r", function() M.move_row(1) end, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "[r", function() M.move_row(-1) end, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "F", window.toggle_fullscreen, { buffer = M.buf, silent = true })

  if #M.view.rows > 0 and #M.view.columns > 0 then
    move_to_cell(1, 1)
  end
end

return M

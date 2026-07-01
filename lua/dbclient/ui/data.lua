local config = require("dbclient.config")
local buffer = require("dbclient.ui.buffer")
local highlights = require("dbclient.ui.highlights")
local state = require("dbclient.state")
local window = require("dbclient.ui.window")

local M = {
  buf = nil,
  view = nil,
  edit_popup = nil,
  transaction_popup = nil,
  transaction = nil,
}

local function stringify(value)
  if value == nil or value == vim.NIL then
    return "NULL"
  end
  return tostring(value)
end

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shorten(value, width)
  value = stringify(value)
  if #value <= width then
    return value
  end
  return value:sub(1, math.max(1, width - 1)) .. "~"
end

local function change_count()
  return M.transaction and #M.transaction.order or 0
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

local function original_pk_for_row(view, row, row_index)
  local pk = pk_for_row(view, row)
  local transaction = M.transaction
  if not transaction then
    return pk
  end

  for _, key in ipairs(transaction.order) do
    local change = transaction.changes[key]
    if change and change.row_index == row_index then
      for _, column in ipairs(view.primary) do
        if change.column == column then
          pk[column] = change.old_value
        end
      end
    end
  end

  return pk
end

local function render(view)
  local lines = {
    view.schema
      .. "."
      .. view.table
      .. "  rows:"
      .. #view.rows
      .. "  limit:"
      .. view.limit
      .. "  pending:"
      .. change_count(),
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

local function redraw_view(row_index, column_index)
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) or not M.view then
    return
  end

  vim.bo[M.buf].modifiable = true
  local lines = render(M.view)
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  highlights.table(M.buf, #lines)

  if row_index and column_index then
    move_to_cell(row_index, column_index)
  end
end

local function close_edit_popup()
  local popup = M.edit_popup
  M.edit_popup = nil

  if popup and popup.win and vim.api.nvim_win_is_valid(popup.win) then
    vim.api.nvim_win_close(popup.win, true)
  end

  if popup and popup.buf and vim.api.nvim_buf_is_valid(popup.buf) then
    pcall(vim.api.nvim_buf_delete, popup.buf, { force = true })
  end
end

local function close_transaction_popup()
  local popup = M.transaction_popup
  M.transaction_popup = nil

  if popup and popup.win and vim.api.nvim_win_is_valid(popup.win) then
    vim.api.nvim_win_close(popup.win, true)
  end

  if popup and popup.buf and vim.api.nvim_buf_is_valid(popup.buf) then
    pcall(vim.api.nvim_buf_delete, popup.buf, { force = true })
  end
end

local function leave_insert_mode()
  if vim.fn.mode():match("^[iR]") then
    vim.cmd("stopinsert")
  end
end

local function input_value(input)
  return input == "NULL" and vim.NIL or input
end

local function same_value(left, right)
  return stringify(left) == stringify(right)
end

local function ensure_transaction()
  if M.transaction then
    return M.transaction
  end

  M.transaction = {
    schema = M.view.schema,
    table = M.view.table,
    order = {},
    changes = {},
  }
  vim.notify("DBClient: transaction started", vim.log.levels.INFO)
  return M.transaction
end

local function remove_pending_change(transaction, key)
  transaction.changes[key] = nil
  for index, existing in ipairs(transaction.order) do
    if existing == key then
      table.remove(transaction.order, index)
      break
    end
  end

  if #transaction.order == 0 then
    M.transaction = nil
  end
end

local function track_cell_value(cell, input)
  if input == nil then
    return
  end

  local transaction = ensure_transaction()
  local key = cell.row_index .. ":" .. cell.column_index
  local change = transaction.changes[key]
  local old_value = change and change.old_value or cell.row[cell.column_index]
  local new_value = input_value(input)

  if same_value(old_value, new_value) then
    cell.row[cell.column_index] = old_value
    if change then
      remove_pending_change(transaction, key)
    end
    redraw_view(cell.row_index, cell.column_index)
    return
  end

  if not change then
    table.insert(transaction.order, key)
  end

  transaction.changes[key] = {
    row_index = cell.row_index,
    column_index = cell.column_index,
    column = cell.column,
    old_value = old_value,
    new_value = new_value,
    pk = original_pk_for_row(M.view, cell.row, cell.row_index),
  }

  cell.row[cell.column_index] = new_value
  redraw_view(cell.row_index, cell.column_index)
end

local function apply_cell_value(cell, input)
  if input == nil then
    return
  end

  local value = input_value(input)
  local ok, err = pcall(state.update_cell, M.view.schema, M.view.table, cell.column, value, pk_for_row(M.view, cell.row))
  if not ok then
    vim.notify("DBClient update failed: " .. err, vim.log.levels.ERROR)
    return
  end

  M.open(M.view.schema, M.view.table, M.view.limit)
end

local function pending_updates()
  local updates = {}
  local transaction = M.transaction
  if not transaction then
    return updates
  end

  for _, key in ipairs(transaction.order) do
    local change = transaction.changes[key]
    if change then
      table.insert(updates, {
        schema = transaction.schema,
        table = transaction.table,
        column = change.column,
        value = change.new_value,
        pk = change.pk,
      })
    end
  end

  return updates
end

local function commit_transaction()
  local updates = pending_updates()
  if #updates == 0 then
    close_transaction_popup()
    vim.notify("DBClient: no pending transaction", vim.log.levels.INFO)
    return
  end

  local schema = M.transaction.schema
  local table_name = M.transaction.table
  local limit = M.view.limit
  local ok, err = pcall(state.update_cells, updates)
  if not ok then
    vim.notify("DBClient transaction failed: " .. err, vim.log.levels.ERROR)
    return
  end

  M.transaction = nil
  close_transaction_popup()
  M.open(schema, table_name, limit)
end

local function rollback_transaction()
  local transaction = M.transaction
  if not transaction then
    close_transaction_popup()
    return
  end

  for _, key in ipairs(transaction.order) do
    local change = transaction.changes[key]
    if change and M.view.rows[change.row_index] then
      M.view.rows[change.row_index][change.column_index] = change.old_value
    end
  end

  M.transaction = nil
  close_transaction_popup()
  redraw_view()
  vim.notify("DBClient: transaction rolled back", vim.log.levels.INFO)
end

local function open_edit_popup(cell, on_submit)
  close_edit_popup()

  local old = stringify(cell.row[cell.column_index])
  local title = " " .. cell.column .. " old: " .. shorten(old, 24) .. " "
  local width = math.max(32, math.min(72, math.max(#old, #cell.column) + 8))
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "left",
  })

  M.edit_popup = { buf = buf, win = win }
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "dbclient-cell"
  vim.wo[win].wrap = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

  local submitted = false
  local function submit()
    if submitted then
      return
    end
    submitted = true

    local was_insert = vim.fn.mode():match("^[iR]") ~= nil
    leave_insert_mode()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local input = trim(lines[1] or "")
    close_edit_popup()
    on_submit(cell, input)
    if was_insert then
      vim.schedule(leave_insert_mode)
    end
  end

  local function cancel()
    leave_insert_mode()
    close_edit_popup()
    vim.schedule(leave_insert_mode)
  end

  vim.keymap.set("n", "<CR>", submit, { buffer = buf, silent = true })
  vim.keymap.set("i", "<CR>", submit, { buffer = buf, silent = true })
  vim.keymap.set("n", "q", cancel, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, silent = true })
  vim.keymap.set("i", "<Esc>", cancel, { buffer = buf, silent = true })

  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.cmd("startinsert")
end

local function transaction_lines()
  local transaction = M.transaction
  local lines = { "pending cell changes", "" }

  if not transaction or #transaction.order == 0 then
    table.insert(lines, "no pending changes")
  else
    for index, key in ipairs(transaction.order) do
      local change = transaction.changes[key]
      if change then
        table.insert(
          lines,
          index
            .. ". row "
            .. change.row_index
            .. " "
            .. change.column
            .. ": "
            .. stringify(change.old_value)
            .. " -> "
            .. stringify(change.new_value)
        )
      end
    end
  end

  table.insert(lines, "")
  table.insert(lines, "c commit  r rollback  q cancel")
  return lines
end

function M.open_transaction_popup()
  close_transaction_popup()

  local lines = transaction_lines()
  local width = 40
  for _, line in ipairs(lines) do
    width = math.max(width, #line + 2)
  end
  width = math.min(width, math.max(20, vim.o.columns - 4))
  local height = math.min(#lines, math.max(1, vim.o.lines - 4))
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " transaction ",
    title_pos = "left",
  })

  M.transaction_popup = { buf = buf, win = win }
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "dbclient-transaction"
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.wo[win].wrap = false

  vim.keymap.set("n", "c", commit_transaction, { buffer = buf, silent = true })
  vim.keymap.set("n", "r", rollback_transaction, { buffer = buf, silent = true })
  vim.keymap.set("n", "q", close_transaction_popup, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", close_transaction_popup, { buffer = buf, silent = true })
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

local function editable_cell()
  local cell = current_cell()
  if not cell then
    vim.notify("DBClient: move onto a data cell first", vim.log.levels.WARN)
    return nil
  end

  if #M.view.primary == 0 then
    vim.notify("DBClient: table has no primary key; refusing blind update", vim.log.levels.WARN)
    return nil
  end

  return cell
end

function M.edit_cell()
  local cell = editable_cell()
  if cell then
    open_edit_popup(cell, track_cell_value)
  end
end

function M.edit_cell_immediate()
  if change_count() > 0 then
    vim.notify("DBClient: commit or rollback the pending transaction before an immediate update", vim.log.levels.WARN)
    return
  end

  local cell = editable_cell()
  if cell then
    open_edit_popup(cell, apply_cell_value)
  end
end

function M.refresh()
  if M.view then
    if change_count() > 0 then
      vim.notify("DBClient: commit or rollback the pending transaction before refreshing", vim.log.levels.WARN)
      return
    end
    M.open(M.view.schema, M.view.table, M.view.limit)
  end
end

function M.open(schema, table_name, limit)
  if change_count() > 0 then
    vim.notify("DBClient: commit or rollback the pending transaction before opening data", vim.log.levels.WARN)
    return
  end

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
  M.buf = buffer.set_name(M.buf, "DBClient Data - " .. schema .. "." .. table_name)
  vim.bo[M.buf].modifiable = true
  local lines = render(M.view)
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  vim.wo.cursorline = true
  vim.wo.cursorcolumn = true
  highlights.table(M.buf, #lines)

  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = M.buf, silent = true })
  vim.keymap.set("n", "r", M.refresh, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "i", M.edit_cell, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "I", M.edit_cell_immediate, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "E", M.edit_cell_immediate, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "T", M.open_transaction_popup, { buffer = M.buf, silent = true })
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

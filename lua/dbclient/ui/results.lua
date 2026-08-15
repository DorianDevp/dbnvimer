--- Read-only result grid for query output.
---
--- Shares the rendering, navigation and text objects with the data buffer;
--- what it does not share is writability, because a join result has no single
--- table to write back to.

local buffer = require("dbclient.ui.buffer")
local config = require("dbclient.config")
local export = require("dbclient.export")
local grid = require("dbclient.ui.grid")
local help = require("dbclient.ui.help")
local highlights = require("dbclient.ui.highlights")
local keymap = require("dbclient.keymap")
local value_inspector = require("dbclient.ui.value")
local window = require("dbclient.ui.window")
local winbar = require("dbclient.ui.winbar")

local M = {
  views = {},
}

local HEADER_LINES = 3

function M.view(bufnr)
  return M.views[bufnr or vim.api.nvim_get_current_buf()]
end

local function header_text(view)
  local parts = {}

  if #view.columns > 0 then
    table.insert(parts, ("%d row(s)"):format(#view.rows))
  else
    table.insert(parts, ("%d row(s) affected"):format(view.affected_rows or 0))
  end
  table.insert(parts, ("%d ms"):format(view.elapsed_ms or 0))
  if view.truncated then
    table.insert(parts, ("truncated at %d"):format(#view.rows))
  end
  if view.kind then
    table.insert(parts, view.kind)
  end
  if view.session_name then
    table.insert(parts, view.session_name)
  end

  return table.concat(parts, "  ·  ")
end

--- Show a result set.
---@param result table  the core's query output
---@param opts? { session_id?: string, session_name?: string, sql?: string, title?: string }
function M.show(result, opts)
  opts = opts or {}

  local bufnr = buffer.scratch("dbclient://results", { modifiable = false, buftype = "acwrite" })
  local first = M.views[bufnr] == nil

  local view = {
    bufnr = bufnr,
    columns = result.columns or {},
    rows = result.rows or {},
    affected_rows = result.affected_rows,
    elapsed_ms = result.elapsed_ms,
    truncated = result.truncated,
    kind = result.kind,
    notices = result.notices or {},
    sql = opts.sql,
    session_id = opts.session_id,
    session_name = opts.session_name,
    primary = {},
  }
  M.views[bufnr] = view

  local sizes = grid.widths(view.columns, view.rows)
  view.sizes = sizes
  view.spans = grid.spans(view.columns, sizes)

  local lines = { header_text(view) }
  local nulls = {}

  if #view.columns > 0 then
    local header, underline = grid.render_header(view.columns, sizes)
    table.insert(lines, header)
    table.insert(lines, underline)
    for index, row in ipairs(view.rows) do
      local line, row_nulls = grid.render_row(row, view.columns, sizes)
      table.insert(lines, line)
      nulls[index] = row_nulls
    end
  else
    table.insert(lines, "")
    table.insert(lines, "")
  end

  for _, notice in ipairs(view.notices) do
    table.insert(lines, "-- " .. notice)
  end

  vim.bo[bufnr].filetype = "dbclient-result"
  buffer.set_lines(bufnr, lines)
  vim.bo[bufnr].modifiable = false

  buffer.show(bufnr, ("botright %dsplit"):format(config.get().ui.result_height))
  vim.wo.cursorline = true
  vim.wo.wrap = false
  winbar.bind(bufnr, opts.session_id)

  highlights.grid(bufnr, {
    header_line = 1,
    first_row = HEADER_LINES,
    spans = view.spans,
    columns = view.columns,
    rows = #view.rows,
    nulls = nulls,
    stripes = config.get().ui.row_stripes,
  })
  highlights.lines(bufnr, { { line = 0, group = "DBClientHeader" } }, highlights.ns_virt)

  if first then
    M.attach(bufnr)
  end

  if #view.rows > 0 then
    pcall(vim.api.nvim_win_set_cursor, 0, { HEADER_LINES + 1, 0 })
  end
end

function M.current_cell()
  local view = M.view()
  if not view or #view.columns == 0 then
    return nil
  end
  local position = vim.api.nvim_win_get_cursor(0)
  local row_index = position[1] - HEADER_LINES
  if row_index < 1 or row_index > #view.rows then
    return nil
  end
  local line = vim.api.nvim_get_current_line()
  local column_index = grid.column_at(grid.line_spans(line, view.spans), position[2]) or 1
  return {
    view = view,
    row_index = row_index,
    column_index = column_index,
    column = view.columns[column_index],
    row = view.rows[row_index],
    value = view.rows[row_index][column_index],
  }
end

local function move(row_delta, column_delta)
  local cell = M.current_cell()
  if not cell then
    return
  end
  local row_index = math.max(1, math.min(cell.row_index + row_delta, #cell.view.rows))
  local column_index = math.max(1, math.min(cell.column_index + column_delta, #cell.view.columns))
  local line_number = HEADER_LINES + row_index
  local text = vim.api.nvim_buf_get_lines(0, line_number - 1, line_number, false)[1] or ""
  local span = grid.line_spans(text, cell.view.spans)[column_index]
  pcall(vim.api.nvim_win_set_cursor, 0, { line_number, span and span.start or 0 })
end

function M.inspect_value()
  local cell = M.current_cell()
  if not cell then
    return
  end
  value_inspector.open({
    value = cell.value,
    column = cell.column,
    session = cell.view.session_id,
    title = cell.column.name,
  })
end

function M.column_stats()
  local cell = M.current_cell()
  if not cell then
    return
  end
  vim.notify(
    "DBClient: column statistics need a table; open the table with gd first",
    vim.log.levels.WARN
  )
end

function M.transpose()
  local cell = M.current_cell()
  if not cell then
    return
  end

  local width = 0
  for _, column in ipairs(cell.view.columns) do
    width = math.max(width, grid.width(column.name))
  end

  local lines = {}
  for index, column in ipairs(cell.view.columns) do
    table.insert(
      lines,
      ("%s  %s"):format(grid.pad(column.name, width, "left"), (grid.display(cell.row[index], column)))
    )
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  local winid = window.float(bufnr, { title = "row " .. cell.row_index, max_width = 0.8 })
  window.close_keys(bufnr, winid)
end

function M.export_result()
  local view = M.view()
  if view then
    export.export(view)
  end
end

function M.yank()
  export.yank_menu(M.view(), M.current_cell(), HEADER_LINES)
end

function M.attach(bufnr)
  keymap.apply("result", bufnr, {
    inspect_value = M.inspect_value,
    column_stats = M.column_stats,
    transpose = M.transpose,
    yank = M.yank,
    export = M.export_result,
    chart = function()
      require("dbclient.chart").pick_and_show()
    end,
    snapshot = function()
      require("dbclient.snapshot").save_current()
    end,
    compare = function()
      require("dbclient.snapshot").diff_with_saved()
    end,
    pipe = function()
      vim.ui.input({ prompt = "pipe rows through " }, function(command)
        if command and command:match("%S") then
          require("dbclient.snapshot").pipe(command)
        end
      end)
    end,
    next_cell = function()
      move(0, 1)
    end,
    prev_cell = function()
      move(0, -1)
    end,
    next_row = function()
      move(1, 0)
    end,
    prev_row = function()
      move(-1, 0)
    end,
    close = function()
      buffer.hide(bufnr)
    end,
    help = help.handler("result"),
  })

  require("dbclient.textobj").attach(bufnr, function()
    return M.view(bufnr), HEADER_LINES
  end)

  -- `:w report.csv` exports; the extension picks the format.
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function(args)
      local view = M.view(bufnr)
      if not view then
        return
      end
      local target = args.match
      if target == "" or target:match("^dbclient://") then
        return export.export(view)
      end
      local ok, err = export.write_file(view, target)
      if ok then
        vim.notify(("DBClient: wrote %s"):format(target))
        vim.bo[bufnr].modified = false
      else
        vim.notify("DBClient: " .. tostring(err), vim.log.levels.ERROR)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      M.views[bufnr] = nil
    end,
  })
end

M.HEADER_LINES = HEADER_LINES

return M

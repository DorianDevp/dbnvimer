--- Grid text objects.
---
--- `yic`, `dar`, `viC` and friends. The point is that once the grid has text
--- objects, every operator the user already knows works on it: no new verbs,
--- no new muscle memory, and `.` repeats whatever they did.
---
--- Column objects are blockwise, which is what makes `yiC` on a 200-row page
--- give you the column and nothing else.

local grid = require("dbclient.ui.grid")

local M = {}

local CTRL_V = vim.api.nvim_replace_termcodes("<C-v>", true, false, true)

--- Select a charwise range. Columns are 0-based byte offsets, inclusive end.
local function select_chars(start_line, start_col, end_line, end_col)
  vim.api.nvim_win_set_cursor(0, { start_line, math.max(0, start_col) })
  vim.cmd("normal! v")
  vim.api.nvim_win_set_cursor(0, { end_line, math.max(0, end_col) })
end

local function select_lines(start_line, end_line)
  vim.api.nvim_win_set_cursor(0, { start_line, 0 })
  vim.cmd("normal! V")
  vim.api.nvim_win_set_cursor(0, { end_line, 0 })
end

local function select_block(start_line, start_col, end_line, end_col)
  vim.api.nvim_win_set_cursor(0, { start_line, math.max(0, start_col) })
  vim.cmd("normal! " .. CTRL_V)
  vim.api.nvim_win_set_cursor(0, { end_line, math.max(0, end_col) })
end

--- Byte spans for one buffer line.
---
--- `view.spans` is measured in display cells; every cursor position and every
--- selection boundary here is a byte offset. They only coincide while the row
--- is pure ASCII.
---@param line integer  1-based buffer line
---@param view table
---@return table[]
local function spans_for(line, view)
  local text = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1] or ""
  return grid.line_spans(text, view.spans)
end

--- Resolve the grid position under the cursor.
---@param view table
---@param header_lines integer
---@return { row: integer, column: integer, line: integer, spans: table[] }|nil
local function locate(view, header_lines)
  if not view or not view.spans then
    return nil
  end
  local position = vim.api.nvim_win_get_cursor(0)
  local row = position[1] - header_lines
  if row < 1 or row > #(view.rows or {}) then
    return nil
  end
  local spans = spans_for(position[1], view)
  local column = grid.column_at(spans, position[2])
  if not column then
    return nil
  end
  return { row = row, column = column, line = position[1], spans = spans }
end

--- Attach the text objects to a buffer.
---@param bufnr integer
---@param resolve fun(): table|nil, integer  returns the view and header height
function M.attach(bufnr, resolve)
  local objects = {
    ["ic"] = function()
      local view, header_lines = resolve()
      local at = locate(view, header_lines)
      if not at then
        return
      end
      local span = at.spans[at.column]
      select_chars(at.line, span.start, at.line, span.finish - 1)
    end,

    ["ac"] = function()
      local view, header_lines = resolve()
      local at = locate(view, header_lines)
      if not at then
        return
      end
      local span = at.spans[at.column]
      local line = vim.api.nvim_get_current_line()
      local finish = math.min(#line - 1, span.finish + #grid.SEPARATOR - 1)
      select_chars(at.line, span.start, at.line, finish)
    end,

    ["ir"] = function()
      local view, header_lines = resolve()
      local at = locate(view, header_lines)
      if not at then
        return
      end
      local line = vim.api.nvim_get_current_line()
      select_chars(at.line, 0, at.line, math.max(0, #line - 1))
    end,

    ["ar"] = function()
      local view, header_lines = resolve()
      local at = locate(view, header_lines)
      if not at then
        return
      end
      select_lines(at.line, at.line)
    end,

    ["iC"] = function()
      local view, header_lines = resolve()
      local at = locate(view, header_lines)
      if not at then
        return
      end
      -- A block spans rows whose byte offsets differ, so each end resolves
      -- against its own line.
      local first = spans_for(header_lines + 1, view)[at.column]
      local last = spans_for(header_lines + #view.rows, view)[at.column]
      select_block(
        header_lines + 1,
        first.start,
        header_lines + #view.rows,
        last.finish - 1
      )
    end,

    ["aC"] = function()
      local view, header_lines = resolve()
      local at = locate(view, header_lines)
      if not at then
        return
      end
      local first = spans_for(header_lines + 1, view)[at.column]
      local last = spans_for(header_lines + #view.rows, view)[at.column]
      select_block(
        header_lines + 1,
        first.start,
        header_lines + #view.rows,
        last.finish + #grid.SEPARATOR - 1
      )
    end,
  }

  for lhs, handler in pairs(objects) do
    for _, mode in ipairs({ "o", "x" }) do
      vim.keymap.set(mode, lhs, handler, {
        buffer = bufnr,
        silent = true,
        desc = "DBClient: grid text object " .. lhs,
      })
    end
  end

  -- Cell-wise word motions: `w` and `b` step between cells rather than words,
  -- which is what "next thing" means in a grid.
  vim.keymap.set("n", "w", function()
    local view, header_lines = resolve()
    local at = locate(view, header_lines)
    if not at then
      return vim.cmd("normal! w")
    end
    local span = at.spans[at.column + 1]
    if span then
      vim.api.nvim_win_set_cursor(0, { at.line, span.start })
    elseif at.row < #view.rows then
      local first = grid.column_start(spans_for(at.line + 1, view), 1)
      vim.api.nvim_win_set_cursor(0, { at.line + 1, first })
    end
  end, { buffer = bufnr, silent = true, desc = "DBClient: next cell" })

  vim.keymap.set("n", "b", function()
    local view, header_lines = resolve()
    local at = locate(view, header_lines)
    if not at then
      return vim.cmd("normal! b")
    end
    local span = at.spans[at.column - 1]
    if span then
      vim.api.nvim_win_set_cursor(0, { at.line, span.start })
    elseif at.row > 1 then
      local last = 0
      for _, candidate in pairs(spans_for(at.line - 1, view)) do
        last = math.max(last, candidate.start)
      end
      vim.api.nvim_win_set_cursor(0, { at.line - 1, last })
    end
  end, { buffer = bufnr, silent = true, desc = "DBClient: previous cell" })
end

return M

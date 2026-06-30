local results = require("dbclient.ui.results")
local buffer = require("dbclient.ui.buffer")
local state = require("dbclient.state")
local window = require("dbclient.ui.window")

local M = {
  buf = nil,
}

local function visual_selection()
  local mode = vim.fn.mode()
  if not mode:match("[vV\022]") then
    return nil
  end

  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  if start_pos[2] == 0 or end_pos[2] == 0 then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)
  if #lines == 0 then
    return nil
  end

  lines[#lines] = lines[#lines]:sub(1, end_pos[3])
  lines[1] = lines[1]:sub(start_pos[3])
  return table.concat(lines, "\n")
end

local function statement_at_cursor()
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local first = cursor
  local last = cursor

  while first > 1 and not lines[first - 1]:match("%S*;%s*$") do
    first = first - 1
  end

  while last < #lines and not lines[last]:match(";%s*$") do
    last = last + 1
  end

  return table.concat(vim.list_slice(lines, first, last), "\n")
end

function M.sql_under_cursor()
  local selected = visual_selection()
  if selected and selected:match("%S") then
    return selected
  end
  return statement_at_cursor()
end

function M.execute()
  local sql = M.sql_under_cursor()
  if not sql or not sql:match("%S") then
    vim.notify("DBClient: no SQL to execute", vim.log.levels.WARN)
    return
  end

  local ok, result = pcall(state.query, sql)
  if not ok then
    vim.notify("DBClient query failed: " .. result, vim.log.levels.ERROR)
    return
  end

  results.show(result)
end

function M.open()
  state.ensure_connected()
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) and window.focus(M.buf) then
    return
  end

  M.buf = buffer.open_or_create("DBClient Query - " .. state.active_name, "enew")
  local buf = M.buf
  vim.bo[buf].filetype = "sql"
  vim.bo[buf].bufhidden = "hide"
  M.buf = buffer.set_name(buf, "DBClient Query - " .. state.active_name)
  buf = M.buf
  if vim.api.nvim_buf_line_count(buf) == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "select 1;" })
  end
  vim.keymap.set({ "n", "v" }, "<leader>dq", M.execute, { buffer = buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-CR>", M.execute, { buffer = buf, silent = true })
  vim.keymap.set("n", "F", window.toggle_fullscreen, { buffer = buf, silent = true })
end

function M.open_with(sql)
  M.open()
  if sql and sql ~= "" then
    vim.api.nvim_buf_set_lines(M.buf, -1, -1, false, { "", sql })
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(M.buf), 0 })
  end
end

return M

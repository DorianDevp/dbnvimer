local state = require("dbclient.state")
local window = require("dbclient.ui.window")

local M = {
  buf = nil,
}

local function open_lines(name, lines)
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    vim.cmd("vsplit")
    M.buf = vim.api.nvim_get_current_buf()
  elseif not window.focus(M.buf) then
    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(0, M.buf)
  end

  vim.bo[M.buf].buftype = "nofile"
  vim.bo[M.buf].bufhidden = "hide"
  vim.bo[M.buf].swapfile = false
  vim.bo[M.buf].filetype = "dbclient-inspect"
  vim.api.nvim_buf_set_name(M.buf, "DBClient Inspect - " .. name)
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = M.buf, silent = true })
  vim.keymap.set("n", "F", window.toggle_fullscreen, { buffer = M.buf, silent = true })
end

function M.table(schema, table_name)
  local lines = { schema .. "." .. table_name, "", "columns" }
  for _, column in ipairs(state.columns(schema, table_name, false)) do
    local key = column.key ~= "" and (" " .. column.key) or ""
    local nullable = column.nullable and " nullable" or " not-null"
    table.insert(lines, "  " .. column.name .. "  " .. column.type .. nullable .. key)
  end
  open_lines(schema .. "." .. table_name, lines)
end

function M.schema(schema)
  local lines = { schema, "", "tables" }
  for _, table_info in ipairs(state.tables(schema, false)) do
    table.insert(lines, "  " .. table_info.name .. "  " .. table_info.kind)
  end
  table.insert(lines, "")
  table.insert(lines, "routines")
  for _, routine in ipairs(state.routines(schema, false)) do
    table.insert(lines, "  " .. routine.kind .. " " .. routine.name)
  end
  open_lines(schema, lines)
end

return M

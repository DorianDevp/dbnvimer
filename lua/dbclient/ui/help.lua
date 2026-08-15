--- The `g?` popup.
---
--- Rendered straight from `dbclient.keymap`, so it can never disagree with the
--- mappings that are actually registered.

local highlights = require("dbclient.ui.highlights")
local keymap = require("dbclient.keymap")
local window = require("dbclient.ui.window")

local M = {}

--- Show the help for one mapping group.
---@param group string
function M.show(group)
  local lines, marks = keymap.help_lines(group)

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "dbclient-help"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  local winid = window.float(bufnr, {
    title = "DBClient help",
    max_width = 0.8,
    max_height = 0.8,
    cursorline = false,
  })

  highlights.lines(bufnr, marks)
  window.close_keys(bufnr, winid)
  vim.keymap.set("n", "g?", function()
    window.close(winid, bufnr)
  end, { buffer = bufnr, silent = true, nowait = true })
end

--- A closure suitable for a keymap handler table.
---@param group string
---@return fun()
function M.handler(group)
  return function()
    M.show(group)
  end
end

--- Every group at once, in a scratch buffer rather than a float.
function M.show_all()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "dbclient-help"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, keymap.documentation())
  vim.bo[bufnr].modifiable = false

  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.keymap.set("n", "q", "<cmd>tabclose<cr>", { buffer = bufnr, silent = true, nowait = true })
end

return M

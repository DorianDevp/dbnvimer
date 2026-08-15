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
    hints = { { "q", "close" }, { ":DBClientHelp", "everything" } },
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

--- The generated palette, with the contrast each role achieved.
---
--- Worth having in the UI rather than only in the tests: when someone reports
--- that a colour is hard to read, this says whether the palette is wrong or the
--- terminal is lying about its background.
function M.show_palette()
  local theme = require("dbclient.ui.theme")
  local lines, marks = theme.describe()

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "dbclient-palette"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  local winid = window.float(bufnr, {
    title = "palette",
    max_height = 0.85,
    cursorline = false,
    hints = { { "q", "close" } },
  })

  highlights.lines(bufnr, marks)
  window.close_keys(bufnr, winid)
end

return M

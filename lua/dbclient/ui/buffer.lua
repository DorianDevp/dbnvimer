--- Named scratch buffer helpers.
---
--- DBClient buffers are identified by name so reopening one focuses the
--- existing buffer instead of hitting `E95: Buffer with this name already
--- exists`.

local M = {}

--- Find a buffer by exact name or tail.
---@param name string
---@return integer|nil
function M.find(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local buf_name = vim.api.nvim_buf_get_name(buf)
      if buf_name == name or vim.fn.fnamemodify(buf_name, ":t") == name then
        return buf
      end
    end
  end
end

--- Create a scratch buffer with a unique name.
---@param name string
---@param opts? { filetype?: string, modifiable?: boolean, buftype?: string, bufhidden?: string }
---@return integer bufnr
function M.scratch(name, opts)
  opts = opts or {}

  local existing = M.find(name)
  if existing and vim.api.nvim_buf_is_valid(existing) then
    return existing
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, bufnr, name)
  vim.bo[bufnr].buftype = opts.buftype or "nofile"
  vim.bo[bufnr].bufhidden = opts.bufhidden or "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = opts.modifiable ~= false
  if opts.filetype then
    vim.bo[bufnr].filetype = opts.filetype
  end
  return bufnr
end

--- Replace a buffer's contents, temporarily lifting `modifiable`.
---@param bufnr integer
---@param lines string[]
function M.set_lines(bufnr, lines)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local was_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = was_modifiable
  vim.bo[bufnr].modified = false
end

--- Show a buffer, reusing its window when one is already open.
---@param bufnr integer
---@param command string  window command, e.g. `botright 14split`
---@return integer winid
function M.show(bufnr, command)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      vim.api.nvim_set_current_win(win)
      return win
    end
  end

  vim.cmd(command)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, bufnr)
  return win
end

--- Focus an existing window showing `bufnr`.
---@param bufnr integer|nil
---@return boolean focused
function M.focus(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      vim.api.nvim_set_current_win(win)
      return true
    end
  end
  return false
end

--- Close every window showing `bufnr`, keeping the buffer alive.
---@param bufnr integer
function M.hide(bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr and #vim.api.nvim_list_wins() > 1 then
      pcall(vim.api.nvim_win_close, win, false)
    end
  end
end

return M

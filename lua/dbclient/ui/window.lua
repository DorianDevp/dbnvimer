--- Floating window and layout helpers.

local M = {
  restore = nil,
}

--- Zoom the current window, or restore the previous layout.
function M.toggle_fullscreen()
  if M.restore then
    vim.cmd(M.restore)
    M.restore = nil
    return
  end
  M.restore = vim.fn.winrestcmd()
  vim.cmd("wincmd |")
  vim.cmd("wincmd _")
end

--- Open a centred floating window sized to its content.
---@param bufnr integer
---@param opts { title?: string, width?: integer, height?: integer, max_width?: number, max_height?: number, border?: string }
---@return integer winid
function M.float(bufnr, opts)
  opts = opts or {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local width = opts.width
  if not width then
    width = 0
    for _, line in ipairs(lines) do
      width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    width = width + 2
  end
  width = math.min(width, math.floor(vim.o.columns * (opts.max_width or 0.9)))
  width = math.max(width, 20)

  local height = opts.height or #lines
  height = math.min(height, math.floor(vim.o.lines * (opts.max_height or 0.8)))
  height = math.max(height, 1)

  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = opts.border or "rounded",
    title = opts.title and (" " .. opts.title .. " ") or nil,
    title_pos = opts.title and "left" or nil,
  })

  vim.wo[win].wrap = opts.wrap or false
  vim.wo[win].cursorline = opts.cursorline ~= false
  return win
end

--- Open a floating window anchored under the cursor.
---@param bufnr integer
---@param opts { title?: string, width?: integer, height?: integer }
---@return integer winid
function M.float_at_cursor(bufnr, opts)
  opts = opts or {}
  local width = opts.width or 40
  local height = opts.height or 1
  return vim.api.nvim_open_win(bufnr, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.min(width, vim.o.columns - 4),
    height = math.min(height, vim.o.lines - 4),
    style = "minimal",
    border = "rounded",
    title = opts.title and (" " .. opts.title .. " ") or nil,
    title_pos = opts.title and "left" or nil,
  })
end

--- Close a window and wipe its buffer.
---@param winid integer|nil
---@param bufnr integer|nil
function M.close(winid, bufnr)
  if winid and vim.api.nvim_win_is_valid(winid) then
    pcall(vim.api.nvim_win_close, winid, true)
  end
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

--- Map `q` and `<Esc>` to close a transient float.
---@param bufnr integer
---@param winid integer
---@param on_close? fun()
function M.close_keys(bufnr, winid, on_close)
  local function close()
    if on_close then
      pcall(on_close)
    end
    M.close(winid, bufnr)
  end
  vim.keymap.set("n", "q", close, { buffer = bufnr, silent = true, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = bufnr, silent = true, nowait = true })
end

return M

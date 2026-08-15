--- Floating window and layout helpers.
---
--- The design decisions live here rather than at each call site, so every panel
--- in the plugin gets the same treatment:
---
---   * the palette's raised surface, not the colourscheme's `NormalFloat`,
---     so a float reads as lifted off the page by a measured amount;
---   * a border in the rule colour, which is deliberately near-invisible — the
---     box is there to separate, not to decorate;
---   * one column of breathing room on each side, because content pressed
---     against a border is the single most common reason a TUI looks cramped;
---   * key hints in the footer rather than as a line of body text, which keeps
---     the content area for content.

local M = {
  restore = nil,
}

--- Applied to every float so the panels share one surface.
local WINHIGHLIGHT = table.concat({
  "Normal:DBClientFloat",
  "NormalFloat:DBClientFloat",
  "FloatBorder:DBClientBorder",
  "FloatTitle:DBClientFloatTitle",
  "FloatFooter:DBClientHelpText",
  "CursorLine:DBClientStripe",
}, ",")

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

--- Render `{ key, label }` pairs as a footer strip.
---@param hints table[]|nil
---@return table|nil
local function footer(hints)
  if not hints or #hints == 0 then
    return nil
  end
  local chunks = { { " " } }
  for index, hint in ipairs(hints) do
    if index > 1 then
      table.insert(chunks, { "   ", "DBClientHelpText" })
    end
    table.insert(chunks, { hint[1], "DBClientHelpKey" })
    table.insert(chunks, { " " .. hint[2], "DBClientHelpText" })
  end
  table.insert(chunks, { " " })
  return chunks
end

--- Width a footer needs, so a float is never narrower than its own hints.
---@param hints table[]|nil
---@return integer
local function footer_width(hints)
  if not hints or #hints == 0 then
    return 0
  end
  local width = 2
  for index, hint in ipairs(hints) do
    if index > 1 then
      width = width + 3
    end
    width = width + vim.fn.strdisplaywidth(hint[1]) + 1 + vim.fn.strdisplaywidth(hint[2])
  end
  return width + 2
end

--- Apply the shared styling to an already-open floating window.
---@param win integer
---@param opts table|nil
function M.style(win, opts)
  opts = opts or {}
  vim.wo[win].winhighlight = WINHIGHLIGHT
  if opts.pad ~= false then
    -- `style = "minimal"` clears these, so they have to be set afterwards.
    -- The sign column is the cheapest column of left padding there is.
    vim.wo[win].signcolumn = "yes:1"
  end
end

--- Open a centred floating window sized to its content.
---@param bufnr integer
---@param opts { title?: string, width?: integer, height?: integer, max_width?: number, max_height?: number, border?: string, hints?: table[], pad?: boolean }
---@return integer winid
function M.float(bufnr, opts)
  opts = opts or {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local padded = opts.pad ~= false

  local width = opts.width
  if not width then
    width = 0
    for _, line in ipairs(lines) do
      width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    -- One column of air on each side, plus the sign column that supplies the
    -- left one.
    width = width + 2
  end
  width = math.max(width, footer_width(opts.hints))
  if padded then
    width = width + 2
  end
  width = math.min(width, math.floor(vim.o.columns * (opts.max_width or 0.9)))
  width = math.max(width, 20)

  local height = opts.height or #lines
  height = math.min(height, math.floor(vim.o.lines * (opts.max_height or 0.8)))
  height = math.max(height, 1)

  local hints = footer(opts.hints)
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
    footer = hints,
    footer_pos = hints and "right" or nil,
  })

  vim.wo[win].wrap = opts.wrap or false
  vim.wo[win].cursorline = opts.cursorline ~= false
  M.style(win, opts)
  return win
end

--- Open a floating window anchored under the cursor.
---@param bufnr integer
---@param opts { title?: string, width?: integer, height?: integer, hints?: table[] }
---@return integer winid
function M.float_at_cursor(bufnr, opts)
  opts = opts or {}
  local width = opts.width or 40
  local height = opts.height or 1
  local hints = footer(opts.hints)
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.min(width, vim.o.columns - 4),
    height = math.min(height, vim.o.lines - 4),
    style = "minimal",
    border = "rounded",
    title = opts.title and (" " .. opts.title .. " ") or nil,
    title_pos = opts.title and "left" or nil,
    footer = hints,
    footer_pos = hints and "right" or nil,
  })
  M.style(win, { pad = opts.pad })
  return win
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

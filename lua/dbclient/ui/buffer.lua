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

--- Windows showing `bufnr`, preferring the current tab page.
---
--- Searching every tab would teleport the user out of the tab they are working
--- in, which is exactly the wrong thing when the quick-query tab has its own
--- result window.
---@param bufnr integer
---@return integer[]
function M.windows(bufnr)
  local here, elsewhere = {}, {}
  local current_tab = vim.api.nvim_get_current_tabpage()

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      if vim.api.nvim_win_get_tabpage(win) == current_tab then
        table.insert(here, win)
      else
        table.insert(elsewhere, win)
      end
    end
  end

  return #here > 0 and here or elsewhere
end

--- Show a buffer, reusing its window when one is already open.
---@param bufnr integer
---@param command string  window command, e.g. `botright 14split`
---@return integer winid
--- Panels that report on something else, and so must not be taken over.
---
--- A result set sits under the query that produced it and an error under the
--- statement that caused it. Opening a table into one of those would replace
--- the thing you are reading with the thing you asked about.
local PANELS = {
  ["dbclient"] = true, -- the sidebar
  ["dbclient-result"] = true,
  ["dbclient-error"] = true,
  ["dbclient-diagnosis"] = true,
  ["dbclient-help"] = true,
  ["dbclient-palette"] = true,
  ["dbclient-transpose"] = true,
  ["dbclient-stats"] = true,
  ["dbclient-chart"] = true,
  ["dbclient-blast"] = true,
  ["dbclient-changes"] = true,
}

--- Whether a window is somewhere content can be put.
---@param win integer
---@return boolean
local function is_content_window(win)
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return false
  end
  local bufnr = vim.api.nvim_win_get_buf(win)
  if PANELS[vim.bo[bufnr].filetype] then
    return false
  end
  return vim.bo[bufnr].buftype == "" or vim.bo[bufnr].buftype == "nofile"
end

--- Where content the user asked to look at should go.
---
--- Splitting instead is what made this unusable: with a file open and the
--- sidebar out, a table arrived as a full-width strip along the bottom and
--- halved everything else — and a second table halved it again, leaving two
--- nine-line grids. A data buffer is the thing you came to read, so it gets
--- the main area, and the next one replaces it rather than stacking.
---
--- The buffer that was there is not lost: it stays in the buffer list, and
--- `<C-o>` or `:b#` brings it straight back.
---@return integer|nil
local function primary_window()
  local windows = vim.api.nvim_list_wins()

  -- A window already showing content of this kind is the obvious home, so
  -- opening one table after another reuses one window instead of tiling.
  for _, win in ipairs(windows) do
    local filetype = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
    if filetype == "dbclient-data" or filetype == "dbclient-record" then
      return win
    end
  end

  local current = vim.api.nvim_get_current_win()
  if is_content_window(current) then
    return current
  end

  local best, best_area
  for _, win in ipairs(windows) do
    if is_content_window(win) then
      local area = vim.api.nvim_win_get_width(win) * vim.api.nvim_win_get_height(win)
      if not best or area > best_area then
        best, best_area = win, area
      end
    end
  end
  return best
end

--- Put a buffer on screen.
---
--- `opts.primary` marks content the user asked to look at — a table, a record.
--- It lands in the main area. Everything else keeps whatever split its caller
--- asked for, because a panel that belongs under something has to stay there.
---@param bufnr integer
---@param command string
---@param opts? { primary?: boolean }
---@return integer winid
function M.show(bufnr, command, opts)
  local existing = M.windows(bufnr)[1]
  if existing then
    vim.api.nvim_set_current_win(existing)
    return existing
  end

  if opts and opts.primary then
    local target = primary_window()
    if target then
      vim.api.nvim_set_current_win(target)
      vim.api.nvim_win_set_buf(target, bufnr)
      return target
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
  local existing = M.windows(bufnr)[1]
  if existing then
    vim.api.nvim_set_current_win(existing)
    return true
  end
  return false
end

--- Close every window showing `bufnr`, keeping the buffer alive.
---@param bufnr integer
function M.hide(bufnr)
  for _, win in ipairs(M.windows(bufnr)) do
    if #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win)) > 1 then
      pcall(vim.api.nvim_win_close, win, false)
    end
  end
end

return M

local M = {}

function M.find(name)
  local bufnr = vim.fn.bufnr(name)
  if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local buf_name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_valid(buf) and (buf_name == name or vim.fn.fnamemodify(buf_name, ":t") == name) then
      return buf
    end
  end
end

function M.set_name(buf, name)
  local existing = M.find(name)
  if existing == buf then
    return buf
  elseif existing then
    vim.api.nvim_win_set_buf(0, existing)
    return existing
  end

  local ok, err = pcall(vim.api.nvim_buf_set_name, buf, name)
  if not ok then
    local recovered = M.find(name)
    if recovered then
      vim.api.nvim_win_set_buf(0, recovered)
      return recovered
    end
    error(err)
  end

  return buf
end

function M.open_named(name, command)
  local existing = M.find(name)
  vim.cmd(command)
  local win = vim.api.nvim_get_current_win()
  local buf = existing or vim.api.nvim_get_current_buf()

  if existing then
    vim.api.nvim_win_set_buf(win, existing)
  end

  return buf, win
end

function M.open_or_create(name, command)
  local existing = M.find(name)
  if existing then
    vim.cmd(command)
    local win = vim.api.nvim_get_current_win()
    local created = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_buf(win, existing)
    if created ~= existing and vim.api.nvim_buf_get_name(created) == "" then
      pcall(vim.api.nvim_buf_delete, created, { force = true })
    end
    return existing, win, true
  end

  vim.cmd(command)
  return vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(), false
end

return M

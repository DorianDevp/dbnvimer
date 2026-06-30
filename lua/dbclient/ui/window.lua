local M = {
  restore = nil,
}

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

function M.focus(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == buf then
        vim.api.nvim_set_current_win(win)
        return true
      end
    end
  end
  return false
end

return M

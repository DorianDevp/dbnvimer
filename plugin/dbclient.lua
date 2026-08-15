-- Lazily define `:DBClient` so the plugin costs nothing until it is used.
-- `setup()` replaces this with the full command set.

if vim.g.loaded_dbclient then
  return
end
vim.g.loaded_dbclient = true

vim.api.nvim_create_user_command("DBClient", function()
  require("dbclient").setup(vim.g.dbclient or {})
  require("dbclient").open()
end, { desc = "Open the DBClient sidebar", force = true })

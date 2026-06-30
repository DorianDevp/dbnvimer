local config = require("dbclient.config")
local query = require("dbclient.ui.query")
local sidebar = require("dbclient.ui.sidebar")
local state = require("dbclient.state")

local M = {}

function M.setup(opts)
  config.setup(opts)

  vim.api.nvim_create_user_command("DBClient", M.open, {})
  vim.api.nvim_create_user_command("DBClientQuery", query.execute, { range = true })
  vim.api.nvim_create_user_command("DBClientClose", M.close, {})
  vim.api.nvim_create_user_command("DBClientConnect", function(args)
    M.connect(args.args)
  end, {
    nargs = 1,
    complete = function()
      return state.connection_names()
    end,
  })

  vim.keymap.set("n", "<leader>dc", M.pick_connection, { silent = true })
end

function M.open()
  sidebar.open()
end

function M.connect(name)
  local ok, err = pcall(state.connect, name)
  if not ok then
    vim.notify("DBClient connect failed: " .. err, vim.log.levels.ERROR)
    return
  end
  sidebar.render()
end

function M.pick_connection()
  local names = state.connection_names()
  if #names == 0 then
    vim.notify("DBClient: no connections configured", vim.log.levels.WARN)
    return
  end

  vim.ui.select(names, { prompt = "DBClient connection" }, function(choice)
    if choice then
      M.connect(choice)
    end
  end)
end

function M.close()
  state.close()
  sidebar.render()
end

function M.query()
  query.execute()
end

return M

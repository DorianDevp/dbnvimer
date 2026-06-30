local M = {}

local defaults = {
  core = {
    command = "dbclient-core",
  },
  ui = {
    sidebar_width = 38,
    result_height = 14,
    max_cell_width = 48,
  },
  connections = {},
}

M.values = vim.deepcopy(defaults)

function M.setup(opts)
  M.values = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  return M.values
end

function M.get()
  return M.values
end

return M

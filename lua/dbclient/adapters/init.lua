local M = {}

local loaded = {}

function M.get(name)
  if not loaded[name] then
    loaded[name] = require("dbclient.adapters." .. name)
  end
  return loaded[name]
end

return M

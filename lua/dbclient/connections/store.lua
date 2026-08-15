--- Persistence for connections created from inside the client.
---
--- Secrets are never written here. A stored connection may reference a
--- password by environment variable or by shell command, or ask to be
--- prompted; the value itself only ever lives in memory.

local config = require("dbclient.config")

local M = {}

local SECRET_KEYS = { "password" }

local function path()
  return config.get().store.path
end

local function ensure_dir()
  local dir = vim.fs.dirname(path())
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

--- Read every stored connection.
---@return table<string, table>
function M.read()
  local file = path()
  if vim.fn.filereadable(file) ~= 1 then
    return {}
  end

  local content = table.concat(vim.fn.readfile(file), "\n")
  if content:match("^%s*$") then
    return {}
  end

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    vim.notify(
      "DBClient: could not parse " .. file .. "; ignoring stored connections",
      vim.log.levels.WARN
    )
    return {}
  end
  return decoded.connections or {}
end

--- Replace the whole store.
---@param connections table<string, table>
---@return boolean ok, string|nil err
function M.write(connections)
  if not config.get().store.enabled then
    return false, "the connection store is disabled"
  end

  ensure_dir()
  local sanitised = {}
  for name, spec in pairs(connections) do
    local copy = vim.deepcopy(spec)
    for _, key in ipairs(SECRET_KEYS) do
      copy[key] = nil
    end
    sanitised[name] = copy
  end

  local encoded = vim.json.encode({ version = 1, connections = sanitised })
  local ok, err = pcall(vim.fn.writefile, vim.split(encoded, "\n"), path())
  if not ok then
    return false, tostring(err)
  end

  -- The file can still name secrets indirectly, so keep it owner-only.
  pcall(vim.uv.fs_chmod, path(), 384) -- 0600
  return true
end

---@param name string
---@param spec table
function M.save(name, spec)
  local connections = M.read()
  connections[name] = spec
  return M.write(connections)
end

---@param name string
function M.delete(name)
  local connections = M.read()
  if not connections[name] then
    return false, "no stored connection named " .. name
  end
  connections[name] = nil
  return M.write(connections)
end

---@param from string
---@param to string
function M.rename(from, to)
  local connections = M.read()
  if not connections[from] then
    return false, "no stored connection named " .. from
  end
  connections[to] = connections[from]
  connections[from] = nil
  return M.write(connections)
end

function M.path()
  return path()
end

return M

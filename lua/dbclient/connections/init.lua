--- The connection registry: merges every source into one addressable list.
---
--- Sources, in precedence order:
---   1. `setup()`  — read-only, owned by the user's config
---   2. store      — editable from inside the client
---   3. detected   — read-only suggestions found in the project
---
--- Secrets are resolved at connect time and cached in memory only.

local config = require("dbclient.config")
local detect = require("dbclient.connections.detect")
local store = require("dbclient.connections.store")

local M = {
  --- name -> resolved password, kept out of every file on disk.
  secrets = {},
  --- Cached project scan, refreshed by `M.rescan()`.
  detected = nil,
}

local ADAPTERS = { "mariadb", "postgres", "sqlite" }
local DEFAULT_PORTS = { mariadb = 3306, postgres = 5432 }

--- Normalise aliases and fill in defaults.
---@param spec table
---@return table
function M.normalise(spec)
  local copy = vim.deepcopy(spec or {})
  local adapter = tostring(copy.adapter or "mariadb"):lower()
  copy.adapter = ({
    mysql = "mariadb",
    mariadb = "mariadb",
    postgres = "postgres",
    postgresql = "postgres",
    pg = "postgres",
    sqlite = "sqlite",
    sqlite3 = "sqlite",
  })[adapter] or adapter

  if copy.adapter ~= "sqlite" then
    copy.host = copy.host or "127.0.0.1"
    copy.port = tonumber(copy.port) or DEFAULT_PORTS[copy.adapter]
  end
  copy.access = copy.access or "write"
  return copy
end

--- Every known connection, keyed by name.
---@return table<string, table>
function M.all()
  local merged = {}

  if config.get().detect.enabled then
    for name, spec in pairs(M.detected or {}) do
      merged[name] = vim.tbl_extend("force", M.normalise(spec), { source = "project" })
    end
  end

  if config.get().store.enabled then
    for name, spec in pairs(store.read()) do
      merged[name] = vim.tbl_extend("force", M.normalise(spec), { source = "store" })
    end
  end

  for name, spec in pairs(config.get().connections or {}) do
    merged[name] = vim.tbl_extend("force", M.normalise(spec), { source = "setup" })
  end

  return merged
end

--- Sorted connection names.
---@return string[]
function M.names()
  local names = vim.tbl_keys(M.all())
  table.sort(names)
  return names
end

---@param name string
---@return table|nil
function M.get(name)
  return M.all()[name]
end

--- Re-run project detection. Cheap enough to call on `DirChanged`.
function M.rescan()
  if not config.get().detect.enabled then
    M.detected = {}
    return M.detected
  end
  local settings = config.get().detect
  M.detected = detect.scan({ sources = settings.sources, depth = settings.depth })
  return M.detected
end

--- Resolve the password for `name`, prompting only when asked to.
---
--- Order: cached -> literal -> environment variable -> shell command -> prompt.
---@param name string
---@param spec table
---@param callback fun(password: string|nil)
function M.resolve_password(name, spec, callback)
  if M.secrets[name] ~= nil then
    return callback(M.secrets[name])
  end
  if spec.password and spec.password ~= "" then
    return callback(spec.password)
  end
  if spec.password_env then
    local value = vim.env[spec.password_env]
    if value and value ~= "" then
      M.secrets[name] = value
      return callback(value)
    end
  end
  if spec.password_cmd then
    local result = vim.system({ "sh", "-c", spec.password_cmd }, { text = true }):wait()
    if result.code == 0 then
      local value = vim.split(result.stdout or "", "\n")[1] or ""
      value = value:gsub("%s+$", "")
      if value ~= "" then
        M.secrets[name] = value
        return callback(value)
      end
    else
      vim.notify(
        ("DBClient: password_cmd for %s failed: %s"):format(name, result.stderr or ""),
        vim.log.levels.WARN
      )
    end
  end
  if spec.password_prompt then
    return vim.ui.input({ prompt = ("password for %s: "):format(name), default = "" }, function(value)
      if value and value ~= "" then
        M.secrets[name] = value
      end
      callback(value)
    end)
  end
  callback(nil)
end

--- Forget a cached password, so the next connect asks again.
---@param name string|nil
function M.forget_secret(name)
  if name then
    M.secrets[name] = nil
  else
    M.secrets = {}
  end
end

--- Build the wire payload the core expects.
---@param name string
---@param spec table
---@param password string|nil
---@return table connection, table|nil ssh
function M.to_wire(name, spec, password)
  local connection = {
    adapter = spec.adapter,
    host = spec.host,
    port = spec.port,
    user = spec.user,
    password = password,
    database = spec.database,
    path = spec.path and vim.fn.expand(spec.path) or nil,
    access = spec.access or "write",
    options = spec.options or vim.empty_dict(),
    statement_timeout_ms = spec.statement_timeout_ms
      or config.get().core.statement_timeout_ms,
  }

  local ssh = nil
  if spec.ssh then
    ssh = vim.deepcopy(spec.ssh)
    ssh.remote_host = ssh.remote_host or spec.host or "127.0.0.1"
    ssh.remote_port = ssh.remote_port or spec.port or DEFAULT_PORTS[spec.adapter] or 0
  end

  return connection, ssh
end

--- Validate a spec before saving or connecting.
---@param spec table
---@return boolean ok, string|nil err
function M.validate(spec)
  if not spec.adapter or not vim.tbl_contains(ADAPTERS, spec.adapter) then
    return false, "adapter must be one of: " .. table.concat(ADAPTERS, ", ")
  end
  if spec.adapter == "sqlite" then
    if not spec.path or spec.path == "" then
      return false, "sqlite connections need a `path`"
    end
    return true
  end
  if not spec.host or spec.host == "" then
    return false, "host is required"
  end
  if not spec.user or spec.user == "" then
    return false, "user is required"
  end
  if spec.port and (tonumber(spec.port) == nil or tonumber(spec.port) <= 0) then
    return false, "port must be a positive number"
  end
  if spec.access and not vim.tbl_contains({ "write", "read", "sandbox" }, spec.access) then
    return false, "access must be write, read or sandbox"
  end
  return true
end

--- Persist a connection to the store.
---@param name string
---@param spec table
---@return boolean ok, string|nil err
function M.save(name, spec)
  if name == nil or name == "" then
    return false, "connection name is required"
  end

  local existing = M.get(name)
  if existing and existing.source == "setup" then
    return false, ("`%s` comes from setup(); edit it in your Neovim config"):format(name)
  end

  local normalised = M.normalise(spec)
  local ok, err = M.validate(normalised)
  if not ok then
    return false, err
  end

  normalised.source = nil
  normalised.detected = nil
  return store.save(name, normalised)
end

---@param name string
function M.delete(name)
  local existing = M.get(name)
  if not existing then
    return false, "unknown connection " .. name
  end
  if existing.source == "setup" then
    return false, ("`%s` comes from setup(); remove it from your config"):format(name)
  end
  if existing.source == "project" then
    return false, ("`%s` was detected in the project and is not stored"):format(name)
  end
  M.forget_secret(name)
  return store.delete(name)
end

--- Copy a detected or setup connection into the editable store.
---@param name string
---@param new_name string|nil
function M.adopt(name, new_name)
  local spec = M.get(name)
  if not spec then
    return false, "unknown connection " .. name
  end
  local target = new_name or name:gsub("^[%w]+:", "")
  local copy = vim.deepcopy(spec)
  copy.source = nil
  copy.detected = nil
  copy.origin = nil
  return M.save(target, copy)
end

--- Human readable one-line summary, used by pickers and the manager UI.
---@param name string
---@param spec table
---@return string
function M.describe(name, spec)
  spec = spec or M.get(name) or {}
  if spec.adapter == "sqlite" then
    return ("sqlite  %s"):format(spec.path or "?")
  end
  local target = ("%s@%s:%s"):format(spec.user or "?", spec.host or "?", spec.port or "?")
  local database = spec.database and ("/" .. spec.database) or ""
  local via = spec.ssh and ("  ssh:" .. (spec.ssh.host or "?")) or ""
  return ("%-8s %s%s%s"):format(spec.adapter or "?", target, database, via)
end

return M

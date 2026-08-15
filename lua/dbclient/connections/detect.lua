--- Zero-config project detection.
---
--- Opening a project and having its database already listed removes the single
--- biggest piece of setup friction. Detected connections are read-only
--- suggestions: they never overwrite anything from `setup()` or the store, and
--- they are prefixed so their origin is obvious in the sidebar.

local M = {}

local ADAPTER_ALIASES = {
  postgres = "postgres",
  postgresql = "postgres",
  pgsql = "postgres",
  pg = "postgres",
  mysql = "mariadb",
  mariadb = "mariadb",
  mysql2 = "mariadb",
  sqlite = "sqlite",
  sqlite3 = "sqlite",
}

local DEFAULT_PORTS = { postgres = 5432, mariadb = 3306 }

--- Parse a `scheme://user:password@host:port/database` URL.
---@param url string
---@return table|nil
function M.parse_url(url)
  if type(url) ~= "string" then
    return nil
  end

  local scheme, rest = url:match("^(%a[%w+.-]*)://(.*)$")
  if not scheme then
    return nil
  end

  local adapter = ADAPTER_ALIASES[scheme:lower():gsub("%+.*$", "")]
  if not adapter then
    return nil
  end

  if adapter == "sqlite" then
    local file = rest:gsub("^/+", "/")
    return { adapter = "sqlite", path = file }
  end

  local credentials, location = rest:match("^(.-)@(.*)$")
  if not credentials then
    credentials, location = "", rest
  end

  local user, password = credentials:match("^(.-):(.*)$")
  if not user then
    user, password = credentials, nil
  end

  local hostport, tail = location:match("^([^/]*)/?(.*)$")
  local host, port = hostport:match("^(.-):(%d+)$")
  if not host then
    host, port = hostport, nil
  end

  local database = (tail or ""):gsub("%?.*$", "")

  local function unescape(value)
    if not value or value == "" then
      return nil
    end
    return (value:gsub("%%(%x%x)", function(hex)
      return string.char(tonumber(hex, 16))
    end))
  end

  return {
    adapter = adapter,
    host = host ~= "" and host or "127.0.0.1",
    port = tonumber(port) or DEFAULT_PORTS[adapter],
    user = unescape(user),
    password = unescape(password),
    database = database ~= "" and database or nil,
  }
end

local function read_lines(file)
  if vim.fn.filereadable(file) ~= 1 then
    return nil
  end
  return vim.fn.readfile(file)
end

--- Walk up from `start` looking for `name`, at most `depth` levels.
local function find_upward(name, start, depth)
  local found = vim.fs.find(name, {
    upward = true,
    path = start,
    limit = depth or 1,
    type = "file",
  })
  return found
end

--- `.env` style files: `KEY=value`, optionally quoted, `export` prefix allowed.
local function parse_env(lines)
  local values = {}
  for _, line in ipairs(lines) do
    local key, value = line:match("^%s*export%s+([%w_]+)%s*=%s*(.*)$")
    if not key then
      key, value = line:match("^%s*([%w_]+)%s*=%s*(.*)$")
    end
    if key then
      value = value:gsub("%s*#.*$", "")
      value = value:gsub("^['\"](.*)['\"]%s*$", "%1")
      values[key] = value
    end
  end
  return values
end

local function from_env_file(file)
  local lines = read_lines(file)
  if not lines then
    return {}
  end

  local env = parse_env(lines)
  local found = {}

  for _, key in ipairs({ "DATABASE_URL", "POSTGRES_URL", "MYSQL_URL", "DB_URL" }) do
    local spec = M.parse_url(env[key])
    if spec then
      spec.origin = file .. ":" .. key
      found[key:lower():gsub("_url$", "")] = spec
      break
    end
  end

  -- Discrete variables, the other common shape.
  if env.POSTGRES_HOST or env.POSTGRES_DB or env.POSTGRES_USER then
    found.postgres = {
      adapter = "postgres",
      host = env.POSTGRES_HOST or "127.0.0.1",
      port = tonumber(env.POSTGRES_PORT) or 5432,
      user = env.POSTGRES_USER or "postgres",
      password = env.POSTGRES_PASSWORD,
      database = env.POSTGRES_DB,
      origin = file,
    }
  end
  if env.MYSQL_HOST or env.MYSQL_DATABASE or env.MARIADB_DATABASE then
    found.mysql = {
      adapter = "mariadb",
      host = env.MYSQL_HOST or "127.0.0.1",
      port = tonumber(env.MYSQL_PORT) or 3306,
      user = env.MYSQL_USER or "root",
      password = env.MYSQL_PASSWORD or env.MARIADB_PASSWORD or env.MYSQL_ROOT_PASSWORD,
      database = env.MYSQL_DATABASE or env.MARIADB_DATABASE,
      origin = file,
    }
  end

  return found
end

--- Minimal YAML reader for the shapes docker-compose and Rails actually use:
--- nested maps by indentation plus `- item` sequences. Not a general parser.
---@param lines string[]
---@return table
function M.parse_yaml(lines)
  local root = {}
  local stack = { { indent = -1, node = root } }

  for _, raw in ipairs(lines) do
    local line = raw:gsub("%s+$", "")
    if line ~= "" and not line:match("^%s*#") then
      local indent = #(line:match("^(%s*)") or "")
      local content = line:sub(indent + 1)

      while #stack > 1 and indent <= stack[#stack].indent do
        table.remove(stack)
      end
      local parent = stack[#stack].node

      local item = content:match("^%-%s*(.*)$")
      if item then
        if not vim.islist(parent) and next(parent) == nil then
          setmetatable(parent, nil)
        end
        table.insert(parent, (item:gsub("^['\"](.*)['\"]$", "%1")))
      else
        local key, value = content:match("^([^:]+):%s*(.*)$")
        if key then
          key = key:gsub("^['\"](.*)['\"]$", "%1")
          if value == "" then
            local node = {}
            parent[key] = node
            table.insert(stack, { indent = indent, node = node })
          else
            value = value:gsub("%s*#.*$", "")
            parent[key] = (value:gsub("^['\"](.*)['\"]$", "%1"))
          end
        end
      end
    end
  end

  return root
end

local function image_adapter(image)
  if type(image) ~= "string" then
    return nil
  end
  image = image:lower()
  if image:match("postgres") or image:match("timescale") or image:match("pgvector") then
    return "postgres"
  end
  if image:match("mariadb") or image:match("mysql") or image:match("percona") then
    return "mariadb"
  end
  return nil
end

--- Take the host side of a `"5433:5432"` port mapping.
local function published_port(ports, fallback)
  if type(ports) ~= "table" then
    return fallback
  end
  for _, entry in ipairs(ports) do
    local text = tostring(entry)
    local host, container = text:match("(%d+):(%d+)")
    if host and tonumber(container) == fallback then
      return tonumber(host)
    end
    if host then
      return tonumber(host)
    end
  end
  return fallback
end

--- Compose `environment` may be a map or a `KEY=value` list.
local function service_env(service)
  local environment = service.environment
  if type(environment) ~= "table" then
    return {}
  end
  if vim.islist(environment) then
    return parse_env(environment)
  end
  return environment
end

local function from_docker_compose(file)
  local lines = read_lines(file)
  if not lines then
    return {}
  end

  local document = M.parse_yaml(lines)
  local services = document.services
  if type(services) ~= "table" then
    return {}
  end

  local found = {}
  for name, service in pairs(services) do
    if type(service) == "table" then
      local adapter = image_adapter(service.image)
      if adapter then
        local env = service_env(service)
        local port = published_port(service.ports, DEFAULT_PORTS[adapter])
        if adapter == "postgres" then
          found[name] = {
            adapter = "postgres",
            host = "127.0.0.1",
            port = port,
            user = env.POSTGRES_USER or "postgres",
            password = env.POSTGRES_PASSWORD,
            database = env.POSTGRES_DB or env.POSTGRES_USER or "postgres",
            origin = file,
          }
        else
          found[name] = {
            adapter = "mariadb",
            host = "127.0.0.1",
            port = port,
            user = env.MYSQL_USER or "root",
            password = env.MYSQL_PASSWORD
              or env.MYSQL_ROOT_PASSWORD
              or env.MARIADB_ROOT_PASSWORD,
            database = env.MYSQL_DATABASE or env.MARIADB_DATABASE,
            origin = file,
          }
        end
      end
    end
  end
  return found
end

local function from_database_yml(file)
  local lines = read_lines(file)
  if not lines then
    return {}
  end

  local document = M.parse_yaml(lines)
  local found = {}
  for environment, entry in pairs(document) do
    if type(entry) == "table" and entry.adapter then
      local adapter = ADAPTER_ALIASES[tostring(entry.adapter):lower()]
      if adapter then
        found[environment] = {
          adapter = adapter,
          host = entry.host or "127.0.0.1",
          port = tonumber(entry.port) or DEFAULT_PORTS[adapter],
          user = entry.username,
          password = entry.password,
          database = entry.database,
          path = adapter == "sqlite" and entry.database or nil,
          origin = file,
        }
      end
    end
  end
  return found
end

--- A project-local `.dbclient.lua` returning a table of connections. Loading
--- executes project code, so it is gated behind the same trust prompt style
--- Neovim uses for `exrc`.
local function from_project_lua(file)
  if vim.fn.filereadable(file) ~= 1 then
    return {}
  end

  local trusted = vim.secure and vim.secure.read and vim.secure.read(file)
  if not trusted then
    return {}
  end

  local chunk, err = loadstring(trusted, "@" .. file)
  if not chunk then
    vim.notify("DBClient: " .. file .. ": " .. tostring(err), vim.log.levels.WARN)
    return {}
  end

  local ok, result = pcall(chunk)
  if not ok or type(result) ~= "table" then
    return {}
  end

  local found = {}
  for name, spec in pairs(result.connections or result) do
    if type(spec) == "table" then
      spec.origin = file
      found[name] = spec
    end
  end
  return found
end

--- Scan the project for connection definitions.
---@param opts? { cwd?: string, sources?: string[], depth?: integer }
---@return table<string, table>
function M.scan(opts)
  opts = opts or {}
  local cwd = opts.cwd or vim.uv.cwd()
  local depth = opts.depth or 4
  local sources = opts.sources or { "env", "docker_compose", "database_yml", "dbclient_lua" }
  local found = {}

  local function merge(prefix, entries)
    for name, spec in pairs(entries) do
      local key = prefix .. name
      if not found[key] then
        spec.detected = true
        found[key] = spec
      end
    end
  end

  local handlers = {
    env = function()
      for _, name in ipairs({ ".env", ".env.local", ".env.development" }) do
        for _, file in ipairs(find_upward(name, cwd, depth)) do
          merge("env:", from_env_file(file))
        end
      end
    end,
    docker_compose = function()
      for _, name in ipairs({
        "docker-compose.yml",
        "docker-compose.yaml",
        "compose.yml",
        "compose.yaml",
      }) do
        for _, file in ipairs(find_upward(name, cwd, depth)) do
          merge("compose:", from_docker_compose(file))
        end
      end
    end,
    database_yml = function()
      for _, file in ipairs(find_upward("database.yml", cwd, depth)) do
        merge("rails:", from_database_yml(file))
      end
    end,
    dbclient_lua = function()
      for _, file in ipairs(find_upward(".dbclient.lua", cwd, depth)) do
        merge("", from_project_lua(file))
      end
    end,
  }

  for _, source in ipairs(sources) do
    local handler = handlers[source]
    if handler then
      pcall(handler)
    end
  end

  return found
end

return M

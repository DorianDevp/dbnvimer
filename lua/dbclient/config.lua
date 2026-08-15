--- Plugin configuration and defaults.

local M = {}

local function plugin_root()
  local source = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

M.root = plugin_root()

local function bundled_core_name()
  local uname = vim.uv and vim.uv.os_uname() or vim.loop.os_uname()
  local system = ({
    Linux = "linux",
    Darwin = "macos",
    Windows_NT = "windows",
  })[uname.sysname]
  local machine = ({
    x86_64 = "x86_64",
    amd64 = "x86_64",
    arm64 = "aarch64",
    aarch64 = "aarch64",
  })[uname.machine:lower()]

  if not system or not machine then
    return nil
  end

  local extension = system == "windows" and ".exe" or ""
  return "dbclient-core-" .. system .. "-" .. machine .. extension
end

--- Prefer a locally built binary, then the bundled one, then `$PATH`.
local function default_core_command()
  local candidates = {
    M.root .. "/rust/dbclient-core/target/release/dbclient-core",
  }
  local bundled = bundled_core_name()
  if bundled then
    table.insert(candidates, M.root .. "/bin/" .. bundled)
  end

  for _, path in ipairs(candidates) do
    if vim.fn.executable(path) == 1 then
      return path
    end
  end
  return "dbclient-core"
end

local function data_path(...)
  return table.concat({ vim.fn.stdpath("data"), "dbclient", ... }, "/")
end

local defaults = {
  core = {
    command = nil, -- resolved lazily so tests can override it first
    --- Applied to every session where the backend supports it.
    statement_timeout_ms = nil,
  },

  ui = {
    sidebar_width = 38,
    result_height = 14,
    max_cell_width = 48,
    preview_limit = 200,
    query_limit = 5000,
    --- Shown in place of a SQL NULL. Always highlighted differently from the
    --- literal text "NULL", which renders as-is.
    null_display = "∅",
    bool_display = { "true", "false" },
    row_stripes = true,
    winbar = true,
    --- Show `→ table.column` next to foreign key columns.
    virtual_fk = true,
    --- Pin the header row as a winbar while scrolling.
    sticky_header = true,
    --- Terminal graphics for image blobs when the terminal supports it.
    image_preview = true,
  },

  --- Set to false to register no default mappings at all.
  keys = true,

  --- Connections declared inline in `setup()`.
  connections = {},

  --- Connections managed from inside the client.
  store = {
    enabled = true,
    path = nil, -- resolved lazily
  },

  --- Automatic project detection (.env, docker-compose.yml, ...).
  detect = {
    enabled = true,
    sources = { "env", "docker_compose", "database_yml", "dbclient_lua" },
    --- Directories walked upward from the cwd looking for project files.
    depth = 4,
  },

  history = {
    enabled = true,
    path = nil, -- resolved lazily
    limit = 1000,
  },

  --- Extra confirmation before dangerous statements.
  guard = {
    confirm_unfiltered_writes = true,
    confirm_destructive = true,
    --- Connections with this access level require typing the object name.
    typed_confirmation_for = { "write" },
  },

  export = {
    dir = nil, -- resolved lazily
  },

  --- Extra `codegen` templates, keyed by name.
  codegen = {},

  log = {
    --- Keep the last N executed statements for `:DBClientLog`.
    limit = 500,
  },
}

M.values = vim.deepcopy(defaults)

local function resolve_lazy(values)
  values.core.command = values.core.command or default_core_command()
  values.store.path = values.store.path or data_path("connections.json")
  values.history.path = values.history.path or data_path("history.jsonl")
  values.export.dir = values.export.dir or data_path("exports")
  return values
end

---@param opts table|nil
function M.setup(opts)
  M.values = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  resolve_lazy(M.values)
  return M.values
end

function M.get()
  if not M.values.core.command then
    resolve_lazy(M.values)
  end
  return M.values
end

--- Default keys for the leader-prefixed global mappings.
function M.defaults()
  return vim.deepcopy(defaults)
end

return M

local M = {}

local function plugin_root()
  local source = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

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

local function default_core_command()
  local name = bundled_core_name()
  if not name then
    return "dbclient-core"
  end

  local path = plugin_root() .. "/bin/" .. name
  if vim.fn.executable(path) == 1 then
    return path
  end

  return "dbclient-core"
end

local defaults = {
  core = {
    command = default_core_command(),
  },
  ui = {
    sidebar_width = 38,
    result_height = 14,
    max_cell_width = 48,
    preview_limit = 200,
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

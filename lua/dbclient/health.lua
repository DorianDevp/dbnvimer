--- `:checkhealth dbclient`.

local M = {}

local function start(name)
  (vim.health.start or vim.health.report_start)(name)
end
local function ok(message)
  (vim.health.ok or vim.health.report_ok)(message)
end
local function warn(message, advice)
  (vim.health.warn or vim.health.report_warn)(message, advice)
end
local function error_(message, advice)
  (vim.health.error or vim.health.report_error)(message, advice)
end
local function info(message)
  (vim.health.info or vim.health.report_info)(message)
end

function M.check()
  local config = require("dbclient.config")
  local client = require("dbclient.core.client")
  local connections = require("dbclient.connections")

  start("dbclient: environment")

  if vim.fn.has("nvim-0.10") == 1 then
    ok("Neovim " .. tostring(vim.version()))
  else
    error_("Neovim 0.10 or newer is required")
  end

  if vim.fn.executable("ssh") == 1 then
    ok("ssh found on PATH")
  else
    warn("ssh not found on PATH", { "SSH tunnels will not work" })
  end

  start("dbclient: core binary")

  local command = config.get().core.command
  if vim.fn.executable(command) == 1 then
    ok("core binary: " .. command)
  else
    error_("core binary not found: " .. command, {
      "Build it with: cargo build --release --manifest-path rust/dbclient-core/Cargo.toml",
      "Or point setup({ core = { command = ... } }) at an existing binary",
    })
    return
  end

  local result = vim.system({ command, "version" }, { text = true }):wait()
  if result.code ~= 0 then
    error_("core binary failed to run: " .. (result.stderr or ""))
    return
  end

  local decoded = vim.json.decode(result.stdout or "{}")
  local data = decoded and decoded.data or {}
  info("core version: " .. tostring(data.version))

  if data.protocol == client.EXPECTED_PROTOCOL then
    ok(("protocol %s matches the plugin"):format(data.protocol))
  else
    error_(
      ("protocol mismatch: core speaks %s, the plugin speaks %s")
        :format(tostring(data.protocol), client.EXPECTED_PROTOCOL),
      { "Rebuild dbclient-core, or update the plugin" }
    )
  end

  start("dbclient: daemon")

  local err = client.await("version", {}, nil, 3000)
  if err then
    error_("the daemon did not answer: " .. tostring(err))
  else
    ok("daemon started and answered")
  end

  start("dbclient: connections")

  connections.rescan()
  local all = connections.all()
  local names = vim.tbl_keys(all)
  table.sort(names)

  if #names == 0 then
    warn("no connections configured", {
      "Add one with <leader>dC, or in setup({ connections = { ... } })",
    })
  else
    for _, name in ipairs(names) do
      local spec = all[name]
      local valid, reason = connections.validate(spec)
      local summary = ("%s  [%s]  %s"):format(name, spec.source, connections.describe(name, spec))
      if not valid then
        warn(summary .. " — " .. tostring(reason))
      elseif spec.password and spec.source == "setup" then
        warn(summary, {
          "This connection has a literal password in your config.",
          "Prefer password_cmd, password_env or password_prompt.",
        })
      else
        ok(summary)
      end
    end
  end

  start("dbclient: storage")

  local store = require("dbclient.connections.store")
  local store_path = store.path()
  if vim.fn.filereadable(store_path) == 1 then
    local stat = vim.uv.fs_stat(store_path)
    local mode = stat and bit.band(stat.mode, 511) or 0
    if mode == 384 then
      ok(("connection store: %s (0600)"):format(store_path))
    else
      warn(("connection store %s has mode %o"):format(store_path, mode), {
        "Run: chmod 600 " .. store_path,
      })
    end
  else
    info("connection store not created yet: " .. store_path)
  end

  local history_path = config.get().history.path
  info("history: " .. history_path)

  start("dbclient: optional integrations")

  for name, hint in pairs({
    ["nvim-treesitter"] = "better SQL highlighting and statement objects",
    ["cmp"] = "completion source registration",
    ["telescope"] = "richer pickers through vim.ui.select",
  }) do
    if pcall(require, name) then
      ok(("%s found (%s)"):format(name, hint))
    else
      info(("%s not installed (%s)"):format(name, hint))
    end
  end
end

return M

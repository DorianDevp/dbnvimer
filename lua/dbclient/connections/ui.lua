--- The in-client connection manager.
---
--- Connections are edited as text in a buffer and saved with `:w`, the same
--- gesture as everything else in the plugin. A form of floating input prompts
--- would need its own navigation; a buffer already has yours.
---
--- Passwords are never stored. A connection names where its secret comes from
--- — an environment variable, a shell command, or a prompt — and the value
--- lives in memory for the session only.

local buffer = require("dbclient.ui.buffer")
local client = require("dbclient.core.client")
local connections = require("dbclient.connections")
local help = require("dbclient.ui.help")
local highlights = require("dbclient.ui.highlights")
local keymap = require("dbclient.keymap")
local session = require("dbclient.session")
local store = require("dbclient.connections.store")
local window = require("dbclient.ui.window")

local M = {
  --- bufnr -> { name, on_save }
  editors = {},
  list_buf = nil,
  list_entries = {},
}

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

local FIELDS = {
  { key = "adapter", hint = "mariadb | postgres | sqlite" },
  { key = "host" },
  { key = "port" },
  { key = "user" },
  { key = "database" },
  { key = "path", hint = "sqlite only" },
  { key = "access", hint = "write | read | sandbox" },
  { key = "color", hint = "red | orange | yellow | green | blue | purple | cyan | grey" },
  { key = "password_env", hint = "name of an environment variable" },
  { key = "password_cmd", hint = "shell command printing the password" },
  { key = "password_prompt", hint = "true to be asked on connect" },
  { key = "statement_timeout_ms" },
  { key = "ssh.host", hint = "host or a Host alias from ~/.ssh/config" },
  { key = "ssh.user" },
  { key = "ssh.port" },
  { key = "ssh.identity_file" },
  { key = "ssh.jump", hint = "ProxyJump chain" },
}

--- Render a spec into editable `key = value` lines.
---@param name string
---@param spec table
---@return string[]
local function to_lines(name, spec)
  local lines = {
    "# DBClient connection. Edit and :w to save.",
    "# Secrets are never written here: name an env var or a command instead.",
    "",
    ("name = %s"):format(name or ""),
  }

  local width = 0
  for _, field in ipairs(FIELDS) do
    width = math.max(width, #field.key)
  end

  for _, field in ipairs(FIELDS) do
    local value
    if field.key:find("%.") then
      local group, key = field.key:match("^(.-)%.(.*)$")
      value = spec[group] and spec[group][key]
    else
      value = spec[field.key]
    end
    if value == vim.NIL then
      value = nil
    end
    local text = ("%-" .. width .. "s = %s"):format(field.key, value ~= nil and tostring(value) or "")
    if field.hint then
      text = ("%-44s # %s"):format(text, field.hint)
    end
    table.insert(lines, text)
  end

  return lines
end

--- Parse the editor buffer back into `name, spec`.
---@param lines string[]
---@return string|nil name, table spec
local function from_lines(lines)
  local name
  local spec = {}

  for _, line in ipairs(lines) do
    local stripped = line:gsub("%s+#.*$", "")
    local key, value = stripped:match("^%s*([%w_.]+)%s*=%s*(.-)%s*$")
    if key then
      if value == "" then
        value = nil
      end
      if key == "name" then
        name = value
      elseif value ~= nil then
        if key:find("%.") then
          local group, sub_key = key:match("^(.-)%.(.*)$")
          spec[group] = spec[group] or {}
          spec[group][sub_key] = tonumber(value) or (value == "true" and true)
            or (value == "false" and false)
            or value
        else
          spec[key] = tonumber(value) or (value == "true" and true)
            or (value == "false" and false)
            or value
        end
      end
    end
  end

  return name, spec
end

--- Open an editor buffer for a connection.
---@param name string|nil  nil creates a new one
---@param spec table|nil
---@param on_save fun()|nil
local function open_editor(name, spec, on_save)
  local title = name and ("dbclient://connection/%s"):format(name)
    or "dbclient://connection/new"
  local bufnr = buffer.scratch(title, { modifiable = true, buftype = "acwrite" })
  M.editors[bufnr] = { name = name, on_save = on_save }

  vim.bo[bufnr].filetype = "dbclient-connection"
  buffer.set_lines(bufnr, to_lines(name, spec or { adapter = "postgres", access = "write" }))

  local winid = window.float(bufnr, {
    title = name and ("edit " .. name) or "new connection",
    width = 78,
    max_height = 0.85,
    cursorline = false,
  })
  vim.wo[winid].wrap = false

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    once = false,
    callback = function()
      local entry = M.editors[bufnr]
      local parsed_name, parsed_spec = from_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

      if not parsed_name or parsed_name == "" then
        return notify("a connection needs a name", vim.log.levels.ERROR)
      end

      local ok, err = connections.save(parsed_name, parsed_spec)
      if not ok then
        return notify(err, vim.log.levels.ERROR)
      end

      -- A rename means the old entry has to go.
      if entry.name and entry.name ~= parsed_name then
        connections.delete(entry.name)
      end

      vim.bo[bufnr].modified = false
      notify(("saved %s to %s"):format(parsed_name, store.path()))
      window.close(winid, bufnr)
      M.editors[bufnr] = nil
      if entry.on_save then
        entry.on_save()
      end
    end,
  })

  vim.keymap.set("n", "q", function()
    if vim.bo[bufnr].modified then
      return notify("unsaved changes; :w to save or :q! to discard", vim.log.levels.WARN)
    end
    window.close(winid, bufnr)
    M.editors[bufnr] = nil
  end, { buffer = bufnr, silent = true, nowait = true })
end

---@param on_save fun()|nil
function M.create(on_save)
  open_editor(nil, {
    adapter = "postgres",
    host = "127.0.0.1",
    port = 5432,
    access = "write",
  }, on_save)
end

---@param name string
---@param on_save fun()|nil
function M.edit(name, on_save)
  local spec = connections.get(name)
  if not spec then
    return notify("unknown connection " .. name, vim.log.levels.ERROR)
  end
  if spec.source == "setup" then
    return notify(
      ("`%s` is defined in your Neovim config; edit it there"):format(name),
      vim.log.levels.WARN
    )
  end
  if spec.source == "project" then
    return notify(
      ("`%s` was detected in the project; press y to copy it into the store first"):format(name),
      vim.log.levels.WARN
    )
  end
  open_editor(name, spec, on_save)
end

---@param name string
---@param on_done fun()|nil
function M.delete(name, on_done)
  local spec = connections.get(name)
  if not spec then
    return
  end

  vim.ui.select({ "no", "yes" }, { prompt = ("delete connection `%s`?"):format(name) }, function(choice)
    if choice ~= "yes" then
      return
    end
    local ok, err = connections.delete(name)
    if ok then
      notify("deleted " .. name)
      if on_done then
        on_done()
      end
    else
      notify(err, vim.log.levels.ERROR)
    end
  end)
end

--- Open a session, report the server version and close it again.
---@param name string
function M.test(name)
  local spec = connections.get(name)
  if not spec then
    return notify("unknown connection " .. name, vim.log.levels.ERROR)
  end

  notify("testing " .. name .. "...")
  connections.resolve_password(name, spec, function(password)
    local connection, ssh = connections.to_wire(name, spec, password)
    client.async(function()
      local result = client.call("open-session", { connection = connection, ssh = ssh })
      local info = result.info
      client.request("close-session", {}, result.session, function() end)
      notify(("%s ok: %s"):format(name, info.server_version))
    end, function(err)
      notify(("%s failed: %s"):format(name, err), vim.log.levels.ERROR)
    end)
  end)
end

---@param name string
---@param on_done fun()|nil
function M.adopt(name, on_done)
  local ok, err = connections.adopt(name)
  if ok then
    notify("copied " .. name .. " into the store")
    if on_done then
      on_done()
    end
  else
    notify(err, vim.log.levels.ERROR)
  end
end

-- ---------------------------------------------------------------------------
-- The list view
-- ---------------------------------------------------------------------------

local function render_list()
  local all = connections.all()
  local names = vim.tbl_keys(all)
  table.sort(names)

  local lines = {}
  local marks = {}
  M.list_entries = {}

  table.insert(lines, "connections")
  table.insert(marks, { line = 0, group = "DBClientHeader" })
  table.insert(lines, "")
  table.insert(M.list_entries, false)
  table.insert(M.list_entries, false)

  local width = 0
  for _, name in ipairs(names) do
    width = math.max(width, #name)
  end

  for _, name in ipairs(names) do
    local spec = all[name]
    local connected = session.find_by_name(name) ~= nil
    table.insert(
      lines,
      ("%s %-" .. width .. "s  %-9s %s"):format(
        connected and "●" or "○",
        name,
        spec.source,
        connections.describe(name, spec)
      )
    )
    table.insert(marks, {
      line = #lines - 1,
      group = connected and highlights.connection_group(spec.color)
        or (spec.source == "project" and "DBClientDetected" or "DBClientColumn"),
    })
    table.insert(M.list_entries, name)
  end

  if #names == 0 then
    table.insert(lines, "  none yet — press a to add one")
    table.insert(M.list_entries, false)
  end

  table.insert(lines, "")
  table.insert(lines, "a add   c edit   x delete   t test   y adopt   <CR> connect   g? help")
  table.insert(marks, { line = #lines - 1, group = "DBClientHelpText" })

  buffer.set_lines(M.list_buf, lines)
  highlights.lines(M.list_buf, marks)
end

local function selected_name()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local entry = M.list_entries[row]
  return entry or nil
end

--- Open the connection manager.
function M.open()
  connections.rescan()
  M.list_buf = buffer.scratch("dbclient://connections", { modifiable = false })
  vim.bo[M.list_buf].filetype = "dbclient-connections"

  local winid = window.float(M.list_buf, {
    title = "connections",
    max_width = 0.8,
    max_height = 0.7,
  })

  render_list()

  keymap.apply("connections", M.list_buf, {
    connect = function()
      local name = selected_name()
      if not name then
        return
      end
      window.close(winid, nil)
      session.connect(name, function(target, err)
        if err then
          return notify(err, vim.log.levels.ERROR)
        end
        require("dbclient.completion").warm(target.id)
        require("dbclient.ui.sidebar").render()
        notify("connected to " .. name)
      end)
    end,
    add = function()
      M.create(render_list)
    end,
    edit = function()
      local name = selected_name()
      if name then
        M.edit(name, render_list)
      end
    end,
    delete = function()
      local name = selected_name()
      if name then
        M.delete(name, render_list)
      end
    end,
    test = function()
      local name = selected_name()
      if name then
        M.test(name)
      end
    end,
    adopt = function()
      local name = selected_name()
      if name then
        M.adopt(name, render_list)
      end
    end,
    refresh = function()
      connections.rescan()
      render_list()
    end,
    close = function()
      window.close(winid, nil)
    end,
    help = help.handler("connections"),
  })
end

M.from_lines = from_lines
M.to_lines = to_lines

return M

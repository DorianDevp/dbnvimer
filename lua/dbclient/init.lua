--- DBClient.nvim: a keyboard-first database client for Neovim.

local client = require("dbclient.core.client")
local config = require("dbclient.config")
local connections = require("dbclient.connections")
local highlights = require("dbclient.ui.highlights")
local keymap = require("dbclient.keymap")
local pickers = require("dbclient.pickers")
local session = require("dbclient.session")
local winbar = require("dbclient.ui.winbar")

local M = {}

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

local function sidebar()
  return require("dbclient.ui.sidebar")
end

local function query()
  return require("dbclient.ui.query")
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.open()
  sidebar().open()
end

function M.toggle()
  sidebar().toggle()
end

function M.close()
  session.disconnect_all()
  sidebar().render()
end

---@param name string
function M.connect(name)
  session.connect(name, function(target, err)
    if err then
      return notify(err, vim.log.levels.ERROR)
    end
    require("dbclient.completion").warm(target.id)
    sidebar().render()
    notify("connected to " .. target.name)
  end)
end

function M.pick_connection()
  pickers.connection()
end

function M.manage_connections()
  require("dbclient.connections.ui").open()
end

---@param schema string
---@param table_name string
function M.data(schema, table_name)
  require("dbclient.ui.data").open({ schema = schema, table = table_name })
end

function M.query_buffer()
  query().open()
end

function M.execute()
  query().execute()
end

function M.cancel()
  session.cancel()
end

--- Transaction control on the active session.
---@param action "begin"|"commit"|"rollback"
function M.transaction(action)
  local target = session.current()
  if not target then
    return notify("no active connection", vim.log.levels.WARN)
  end
  client.async(function()
    session[action](target.id)
    winbar.refresh()
    sidebar().render()
    notify(({
      begin = "transaction started",
      commit = "committed",
      rollback = "rolled back",
    })[action])
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

--- Statusline component for lualine and friends.
function M.statusline()
  return winbar.statusline()
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

local function complete_connections()
  return connections.names()
end

local function define_commands()
  local command = vim.api.nvim_create_user_command

  command("DBClient", M.open, { desc = "Open the DBClient sidebar", force = true })
  command("DBClientToggle", M.toggle, { desc = "Toggle the DBClient sidebar", force = true })
  command("DBClientClose", M.close, { desc = "Close every connection", force = true })

  command("DBClientConnect", function(args)
    if args.args == "" then
      return M.pick_connection()
    end
    M.connect(args.args)
  end, { nargs = "?", complete = complete_connections, force = true, desc = "Open a connection" })

  command("DBClientDisconnect", function(args)
    if args.args == "" then
      return session.disconnect()
    end
    local target = session.find_by_name(args.args)
    if target then
      session.disconnect(target.id)
    end
  end, { nargs = "?", complete = complete_connections, force = true })

  command("DBClientConnections", M.manage_connections, {
    desc = "Manage connections",
    force = true,
  })

  command("DBClientQuery", M.execute, { range = true, force = true })
  command("DBClientQueryBuffer", M.query_buffer, { force = true })

  command("DBClientData", function(args)
    local parts = vim.split(args.args, ".", { plain = true })
    if #parts == 2 then
      return M.data(parts[1], parts[2])
    end
    if #parts == 1 and parts[1] ~= "" then
      local target = session.current()
      local schema = target and target.info and target.info.database
      if schema then
        return M.data(schema, parts[1])
      end
    end
    notify("usage: DBClientData [schema.]table", vim.log.levels.ERROR)
  end, { nargs = 1, force = true })

  command("DBClientExplain", function(args)
    require("dbclient.ui.query").explain(args.bang)
  end, { bang = true, force = true, desc = "Explain the statement at the cursor" })

  command("DBClientBegin", function()
    M.transaction("begin")
  end, { force = true })
  command("DBClientCommit", function()
    M.transaction("commit")
  end, { force = true })
  command("DBClientRollback", function()
    M.transaction("rollback")
  end, { force = true })

  command("DBClientCancel", M.cancel, { force = true, desc = "Cancel the running statement" })

  command("DBClientActivity", function()
    require("dbclient.ui.activity").open({ mode = "activity" })
  end, { force = true })
  command("DBClientLocks", function()
    require("dbclient.ui.activity").open({ mode = "locks" })
  end, { force = true })

  command("DBClientHistory", pickers.history, { force = true })
  command("DBClientLog", pickers.statement_log, { force = true })
  command("DBClientSearch", pickers.objects, { force = true })
  command("DBClientSessions", pickers.session, { force = true })
  command("DBClientSchemaDiff", pickers.schema_diff, { force = true })

  command("DBClientDDL", function(args)
    local parts = vim.split(args.args, ".", { plain = true })
    if #parts ~= 2 then
      return notify("usage: DBClientDDL schema.object", vim.log.levels.ERROR)
    end
    require("dbclient.ui.ddl").open({ kind = "table", schema = parts[1], name = parts[2] })
  end, { nargs = 1, force = true })

  command("DBClientGenerate", function(args)
    local parts = vim.split(args.args, ".", { plain = true })
    if #parts < 2 then
      return notify("usage: DBClientGenerate schema.table [template]", vim.log.levels.ERROR)
    end
    require("dbclient.codegen").generate({
      schema = parts[1],
      table = parts[2],
      template = parts[3],
    })
  end, { nargs = "+", force = true })

  command("DBClientHelp", function()
    require("dbclient.ui.help").show_all()
  end, { force = true })

  command("DBClientRestart", function()
    session.disconnect_all()
    client.stop()
    vim.defer_fn(function()
      client.ensure()
      notify("core restarted")
    end, 300)
  end, { force = true })
end

-- ---------------------------------------------------------------------------
-- Autocommands
-- ---------------------------------------------------------------------------

local function define_autocommands()
  local group = vim.api.nvim_create_augroup("DBClient", { clear = true })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      session.disconnect_all()
      client.stop()
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = highlights.setup,
  })

  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function()
      connections.rescan()
      if require("dbclient.ui.sidebar").bufnr then
        require("dbclient.ui.sidebar").render()
      end
    end,
  })

  -- `-- @conn: name` binds a SQL file to a connection.
  vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
    group = group,
    pattern = "*.sql",
    callback = function(args)
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(args.buf) then
          query().detect_binding(args.buf)
        end
      end, 50)
    end,
  })

  -- Keep the spinner running while requests are in flight.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DBClientRequest",
    callback = function()
      winbar.start_spinner()
    end,
  })

  -- `<CR>` in a DBClient quickfix list opens the referenced rows.
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "qf",
    callback = function(args)
      local list = vim.fn.getqflist({ title = 0 })
      if not tostring(list.title):match("^DBClient") then
        return
      end
      vim.keymap.set("n", "<CR>", function()
        local line = vim.api.nvim_win_get_cursor(0)[1]
        local items = vim.fn.getqflist()
        local item = items[line]
        local data = item and item.user_data
        if type(data) == "table" and data.dbclient then
          vim.cmd("cclose")
          require("dbclient.ui.data").open({
            session_id = data.session_id,
            schema = data.schema,
            table = data.table,
            filter = data.filter,
          })
        end
      end, { buffer = args.buf, silent = true, nowait = true })
    end,
  })

  session.on("transaction", function()
    winbar.refresh()
  end)
  session.on("activate", function()
    winbar.refresh()
  end)
  session.on("connect", function()
    winbar.refresh()
  end)
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

local function global_handlers()
  return {
    toggle_sidebar = M.toggle,
    pick_connection = M.pick_connection,
    manage_connections = M.manage_connections,
    open_query = M.query_buffer,
    execute_buffer = function()
      query().execute_buffer()
    end,
    search_objects = pickers.objects,
    history = pickers.history,
    statement_log = pickers.statement_log,
    activity = function()
      require("dbclient.ui.activity").open({ mode = "activity" })
    end,
    locks = function()
      require("dbclient.ui.activity").open({ mode = "locks" })
    end,
    cancel = M.cancel,
    begin = function()
      M.transaction("begin")
    end,
    commit = function()
      M.transaction("commit")
    end,
    rollback = function()
      M.transaction("rollback")
    end,
    disconnect = function()
      session.disconnect()
      sidebar().render()
    end,
  }
end

---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
  highlights.setup()
  define_commands()
  define_autocommands()
  keymap.apply("global", nil, global_handlers())

  connections.rescan()

  -- Register the completion source when nvim-cmp is around.
  local has_cmp, cmp = pcall(require, "cmp")
  if has_cmp then
    pcall(function()
      cmp.register_source("dbclient", require("dbclient.completion").cmp_source())
    end)
  end

  return config.get()
end

M.handlers = global_handlers

return M

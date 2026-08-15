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

  command("DBClientWatch", function(args)
    local interval = tonumber(args.args:match("^(%d+)%s")) or 5
    local sql = args.args:gsub("^%d+%s+", "")
    if sql == "" then
      return notify("usage: DBClientWatch [seconds] <sql>", vim.log.levels.ERROR)
    end
    require("dbclient.watch").start({ sql = sql, interval = interval })
  end, { nargs = "+", force = true, desc = "Re-run a statement on a timer" })

  command("DBClientProfile", function(args)
    local runs = tonumber(args.args:match("^(%d+)%s")) or 10
    local sql = args.args:gsub("^%d+%s+", "")
    if sql == "" then
      return notify("usage: DBClientProfile [runs] <sql>", vim.log.levels.ERROR)
    end
    require("dbclient.watch").profile({ sql = sql, runs = runs })
  end, { nargs = "+", force = true, desc = "Time a statement over several runs" })

  command("DBClientBroadcast", function(args)
    if args.args == "" then
      return require("dbclient.broadcast").prompt()
    end
    require("dbclient.broadcast").run({ sql = args.args })
  end, { nargs = "*", force = true, desc = "Run a statement on every open connection" })

  command("DBClientDiagram", function(args)
    local schema = args.args
    if schema == "" then
      local target = session.current()
      schema = target and target.info and target.info.database or ""
    end
    if schema == "" then
      return notify("usage: DBClientDiagram <schema>", vim.log.levels.ERROR)
    end
    require("dbclient.diagram").show({ schema = schema })
  end, { nargs = "?", force = true, desc = "Entity relationship diagram" })

  command("DBClientImport", function(args)
    local parts = vim.split(args.args, "%s+")
    local qualified = vim.split(parts[1] or "", ".", { plain = true })
    if #qualified ~= 2 then
      return notify("usage: DBClientImport schema.table [file.csv]", vim.log.levels.ERROR)
    end
    local import = require("dbclient.import")
    if parts[2] then
      import.start({ schema = qualified[1], table = qualified[2], path = parts[2] })
    else
      import.prompt({ schema = qualified[1], table = qualified[2] })
    end
  end, { nargs = "+", complete = "file", force = true, desc = "Import a CSV" })

  command("DBClientNotebook", function()
    require("dbclient.notebook").enable()
  end, { force = true, desc = "Enable notebook mode in this markdown buffer" })

  command("DBClientSnapshot", function()
    require("dbclient.snapshot").save_current()
  end, { force = true, desc = "Save the current result set" })

  command("DBClientCompare", function()
    require("dbclient.snapshot").diff_with_saved()
  end, { force = true, desc = "Compare the result set with a snapshot" })

  command("DBClientCompareConnections", function()
    require("dbclient.snapshot").diff_connections()
  end, { force = true, desc = "Run a statement on two connections and diff" })

  command("DBClientUndoLog", function()
    require("dbclient.undolog").open()
  end, { force = true, desc = "Writes DBClient made, and how to undo them" })

  command("DBClientPipe", function(args)
    require("dbclient.snapshot").pipe(args.args)
  end, { nargs = "+", force = true, desc = "Pipe the result set through a shell command" })

  command("DBClientIndexes", function(args)
    local target = session.current()
    if not target then
      return notify("no active connection", vim.log.levels.WARN)
    end
    local schema = args.args ~= "" and args.args
      or (target.info and target.info.database)
    if not schema or schema == "" then
      return notify("usage: DBClientIndexes <schema>", vim.log.levels.ERROR)
    end
    client.async(function()
      local result = session.unused_indexes(target.id, schema)
      require("dbclient.ui.results").show(result, {
        session_id = target.id,
        session_name = "index usage",
      })
    end, function(err)
      notify(err, vim.log.levels.ERROR)
    end)
  end, { nargs = "?", force = true, desc = "Index usage and unused index candidates" })

  command("DBClientWorkspaceSave", function()
    local path = require("dbclient.workspace").save()
    notify(path and ("workspace saved to " .. path) or "nothing to save")
  end, { force = true, desc = "Save the workspace for this directory" })

  command("DBClientWorkspaceRestore", function()
    require("dbclient.workspace").restore()
  end, { force = true, desc = "Restore the workspace for this directory" })

  command("DBClientWorkspaceShow", function()
    local lines = require("dbclient.workspace").describe()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    local winid = require("dbclient.ui.window").float(bufnr, { title = "workspace" })
    require("dbclient.ui.window").close_keys(bufnr, winid)
  end, { force = true, desc = "Show the saved workspace" })

  command("DBClientWorkspaceClear", function()
    require("dbclient.workspace").clear()
  end, { force = true, desc = "Forget the saved workspace" })

  command("DBClientScratch", function(args)
    require("dbclient.ui.scratch").open({ sql = args.args ~= "" and args.args or nil })
  end, { nargs = "*", force = true, desc = "Quick query tab" })

  command("DBClientQueries", function()
    require("dbclient.ui.queries").open()
  end, { force = true, desc = "Browse saved queries" })

  command("DBClientSaveQuery", function(args)
    local bufnr = vim.api.nvim_get_current_buf()
    local bound = query().buffers[bufnr]
    local target = bound and session.get(bound.session_id) or session.current()
    local sql = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

    if args.args ~= "" then
      local path, err = require("dbclient.queries").save({
        name = args.args,
        sql = sql,
        connection = target and target.name,
        scope = "global",
      })
      return notify(path and ("saved to " .. path) or tostring(err),
        path and vim.log.levels.INFO or vim.log.levels.ERROR)
    end

    require("dbclient.queries").prompt_save({
      sql = sql,
      connection = target and target.name,
    })
  end, { nargs = "?", force = true, desc = "Save the current query" })

  command("DBClientTrail", function()
    require("dbclient.trail").pick()
  end, { force = true, desc = "Jump to any point on the navigation trail" })

  command("DBClientBack", function(args)
    require("dbclient.trail").back(tonumber(args.args) or 1)
  end, { nargs = "?", force = true, desc = "Back along the navigation trail" })

  command("DBClientForward", function(args)
    require("dbclient.trail").forward(tonumber(args.args) or 1)
  end, { nargs = "?", force = true, desc = "Forward along the navigation trail" })

  command("DBClientJoin", function(args)
    local parts = vim.split(args.args, "%s+")
    if #parts == 2 then
      local target = session.current()
      local schema = target and target.info and target.info.database
      if schema then
        return require("dbclient.joins").build({
          schema = schema,
          from = parts[1],
          to = parts[2],
        })
      end
    end
    require("dbclient.joins").prompt()
  end, { nargs = "*", force = true, desc = "Build a join between two tables" })

  command("DBClientAudit", function(args)
    require("dbclient.audit").prompt({ deep = args.bang })
  end, { bang = true, force = true, desc = "Audit the schema (! also reads column statistics)" })

  command("DBClientChart", function()
    require("dbclient.chart").pick_and_show()
  end, { force = true, desc = "Chart the current result set" })

  command("DBClientBlastRadius", function()
    query().blast_radius()
  end, { force = true, desc = "Show which rows the statement would change" })

  command("DBClientExport", function(args)
    local view = require("dbclient.ui.results").view()
    local target = session.current()
    if not target then
      return notify("no active connection", vim.log.levels.WARN)
    end

    local parts = vim.split(args.args, ".", { plain = true })
    if #parts == 2 then
      return require("dbclient.export.ui").open({
        session_id = target.id,
        schema = parts[1],
        table = parts[2],
      })
    end
    require("dbclient.export.ui").open({
      session_id = target.id,
      sql = view and view.sql,
    })
  end, { nargs = "?", force = true, desc = "Export a table or the last result set" })

  command("DBClientExportPreset", function()
    require("dbclient.export.ui").load_preset({
      session_id = session.current() and session.current().id,
    })
  end, { force = true, desc = "Open a saved export preset" })

  command("DBClientFixture", function(args)
    local parts = vim.split(args.args, "%s+")
    local qualified = vim.split(parts[1] or "", ".", { plain = true })
    if #qualified ~= 2 or not parts[2] then
      return notify("usage: DBClientFixture schema.table key=value [key=value]", vim.log.levels.ERROR)
    end

    local pk = {}
    for index = 2, #parts do
      local key, value = parts[index]:match("^([%w_]+)=(.*)$")
      if key then
        pk[key] = value
      end
    end
    if vim.tbl_isempty(pk) then
      return notify("give the row's key as key=value", vim.log.levels.ERROR)
    end

    require("dbclient.fixture").extract({
      schema = qualified[1],
      table = qualified[2],
      pk = pk,
      children = args.bang,
    })
  end, {
    nargs = "+",
    bang = true,
    force = true,
    desc = "Extract a row and its dependencies as INSERTs (! also pulls children)",
  })

  command("DBClientHypoIndex", function(args)
    require("dbclient.hypo").prompt({ sql = args.args ~= "" and args.args or nil })
  end, { nargs = "*", force = true, desc = "Test an index without building it" })

  command("DBClientTail", function(args)
    require("dbclient.cdc").start({ filter = args.args ~= "" and args.args or nil })
  end, { nargs = "?", force = true, desc = "Follow committed changes" })

  command("DBClientTailStop", function()
    require("dbclient.cdc").stop_all()
  end, { force = true, desc = "Stop following changes" })

  command("DBClientTailCheck", function()
    require("dbclient.cdc").diagnose()
  end, { force = true, desc = "Explain what change streaming needs here" })

  command("DBClientHelp", function()
    require("dbclient.ui.help").show_all()
  end, { force = true })

  command("DBClientPalette", function()
    require("dbclient.ui.help").show_palette()
  end, { force = true, desc = "Show the generated palette and its contrast ratios" })

  command("DBClientMigrationReview", function(args)
    require("dbclient.migration").review({ path = args.args ~= "" and args.args or nil })
  end, {
    nargs = "?",
    complete = "file",
    force = true,
    desc = "What this migration will lock, and for how long",
  })

  command("DBClientSchemaDump", function(args)
    local parts = vim.split(args.args, "%s+")
    require("dbclient.schemafiles").dump_command({
      dir = parts[1] ~= "" and parts[1] or nil,
      schema = parts[2],
      prune = not args.bang,
    })
  end, {
    nargs = "*",
    bang = true,
    complete = "dir",
    force = true,
    desc = "Write the schema out as one .sql file per object (! keeps stale files)",
  })

  command("DBClientSchemaDrift", function(args)
    local parts = vim.split(args.args, "%s+")
    require("dbclient.schemafiles").drift_command({
      dir = parts[1] ~= "" and parts[1] or nil,
      schema = parts[2],
    })
  end, {
    nargs = "*",
    complete = "dir",
    force = true,
    desc = "Compare the live schema against the committed one",
  })

  command("DBClientReplace", function(args)
    -- `:DBClientReplace 'old text' 'new text'`, quoted because the strings
    -- being replaced usually contain spaces.
    local parsed = {}
    for quoted in args.args:gmatch("'([^']*)'") do
      table.insert(parsed, quoted)
    end
    if #parsed == 0 then
      for word in args.args:gmatch("%S+") do
        table.insert(parsed, word)
      end
    end
    require("dbclient.replace").open({ needle = parsed[1], replacement = parsed[2] })
  end, {
    nargs = "*",
    force = true,
    desc = "Find and replace across every text column in the schema",
  })

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
      -- Capture before tearing down, so there is something to capture.
      pcall(function()
        require("dbclient.workspace").save()
      end)
      require("dbclient.watch").stop_all()
      -- A replication slot left behind holds WAL forever.
      pcall(function()
        require("dbclient.cdc").stop_all()
      end)
      session.disconnect_all()
      client.stop()
    end,
  })

  -- The palette is derived from the colourscheme's own background, so it has
  -- to be rebuilt whenever that background changes underneath it.
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = highlights.setup,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = { "background", "termguicolors" },
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
    watch = function()
      vim.ui.input({ prompt = "watch sql " }, function(sql)
        if sql and sql:match("%S") then
          require("dbclient.watch").start({ sql = sql })
        end
      end)
    end,
    profile = function()
      vim.ui.input({ prompt = "profile sql " }, function(sql)
        if sql and sql:match("%S") then
          require("dbclient.watch").profile({ sql = sql })
        end
      end)
    end,
    broadcast = function()
      require("dbclient.broadcast").prompt()
    end,
    notebook = function()
      require("dbclient.notebook").enable()
    end,
    undo_log = function()
      require("dbclient.undolog").open()
    end,
    diagram = function()
      local target = session.current()
      if not target then
        return notify("no active connection", vim.log.levels.WARN)
      end
      client.async(function()
        local schemas = session.schemas(target.id)
        local names = vim.tbl_map(function(entry)
          return entry.name
        end, schemas)
        vim.ui.select(names, { prompt = "diagram for schema" }, function(schema)
          if schema then
            require("dbclient.diagram").show({ session_id = target.id, schema = schema })
          end
        end)
      end, function(err)
        notify(err, vim.log.levels.ERROR)
      end)
    end,
    import = function()
      pickers.objects_for(function(choice)
        require("dbclient.import").prompt({
          session_id = choice.session_id,
          schema = choice.schema,
          table = choice.table,
        })
      end)
    end,
    scratch = function()
      require("dbclient.ui.scratch").toggle()
    end,
    saved_queries = function()
      require("dbclient.ui.queries").open()
    end,
    save_query = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local bound = query().buffers[bufnr]
      local target = bound and session.get(bound.session_id) or session.current()
      require("dbclient.queries").prompt_save({
        sql = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"),
        connection = target and target.name,
      })
    end,
    trail_back = function()
      require("dbclient.trail").back()
    end,
    trail_forward = function()
      require("dbclient.trail").forward()
    end,
    join_builder = function()
      require("dbclient.joins").prompt()
    end,
    audit = function()
      require("dbclient.audit").prompt()
    end,
    chart = function()
      require("dbclient.chart").pick_and_show()
    end,
    blast_radius = function()
      query().blast_radius()
    end,
    export = function()
      local view = require("dbclient.ui.results").view()
      if view then
        return require("dbclient.export.ui").open({
          session_id = view.session_id,
          sql = view.sql,
        })
      end
      pickers.objects_for(function(choice)
        require("dbclient.export.ui").open({
          session_id = choice.session_id,
          schema = choice.schema,
          table = choice.table,
        })
      end)
    end,
    fixture = function()
      require("dbclient.fixture").from_cursor()
    end,
    hypothetical_index = function()
      require("dbclient.hypo").prompt()
    end,
    tail = function()
      require("dbclient.cdc").start()
    end,
    migration_review = function()
      require("dbclient.migration").review()
    end,
    schema_dump = function()
      require("dbclient.schemafiles").dump_command()
    end,
    schema_drift = function()
      require("dbclient.schemafiles").drift_command()
    end,
    replace_in_schema = function()
      require("dbclient.replace").open()
    end,
    compare = function()
      vim.ui.select({
        "compare with a saved snapshot",
        "run on two connections and compare",
      }, { prompt = "compare" }, function(choice)
        if choice == "compare with a saved snapshot" then
          require("dbclient.snapshot").diff_with_saved()
        elseif choice then
          require("dbclient.snapshot").diff_connections()
        end
      end)
    end,
  }
end

---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
  require("dbclient.ui.grid").use_style(config.get().ui.grid_style)
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

--- The SQL query buffer.
---
--- An ordinary `sql` buffer, so treesitter, snippets and the user's own
--- mappings all apply. What DBClient adds is statement detection that survives
--- string literals and `DELIMITER`, asynchronous execution, inline diagnostics
--- and hover backed by the cached schema.

local buffer = require("dbclient.ui.buffer")
local client = require("dbclient.core.client")
local config = require("dbclient.config")
local help = require("dbclient.ui.help")
local highlights = require("dbclient.ui.highlights")
local keymap = require("dbclient.keymap")
local results = require("dbclient.ui.results")
local session = require("dbclient.session")
local window = require("dbclient.ui.window")
local winbar = require("dbclient.ui.winbar")

local M = {
  --- bufnr -> { session_id }
  buffers = {},
}

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------------
-- Offsets
-- ---------------------------------------------------------------------------

--- Byte offset of the cursor within the buffer.
---@param bufnr integer
---@return integer
function M.cursor_offset(bufnr)
  local position = vim.api.nvim_win_get_cursor(0)
  local before = vim.api.nvim_buf_get_lines(bufnr, 0, position[1] - 1, false)
  local offset = 0
  for _, line in ipairs(before) do
    offset = offset + #line + 1
  end
  return offset + position[2]
end

--- Convert a byte offset to a 0-based `(line, column)` pair.
---@param bufnr integer
---@param offset integer
---@return integer line, integer column
function M.offset_to_position(bufnr, offset)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local consumed = 0
  for index, line in ipairs(lines) do
    local length = #line + 1
    if consumed + length > offset then
      return index - 1, offset - consumed
    end
    consumed = consumed + length
  end
  return math.max(0, #lines - 1), 0
end

-- ---------------------------------------------------------------------------
-- Statement selection
-- ---------------------------------------------------------------------------

--- Text currently selected in visual mode, if any.
---@return string|nil
local function visual_selection()
  local mode = vim.fn.mode()
  if not mode:match("[vV\22]") then
    return nil
  end

  local start_position = vim.fn.getpos("v")
  local end_position = vim.fn.getpos(".")
  if start_position[2] > end_position[2] then
    start_position, end_position = end_position, start_position
  end

  local lines = vim.api.nvim_buf_get_lines(0, start_position[2] - 1, end_position[2], false)
  if #lines == 0 then
    return nil
  end
  if mode == "v" then
    lines[#lines] = lines[#lines]:sub(1, end_position[3])
    lines[1] = lines[1]:sub(start_position[3])
  end
  return table.concat(lines, "\n")
end

--- The SQL that `execute` would run: the selection, or the statement at the
--- cursor as determined by the core's splitter.
--- Must run inside `client.async`.
---@param bufnr integer
---@return string|nil sql, table|nil statement
function M.sql_at_cursor(bufnr)
  local selection = visual_selection()
  if selection and selection:match("%S") then
    return selection, nil
  end

  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  if not text:match("%S") then
    return nil, nil
  end

  local response = client.call("statement-at", { sql = text, offset = M.cursor_offset(bufnr) })
  local statement = response.statement
  if not statement then
    return nil, nil
  end
  return statement.text, statement
end

-- ---------------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------------

--- Ask before running something irreversible.
---
--- Runs inside a coroutine and yields until the user answers, so the caller
--- reads as straight-line code.
---@param sql string
---@param target table  the session
---@return boolean proceed
local function guarded(sql, target)
  local settings = config.get().guard
  local diagnostics = client.call("lint-sql", { sql = sql }).diagnostics or {}

  local blocking = {}
  for _, diagnostic in ipairs(diagnostics) do
    if diagnostic.code == "unfiltered-write" and settings.confirm_unfiltered_writes then
      table.insert(blocking, diagnostic.message)
    elseif diagnostic.code == "destructive" and settings.confirm_destructive then
      table.insert(blocking, diagnostic.message)
    end
  end

  local access = target.spec and target.spec.access or "write"
  if access == "read" then
    return true -- the core will refuse it anyway, with a clearer message
  end

  local co = coroutine.running()
  local blast = require("dbclient.blast")

  -- Ask what the statement would touch. A single-row update goes straight
  -- through; anything wider, unfiltered or destructive gets shown first.
  local report = { supported = false }
  if settings.preview_writes_over ~= false then
    local ok, response = pcall(blast.inspect, target.id, sql)
    if ok then
      report = response
    end
  end

  if report.supported and blast.should_confirm(report, blocking) then
    vim.schedule(function()
      blast.confirm({
        session_id = target.id,
        sql = sql,
        connection = target.name,
        warnings = blocking,
        on_decide = function(proceed)
          coroutine.resume(co, proceed)
        end,
      })
    end)
    return coroutine.yield()
  end

  if #blocking == 0 then
    return true
  end

  local prompt = table.concat(blocking, "; ")
  local needs_name = vim.tbl_contains(settings.typed_confirmation_for, access)
    and target.spec
    and target.spec.color ~= nil

  vim.schedule(function()
    if needs_name then
      vim.ui.input({
        prompt = ("%s on `%s`. Type the connection name to confirm: "):format(prompt, target.name),
      }, function(input)
        coroutine.resume(co, input == target.name)
      end)
    else
      vim.ui.select({ "no", "yes" }, { prompt = prompt .. ". Run it?" }, function(choice)
        coroutine.resume(co, choice == "yes")
      end)
    end
  end)

  return coroutine.yield()
end

-- ---------------------------------------------------------------------------
-- Execution
-- ---------------------------------------------------------------------------

local function session_for(bufnr)
  local bound = M.buffers[bufnr]
  local target = bound and session.get(bound.session_id) or session.current()
  if not target then
    notify("no active connection; run :DBClientConnect", vim.log.levels.WARN)
    return nil
  end
  return target
end

--- Build the `on_error` handler for a query buffer.
---
--- Everything a good error message needs that the core cannot know: which
--- buffer, its full text, and where in that text the failing statement began.
--- With those three the server's character offset becomes a line and a column
--- in the file the user is looking at.
---@param bufnr integer
---@param target table|nil
---@param locate fun(): table|nil  the statement, once it is known
---@return fun(err: string, detail: table|nil)
local function on_failure(bufnr, target, locate)
  return function(err, detail)
    local statement = locate and locate() or nil
    require("dbclient.errors").handle(err, detail, {
      bufnr = bufnr,
      source = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"),
      statement_offset = statement and statement.start,
      session_id = target and target.id,
      panel = true,
    })
  end
end

--- Run the statement at the cursor.
function M.execute()
  local bufnr = vim.api.nvim_get_current_buf()
  local target = session_for(bufnr)
  if not target then
    return
  end

  local located
  client.async(function()
    local sql, statement = M.sql_at_cursor(bufnr)
    located = statement
    if not sql or not sql:match("%S") then
      return notify("no SQL under the cursor", vim.log.levels.WARN)
    end
    if not guarded(sql, target) then
      return notify("cancelled")
    end

    require("dbclient.errors").clear_diagnostics(bufnr)
    local result = session.query(target.id, sql, config.get().ui.query_limit)
    results.show(result, { session_id = target.id, session_name = target.name, sql = sql })
    require("dbclient.history").record(target.name, sql)
  end, on_failure(bufnr, target, function()
    return located
  end))
end

--- Run every statement in the buffer, reporting one line per statement.
function M.execute_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local target = session_for(bufnr)
  if not target then
    return
  end

  local sql = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

  client.async(function()
    if not guarded(sql, target) then
      return notify("cancelled")
    end

    local statements = client.call("split-sql", { sql = sql }).statements or {}
    if #statements == 0 then
      return notify("nothing to run", vim.log.levels.WARN)
    end

    local report = {}
    local last_result
    for index, statement in ipairs(statements) do
      local ok, result = pcall(session.query, target.id, statement.text, config.get().ui.query_limit)
      if ok then
        last_result = result
        table.insert(
          report,
          ("%2d  %-8s %5d row(s)  %5d ms  %s"):format(
            index,
            statement.kind,
            #(result.rows or {}) > 0 and #result.rows or result.affected_rows,
            result.elapsed_ms,
            statement.text:gsub("%s+", " "):sub(1, 60)
          )
        )
      else
        table.insert(report, ("%2d  FAILED   %s"):format(index, tostring(result)))
        table.insert(report, "    " .. statement.text:gsub("%s+", " "):sub(1, 100))
        break
      end
    end

    if #statements == 1 and last_result then
      results.show(last_result, { session_id = target.id, session_name = target.name, sql = sql })
    else
      results.show({
        columns = { { name = "script", type = "text", class = "text" } },
        rows = vim.tbl_map(function(line)
          return { line }
        end, report),
        elapsed_ms = 0,
        affected_rows = 0,
      }, { session_id = target.id, session_name = target.name })
    end
    require("dbclient.history").record(target.name, sql)
  end, on_failure(bufnr, target, nil))
end

--- Show which rows the statement at the cursor would change.
function M.blast_radius()
  local bufnr = vim.api.nvim_get_current_buf()
  local target = session_for(bufnr)
  if not target then
    return
  end

  client.async(function()
    local sql = M.sql_at_cursor(bufnr)
    if not sql then
      return notify("no SQL under the cursor", vim.log.levels.WARN)
    end
    require("dbclient.blast").show({
      session_id = target.id,
      sql = sql,
      connection = target.name,
    })
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

---@param analyze boolean
function M.explain(analyze)
  local bufnr = vim.api.nvim_get_current_buf()
  local target = session_for(bufnr)
  if not target then
    return
  end

  local located
  client.async(function()
    local sql, statement = M.sql_at_cursor(bufnr)
    located = statement
    if not sql then
      return notify("no SQL under the cursor", vim.log.levels.WARN)
    end
    require("dbclient.ui.explain").show({
      session_id = target.id,
      sql = sql,
      analyze = analyze,
    })
  end, on_failure(bufnr, target, function()
    return located
  end))
end

-- ---------------------------------------------------------------------------
-- Diagnostics and hover
-- ---------------------------------------------------------------------------

--- Publish lint results as `vim.diagnostic` entries.
--- Execution errors are not handled here — `dbclient.errors` places those at
--- the position the server reported, which is the whole point of it.
---@param bufnr integer
function M.set_diagnostics(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

  local bound = M.buffers[bufnr]
  local target = bound and session.get(bound.session_id) or session.current()

  client.async(function()
    local response = client.call("lint-sql", { sql = text })
    local entries = vim.deepcopy(response.diagnostics or {})

    -- The static linter can only guess at names and types; the server knows.
    -- Preparing and discarding each statement is the cheapest way to ask.
    if target then
      local ok, server = pcall(
        client.call,
        "validate",
        { sql = text },
        target.id
      )
      if ok then
        vim.list_extend(entries, server.diagnostics or {})
      end
    end

    local severities = {
      error = vim.diagnostic.severity.ERROR,
      warn = vim.diagnostic.severity.WARN,
      hint = vim.diagnostic.severity.HINT,
    }

    local diagnostics = {}
    for _, entry in ipairs(entries) do
      local line, column = M.offset_to_position(bufnr, entry.start)
      local end_line, end_column = M.offset_to_position(bufnr, entry["end"])
      table.insert(diagnostics, {
        lnum = line,
        col = column,
        end_lnum = end_line,
        end_col = end_column,
        severity = severities[entry.severity] or vim.diagnostic.severity.INFO,
        message = entry.message,
        code = entry.code,
        source = "dbclient",
      })
    end

    vim.diagnostic.set(highlights.ns_diag, bufnr, diagnostics, {})
  end, function() end)
end

--- Identifier under the cursor, following `schema.table` and `table.column`.
---@return string|nil qualified
local function identifier_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local column = vim.api.nvim_win_get_cursor(0)[2] + 1

  local start_index = column
  while start_index > 1 and line:sub(start_index - 1, start_index - 1):match("[%w_.\"`]") do
    start_index = start_index - 1
  end
  local end_index = column
  while end_index < #line and line:sub(end_index + 1, end_index + 1):match("[%w_.\"`]") do
    end_index = end_index + 1
  end

  local word = line:sub(start_index, end_index):gsub('["`]', "")
  return word ~= "" and word or nil
end

--- Describe the table or column under the cursor.
function M.hover()
  local bufnr = vim.api.nvim_get_current_buf()
  local target = session_for(bufnr)
  if not target then
    return
  end

  local identifier = identifier_under_cursor()
  if not identifier then
    return notify("no identifier under the cursor", vim.log.levels.WARN)
  end

  client.async(function()
    local resolved = require("dbclient.completion").resolve(target.id, identifier)
    if not resolved then
      return notify(("nothing named `%s` in the cached schema"):format(identifier), vim.log.levels.WARN)
    end

    local lines = {}
    if resolved.kind == "table" then
      table.insert(lines, ("%s.%s  %s"):format(resolved.schema, resolved.table, resolved.info.kind or ""))
      if resolved.info.comment and resolved.info.comment ~= vim.NIL then
        table.insert(lines, tostring(resolved.info.comment))
      end
      table.insert(lines, "")
      local columns = session.columns(target.id, resolved.schema, resolved.table)
      local width = 0
      for _, column in ipairs(columns) do
        width = math.max(width, #column.name)
      end
      for _, column in ipairs(columns) do
        table.insert(
          lines,
          ("  %-" .. width .. "s  %s%s%s"):format(
            column.name,
            column.type,
            column.nullable and "" or " not null",
            column.key == "PRI" and "  PK" or ""
          )
        )
      end
      local estimated = resolved.info.estimated_rows
      if estimated and estimated >= 0 then
        table.insert(lines, "")
        table.insert(lines, ("~%d rows"):format(estimated))
      end
    else
      table.insert(lines, ("%s.%s.%s"):format(resolved.schema, resolved.table, resolved.column.name))
      table.insert(lines, ("type      %s"):format(resolved.column.type))
      table.insert(lines, ("nullable  %s"):format(tostring(resolved.column.nullable)))
      if resolved.column.default and resolved.column.default ~= vim.NIL then
        table.insert(lines, ("default   %s"):format(resolved.column.default))
      end
      if resolved.column.comment and resolved.column.comment ~= vim.NIL then
        table.insert(lines, ("comment   %s"):format(resolved.column.comment))
      end
    end

    local float_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[float_buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
    vim.bo[float_buf].modifiable = false
    local winid = window.float(float_buf, {
      title = identifier,
      max_width = 0.7,
      max_height = 0.6,
      cursorline = false,
    })
    window.close_keys(float_buf, winid)
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

--- Open the DDL for the identifier under the cursor.
function M.goto_definition()
  local bufnr = vim.api.nvim_get_current_buf()
  local target = session_for(bufnr)
  if not target then
    return
  end

  local identifier = identifier_under_cursor()
  if not identifier then
    return
  end

  client.async(function()
    local resolved = require("dbclient.completion").resolve(target.id, identifier)
    if not resolved then
      return notify(("nothing named `%s`"):format(identifier), vim.log.levels.WARN)
    end
    vim.cmd("normal! m'")
    require("dbclient.ui.ddl").open({
      session_id = target.id,
      kind = "table",
      schema = resolved.schema,
      name = resolved.table,
    })
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

-- ---------------------------------------------------------------------------
-- Buffer management
-- ---------------------------------------------------------------------------

--- Open or focus a query buffer for a session.
---@param opts? { session_id?: string, sql?: string, split?: string }
function M.open(opts)
  opts = opts or {}
  local target = session.get(opts.session_id)
  if not target then
    notify("no active connection; run :DBClientConnect", vim.log.levels.WARN)
    return
  end

  local name = ("dbclient://%s/query.sql"):format(target.name)
  local bufnr = buffer.scratch(name, { modifiable = true, buftype = "" })
  local first = M.buffers[bufnr] == nil
  M.buffers[bufnr] = { session_id = target.id }

  vim.bo[bufnr].filetype = "sql"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"

  buffer.show(bufnr, opts.split or "vsplit", { reuse_empty = true })
  winbar.bind(bufnr, target.id)

  if first then
    M.attach(bufnr)
    local existing = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if #existing == 1 and existing[1] == "" then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        ("-- @conn: %s"):format(target.name),
        "",
      })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
    end
  end

  if opts.sql and opts.sql ~= "" then
    local count = vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, count, count, false, vim.split(opts.sql, "\n"))
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(bufnr), 0 })
  end

  return bufnr
end

function M.attach(bufnr)
  keymap.apply("query", bufnr, {
    execute = M.execute,
    execute_buffer = M.execute_buffer,
    explain = function()
      M.explain(false)
    end,
    explain_analyze = function()
      M.explain(true)
    end,
    hover = M.hover,
    goto_definition = M.goto_definition,
    blast_radius = function()
      M.blast_radius()
    end,
    save = function()
      local bound = M.buffers[bufnr]
      local target = bound and session.get(bound.session_id) or session.current()
      require("dbclient.queries").prompt_save({
        sql = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"),
        connection = target and target.name,
      })
    end,
    saved_queries = function()
      local bound = M.buffers[bufnr]
      require("dbclient.ui.queries").open({ session_id = bound and bound.session_id })
    end,
    help = help.handler("query"),
  })

  vim.bo[bufnr].omnifunc = "v:lua.require'dbclient.completion'.omnifunc"

  local timer = nil
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    buffer = bufnr,
    callback = function()
      if timer then
        timer:stop()
        timer:close()
      end
      timer = vim.uv.new_timer()
      timer:start(
        400,
        0,
        vim.schedule_wrap(function()
          M.set_diagnostics(bufnr)
          if timer then
            timer:stop()
            timer:close()
            timer = nil
          end
        end)
      )
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      M.buffers[bufnr] = nil
    end,
  })
end

--- Bind a buffer to a specific connection, honouring `-- @conn: name`.
---@param bufnr integer
function M.detect_binding(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 10, false)
  for _, line in ipairs(lines) do
    local name = line:match("^%s*%-%-%s*@conn:%s*([%w_%-.:]+)")
    if name then
      local target = session.find_by_name(name)
      if target then
        M.buffers[bufnr] = { session_id = target.id }
        winbar.bind(bufnr, target.id)
      end
      return name
    end
  end
end

return M

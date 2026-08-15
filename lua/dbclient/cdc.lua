--- `tail -f` for a table.
---
--- Watching what an application actually writes — during a test, a migration or
--- an incident — normally means adding logging to the application. The database
--- already knows: PostgreSQL through a logical replication slot, MySQL and
--- MariaDB through the binary log. Both stream changes as they are committed.
---
--- This needs cooperation from the server (`wal_level = logical`, or row-format
--- binary logging) and a client binary that ships with each database. When
--- either is missing the check says exactly what to change rather than failing
--- obscurely, because "it does not work" is the least useful possible answer
--- for a feature with this many prerequisites.

local buffer = require("dbclient.ui.buffer")
local client = require("dbclient.core.client")
local connections = require("dbclient.connections")
local highlights = require("dbclient.ui.highlights")
local session = require("dbclient.session")

local M = {
  --- session id -> stream
  streams = {},
}

local MAX_LINES = 5000

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------------
-- Capability
-- ---------------------------------------------------------------------------

--- Can this connection stream changes, and if not, why not.
--- Must run inside `client.async`.
---@param session_id string
---@return { ok: boolean, reason?: string, fix?: string[], adapter: string }
function M.check(session_id)
  local target = session.require_session(session_id)
  local adapter = target.spec.adapter

  if adapter == "sqlite" then
    return {
      ok = false,
      adapter = adapter,
      reason = "SQLite has no replication log to follow",
      fix = { "Use :DBClientWatch to re-run a query on a timer instead." },
    }
  end

  if adapter == "postgres" then
    if vim.fn.executable("pg_recvlogical") ~= 1 then
      return {
        ok = false,
        adapter = adapter,
        reason = "pg_recvlogical is not on PATH",
        fix = { "Install the PostgreSQL client tools (postgresql-client)." },
      }
    end

    local ok, result = pcall(session.query, session_id, "show wal_level")
    local level = ok and result.rows[1] and result.rows[1][1] or "?"
    if level ~= "logical" then
      return {
        ok = false,
        adapter = adapter,
        reason = ("wal_level is `%s`; logical decoding needs `logical`"):format(level),
        fix = {
          "ALTER SYSTEM SET wal_level = 'logical';",
          "then restart the server (this setting needs a restart).",
        },
      }
    end

    local slots_ok, slots = pcall(
      session.query,
      session_id,
      "select current_setting('max_replication_slots')::int - count(*) from pg_replication_slots"
    )
    if slots_ok and slots.rows[1] and tonumber(slots.rows[1][1]) or 1 <= 0 then
      return {
        ok = false,
        adapter = adapter,
        reason = "no replication slots are free",
        fix = { "Raise max_replication_slots, or drop an unused slot." },
      }
    end

    return { ok = true, adapter = adapter }
  end

  if adapter == "mariadb" or adapter == "mysql" then
    if vim.fn.executable("mysqlbinlog") ~= 1 and vim.fn.executable("mariadb-binlog") ~= 1 then
      return {
        ok = false,
        adapter = adapter,
        reason = "mysqlbinlog / mariadb-binlog is not on PATH",
        fix = { "Install the MySQL or MariaDB client tools." },
      }
    end

    local ok, result = pcall(session.query, session_id, "select @@log_bin, @@binlog_format")
    if not ok or not result.rows[1] then
      return { ok = false, adapter = adapter, reason = "could not read the binlog settings" }
    end

    local enabled = tostring(result.rows[1][1])
    local format = tostring(result.rows[1][2])
    if enabled ~= "1" and enabled:upper() ~= "ON" then
      return {
        ok = false,
        adapter = adapter,
        reason = "binary logging is off",
        fix = { "Start the server with --log-bin, then restart it." },
      }
    end
    if format:upper() ~= "ROW" then
      return {
        ok = false,
        adapter = adapter,
        reason = ("binlog_format is %s; row images need ROW"):format(format),
        fix = { "SET GLOBAL binlog_format = 'ROW';" },
      }
    end

    return { ok = true, adapter = adapter }
  end

  return { ok = false, adapter = adapter, reason = "this adapter has no change stream" }
end

-- ---------------------------------------------------------------------------
-- Parsing
-- ---------------------------------------------------------------------------

--- Turn one line of `test_decoding` output into an event.
---
--- The format is stable and human-readable, and it ships with PostgreSQL, so
--- it needs no extension the user has to install first:
---   `table public.users: INSERT: id[integer]:1 name[text]:'a'`
---@param line string
---@return { kind: string, table?: string, operation?: string, detail?: string }|nil
function M.parse_postgres(line)
  local transaction = line:match("^BEGIN (%d+)") or line:match("^COMMIT (%d+)")
  if transaction then
    return {
      kind = line:match("^BEGIN") and "begin" or "commit",
      detail = transaction,
    }
  end

  local qualified, operation, rest = line:match("^table ([%w_.\"]+): (%u+): (.*)$")
  if qualified then
    return {
      kind = "row",
      table = qualified:gsub('"', ""),
      operation = operation:lower(),
      detail = rest,
    }
  end

  if line:match("%S") then
    return { kind = "other", detail = line }
  end
  return nil
end

--- Turn `mysqlbinlog --verbose` output into an event.
---
--- Row images arrive as `### INSERT INTO `db`.`t`` followed by `###   @1=…`
--- lines, so the statement line names the table and the following lines carry
--- the values.
---@param line string
---@return table|nil
function M.parse_mysql(line)
  local operation, qualified = line:match("^### (%u+)%s+INTO%s+(.+)$")
  if not operation then
    operation, qualified = line:match("^### (%u+)%s+FROM%s+(.+)$")
  end
  if not operation then
    operation, qualified = line:match("^### (%u+)%s+(.+)$")
    if operation and operation ~= "UPDATE" then
      operation = nil
    end
  end

  if operation and qualified then
    return {
      kind = "row",
      table = qualified:gsub("`", ""):gsub("%s+$", ""),
      operation = operation:lower(),
    }
  end

  local value = line:match("^###%s+(@%d+=.*)$")
  if value then
    return { kind = "value", detail = value }
  end

  if line:match("^BEGIN") then
    return { kind = "begin" }
  end
  if line:match("^COMMIT") then
    return { kind = "commit" }
  end
  return nil
end

--- Render an event as a buffer line.
---@param event table
---@return string|nil text, string|nil highlight
function M.format(event)
  if event.kind == "begin" then
    return ("── begin %s"):format(event.detail or ""), "DBClientSeparator"
  end
  if event.kind == "commit" then
    return ("── commit %s"):format(event.detail or ""), "DBClientSeparator"
  end
  if event.kind == "row" then
    local group = ({
      insert = "DBClientPendingAdd",
      update = "DBClientPending",
      delete = "DBClientPendingDelete",
    })[event.operation] or "DBClientColumn"
    return (
      "%-6s %-28s %s"):format(
      event.operation:upper(),
      event.table or "",
      event.detail or ""
    ),
      group
  end
  if event.kind == "value" then
    return "       " .. (event.detail or ""), "DBClientHelpText"
  end
  if event.kind == "other" then
    return "  " .. event.detail, "DBClientHelpText"
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Streaming
-- ---------------------------------------------------------------------------

local function append(stream, lines)
  if not vim.api.nvim_buf_is_valid(stream.bufnr) then
    return
  end

  local count = vim.api.nvim_buf_line_count(stream.bufnr)
  vim.bo[stream.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(stream.bufnr, count, count, false, lines)

  -- Keep the buffer bounded; a busy database produces a lot of these.
  local total = vim.api.nvim_buf_line_count(stream.bufnr)
  if total > MAX_LINES then
    vim.api.nvim_buf_set_lines(stream.bufnr, 0, total - MAX_LINES, false, {})
  end
  vim.bo[stream.bufnr].modifiable = false
  vim.bo[stream.bufnr].modified = false

  -- Follow the tail, unless the user has scrolled up to read something.
  for _, win in ipairs(buffer.windows(stream.bufnr)) do
    local cursor = vim.api.nvim_win_get_cursor(win)
    if cursor[1] >= total - #lines - 2 then
      pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(stream.bufnr), 0 })
    end
  end
end

--- Feed raw output through the parser and into the buffer.
local function consume(stream, chunk)
  stream.partial = (stream.partial or "") .. chunk
  local lines = {}

  while true do
    local newline = stream.partial:find("\n", 1, true)
    if not newline then
      break
    end
    local line = stream.partial:sub(1, newline - 1):gsub("\r$", "")
    stream.partial = stream.partial:sub(newline + 1)

    local event = stream.parse(line)
    if event then
      if stream.filter and event.kind == "row" then
        local name = (event.table or ""):lower()
        if not name:find(stream.filter:lower(), 1, true) then
          event = nil
        end
      end
      if event then
        local text = M.format(event)
        if text then
          table.insert(lines, text)
          stream.events = stream.events + 1
        end
      end
    end
  end

  if #lines > 0 then
    vim.schedule(function()
      append(stream, lines)
    end)
  end
end

--- Stop a stream and clean up its slot.
---@param session_id string
function M.stop(session_id)
  local stream = M.streams[session_id]
  if not stream then
    return
  end
  M.streams[session_id] = nil

  if stream.handle then
    pcall(function()
      stream.handle:kill(15)
    end)
  end

  -- A replication slot left behind holds WAL forever, which is a real way to
  -- fill a production disk. Dropping it is not optional.
  if stream.slot then
    client.async(function()
      pcall(
        session.query,
        session_id,
        ("select pg_drop_replication_slot('%s')"):format(stream.slot)
      )
    end, function() end)
  end

  notify(("stopped following changes (%d event(s))"):format(stream.events or 0))
end

--- Start following changes.
---@param opts { session_id?: string, filter?: string }
function M.start(opts)
  opts = opts or {}
  local target = session.get(opts.session_id)
  if not target then
    return notify("no active connection", vim.log.levels.WARN)
  end
  if M.streams[target.id] then
    return notify("already following changes; q in the buffer stops it")
  end

  client.async(function()
    local capability = M.check(target.id)
    if not capability.ok then
      local lines = { capability.reason or "change streaming is not available" }
      for _, fix in ipairs(capability.fix or {}) do
        table.insert(lines, "  " .. fix)
      end
      return notify(table.concat(lines, "\n"), vim.log.levels.WARN)
    end

    local spec = target.spec
    connections.resolve_password(target.name, spec, function(password)
      local command, slot, parse

      if capability.adapter == "postgres" then
        slot = ("dbclient_%d"):format(os.time() % 100000)
        parse = M.parse_postgres
        command = {
          "pg_recvlogical",
          "--host=" .. (spec.host or "127.0.0.1"),
          "--port=" .. tostring(spec.port or 5432),
          "--username=" .. (spec.user or "postgres"),
          "--dbname=" .. (spec.database or "postgres"),
          "--slot=" .. slot,
          "--plugin=test_decoding",
          "--create-slot",
          "--start",
          "--file=-",
          "--no-password",
        }
      else
        parse = M.parse_mysql
        local binary = vim.fn.executable("mysqlbinlog") == 1 and "mysqlbinlog" or "mariadb-binlog"
        -- The first log file is where to start; `--stop-never` then follows.
        local logs = session.query(target.id, "show binary logs")
        local first = logs.rows[1] and logs.rows[1][1] or "mysql-bin.000001"
        command = {
          binary,
          "--read-from-remote-server",
          "--host=" .. (spec.host or "127.0.0.1"),
          "--port=" .. tostring(spec.port or 3306),
          "--user=" .. (spec.user or "root"),
          "--stop-never",
          "--base64-output=DECODE-ROWS",
          "--verbose",
          first,
        }
      end

      local bufnr = buffer.scratch(("dbclient://%s/changes"):format(target.name), {
        modifiable = false,
      })
      vim.bo[bufnr].filetype = "dbclient-changes"
      buffer.set_lines(bufnr, {
        ("following changes on %s (%s)"):format(target.name, capability.adapter),
        opts.filter and ("filter: " .. opts.filter) or "q stops   gf filters by table   gc clears",
        "",
      })
      buffer.show(bufnr, "botright 18split")
      require("dbclient.ui.winbar").bind(bufnr, target.id)

      local stream = {
        bufnr = bufnr,
        slot = slot,
        parse = parse,
        filter = opts.filter,
        events = 0,
        partial = "",
      }
      M.streams[target.id] = stream

      local environment = vim.deepcopy(vim.uv.os_environ())
      if password then
        -- Both tools read the password from the environment, which keeps it off
        -- the process command line where anyone could read it.
        environment.PGPASSWORD = password
        environment.MYSQL_PWD = password
      end

      local ok, handle = pcall(vim.system, command, {
        env = environment,
        stdout = function(err, data)
          if not err and data then
            consume(stream, data)
          end
        end,
        stderr = function(err, data)
          if not err and data and data:match("%S") then
            vim.schedule(function()
              append(stream, vim.tbl_map(function(line)
                return "! " .. line
              end, vim.split(vim.trim(data), "\n")))
            end)
          end
        end,
      }, function(result)
        vim.schedule(function()
          if M.streams[target.id] then
            append(stream, { ("── stream ended (exit %s)"):format(result.code) })
            M.stop(target.id)
          end
        end)
      end)

      if not ok then
        M.streams[target.id] = nil
        return notify("could not start the stream: " .. tostring(handle), vim.log.levels.ERROR)
      end
      stream.handle = handle

      vim.keymap.set("n", "q", function()
        M.stop(target.id)
        buffer.hide(bufnr)
      end, { buffer = bufnr, silent = true, nowait = true, desc = "DBClient: stop following" })

      vim.keymap.set("n", "gc", function()
        buffer.set_lines(bufnr, { "cleared", "" })
      end, { buffer = bufnr, silent = true, desc = "DBClient: clear" })

      vim.keymap.set("n", "gf", function()
        vim.ui.input({ prompt = "only this table ", default = stream.filter or "" }, function(value)
          stream.filter = value ~= "" and value or nil
          notify(stream.filter and ("filtering on " .. stream.filter) or "filter cleared")
        end)
      end, { buffer = bufnr, silent = true, desc = "DBClient: filter by table" })

      vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = bufnr,
        callback = function()
          M.stop(target.id)
        end,
      })

      notify("following changes; q stops and drops the slot")
    end)
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

--- Explain what this connection would need.
function M.diagnose()
  local target = session.current()
  if not target then
    return notify("no active connection", vim.log.levels.WARN)
  end

  client.async(function()
    local capability = M.check(target.id)
    local lines = {
      ("change streaming on %s (%s)"):format(target.name, capability.adapter),
      "",
    }
    if capability.ok then
      table.insert(lines, "available — :DBClientTail starts it")
    else
      table.insert(lines, "unavailable: " .. (capability.reason or "unknown"))
      if capability.fix then
        table.insert(lines, "")
        for _, fix in ipairs(capability.fix) do
          table.insert(lines, "  " .. fix)
        end
      end
    end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    local winid = require("dbclient.ui.window").float(bufnr, { title = "change stream" })
    highlights.lines(bufnr, {
      { line = 0, group = "DBClientHeader" },
      { line = 2, group = capability.ok and "DBClientPlanCheap" or "DBClientPlanHot" },
    })
    require("dbclient.ui.window").close_keys(bufnr, winid)
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

function M.stop_all()
  for session_id in pairs(vim.deepcopy(M.streams)) do
    M.stop(session_id)
  end
end

return M

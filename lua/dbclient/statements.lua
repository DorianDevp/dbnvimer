--- What this server has actually been running, and how that has changed.
---
--- The activity monitor answers "what is happening now". This answers "what
--- has been happening", which is the question behind every performance
--- complaint and the one a live view cannot reach. Both servers keep the
--- answer already: PostgreSQL in `pg_stat_statements`, MySQL and MariaDB in
--- `performance_schema.events_statements_summary_by_digest`. Each row is one
--- normalised statement with its call count, its total time and its rows —
--- the whole workload, aggregated by the server, for free.
---
--- Two things follow from having it:
---
---   **Ranked.** Sorting by total time rather than by average is what finds
---   the statement that runs in four milliseconds eighty thousand times an
---   hour, which no slow-query threshold ever catches.
---
---   **Compared.** The digest is a stable fingerprint, so a snapshot taken
---   today can be compared with one from last week and the answer is "this got
---   eleven times slower and the plan changed", not "the database feels slow".
---
--- When the server is not collecting any of it, that is what this says, and
--- how to turn it on. MariaDB ships with `performance_schema` off, so the
--- honest answer for a default install is a sentence rather than an empty
--- table.

local config = require("dbclient.config")
local session = require("dbclient.session")

local M = {}

--- Adapter family for a session.
---@param session_id string
---@return "mysql"|"postgres"|"sqlite"
local function family(session_id)
  local target = session.require_session(session_id)
  local adapter = tostring(target.info and target.info.adapter or ""):lower()
  if adapter:find("postgres") or adapter == "pg" then
    return "postgres"
  end
  if adapter:find("sqlite") then
    return "sqlite"
  end
  return "mysql"
end

--- Whether this server is MariaDB rather than MySQL, read from the version
--- string because the adapter is named `mariadb` for both.
---@param session_id string
---@return boolean
local function is_mariadb(session_id)
  local target = session.require_session(session_id)
  return tostring(target.info and target.info.server_version or ""):lower():find("mariadb") ~= nil
end

-- ---------------------------------------------------------------------------
-- Is the server collecting any of this
-- ---------------------------------------------------------------------------

--- Whether statement statistics are available, and what to do if not.
---
--- Runs on the coroutine.
---@param session_id string
---@return { available: boolean, source?: string, reason?: string, remedy?: string[] }
function M.availability(session_id)
  local kind = family(session_id)

  if kind == "sqlite" then
    return {
      available = false,
      reason = "SQLite keeps no statement statistics",
      remedy = {
        "There is nothing to enable: the engine does not aggregate what it has run.",
        "`<leader>dl` shows the statements DBClient itself executed.",
      },
    }
  end

  if kind == "postgres" then
    local installed = session.query(
      session_id,
      "select count(*) from pg_extension where extname = 'pg_stat_statements'"
    )
    -- Parenthesised: `or` binds looser than `>`, so without them this reads
    -- as `tonumber(...) or (0 > 0)` and a count of zero — a number, therefore
    -- truthy — would report the extension as installed.
    if (tonumber(installed.rows[1] and installed.rows[1][1]) or 0) > 0 then
      return { available = true, source = "pg_stat_statements" }
    end
    return {
      available = false,
      reason = "the pg_stat_statements extension is not installed",
      remedy = {
        "It has to be loaded at startup as well as created, in this order:",
        "  1. add `pg_stat_statements` to `shared_preload_libraries` in postgresql.conf",
        "  2. restart the server — this setting cannot be changed at runtime",
        "  3. `create extension pg_stat_statements;`",
        "The overhead is a few percent and it is the standard way to answer this.",
      },
    }
  end

  local enabled = session.query(session_id, "select @@performance_schema")
  if tostring(enabled.rows[1] and enabled.rows[1][1]) ~= "1" then
    return {
      available = false,
      reason = "performance_schema is off",
      remedy = is_mariadb(session_id)
          and {
            "MariaDB ships with it off, which is why a default install has nothing here.",
            "Add `performance_schema = ON` to my.cnf and restart — it cannot be",
            "changed at runtime. It costs some memory and a few percent of throughput.",
          }
        or {
          "Add `performance_schema = ON` to my.cnf and restart; it cannot be changed",
          "at runtime.",
        },
    }
  end

  local consumer = session.query(
    session_id,
    "select enabled from performance_schema.setup_consumers where name = 'statements_digest'"
  )
  local on = consumer.rows[1] and tostring(consumer.rows[1][1]):upper()
  if on and on ~= "YES" then
    return {
      available = false,
      reason = "performance_schema is on but the statements_digest consumer is not",
      remedy = {
        "This one *can* be changed at runtime:",
        "  update performance_schema.setup_consumers set enabled = 'YES'",
        "   where name = 'statements_digest';",
      },
    }
  end

  return { available = true, source = "performance_schema" }
end

-- ---------------------------------------------------------------------------
-- Reading it
-- ---------------------------------------------------------------------------

--- The statement digest table, ranked by total time.
---
--- Runs on the coroutine.
---@param session_id string
---@param opts? { limit?: integer, schema?: string }
---@return table[]
function M.collect(session_id, opts)
  opts = opts or {}
  local limit = opts.limit or 200
  local kind = family(session_id)

  local sql
  if kind == "postgres" then
    -- `total_exec_time` since PostgreSQL 13; `total_time` before it.
    local named = session.query(
      session_id,
      "select count(*) from information_schema.columns "
        .. "where table_name = 'pg_stat_statements' and column_name = 'total_exec_time'"
    )
    local modern = (tonumber(named.rows[1] and named.rows[1][1]) or 0) > 0
    sql = ([[
      select queryid::text, query, calls,
             %s, %s, rows
      from pg_stat_statements
      where calls > 0
      order by 4 desc
      limit %d
    ]]):format(
      modern and "total_exec_time" or "total_time",
      modern and "mean_exec_time" or "mean_time",
      limit
    )
  else
    -- The timers are in picoseconds.
    sql = ([[
      select digest, digest_text, count_star,
             sum_timer_wait / 1000000000, avg_timer_wait / 1000000000,
             sum_rows_sent, sum_rows_examined, sum_no_index_used,
             schema_name
      from performance_schema.events_statements_summary_by_digest
      where digest is not null
      order by sum_timer_wait desc
      limit %d
    ]]):format(limit)
  end

  local result = session.query(session_id, sql, limit)
  local rows = {}
  for _, row in ipairs(result.rows or {}) do
    local entry = {
      digest = tostring(row[1] or ""),
      text = tostring(row[2] or ""):gsub("%s+", " "),
      calls = tonumber(row[3]) or 0,
      total_ms = tonumber(row[4]) or 0,
      avg_ms = tonumber(row[5]) or 0,
      rows_sent = tonumber(row[6]) or 0,
    }
    if kind ~= "postgres" then
      entry.rows_examined = tonumber(row[7]) or 0
      entry.no_index = tonumber(row[8]) or 0
      entry.schema = row[9] ~= vim.NIL and tostring(row[9]) or nil
    end
    if opts.schema and entry.schema and entry.schema ~= opts.schema then
      entry = nil
    end
    if entry then
      table.insert(rows, entry)
    end
  end
  return rows
end

-- ---------------------------------------------------------------------------
-- Snapshots and comparison
-- ---------------------------------------------------------------------------

---@return string
local function directory()
  return vim.fs.dirname(config.get().history.path) .. "/statements"
end

--- Save the current digest table.
---@param opts { session_id: string, connection: string, label?: string }
---@return string path
function M.save(opts)
  local rows = M.collect(opts.session_id)
  vim.fn.mkdir(directory(), "p")

  local stamp = os.date("%Y%m%d-%H%M%S")
  local safe = tostring(opts.connection):gsub("[^%w%-_]", "_")
  local path = ("%s/%s-%s.json"):format(directory(), safe, stamp)

  local handle = assert(io.open(path, "w"))
  handle:write(vim.json.encode({
    connection = opts.connection,
    label = opts.label,
    taken_at = os.time(),
    rows = rows,
  }))
  handle:close()
  return path
end

--- Every saved snapshot, newest first.
---@param connection? string
---@return table[]
function M.snapshots(connection)
  local found = {}
  for _, path in ipairs(vim.fn.glob(directory() .. "/*.json", false, true)) do
    local handle = io.open(path, "r")
    if handle then
      local text = handle:read("*a")
      handle:close()
      local ok, decoded = pcall(vim.json.decode, text)
      if ok and (not connection or decoded.connection == connection) then
        decoded.path = path
        table.insert(found, decoded)
      end
    end
  end
  table.sort(found, function(a, b)
    return (a.taken_at or 0) > (b.taken_at or 0)
  end)
  return found
end

--- What changed between two readings.
---
--- The counters are cumulative since the server last reset them, so the
--- interesting number is the *difference* in total time divided by the
--- difference in calls: the average over the window between the two readings,
--- rather than the average since the server started, which a long-lived
--- process makes meaningless.
---@param before table[]
---@param after table[]
---@param opts? { min_calls?: integer, threshold?: number }
---@return { slower: table[], faster: table[], appeared: table[] }
function M.compare(before, after, opts)
  opts = opts or {}
  local min_calls = opts.min_calls or 5
  local threshold = opts.threshold or 1.5

  local previous = {}
  for _, row in ipairs(before) do
    previous[row.digest] = row
  end

  local slower, faster, appeared = {}, {}, {}

  for _, row in ipairs(after) do
    local was = previous[row.digest]
    if not was then
      if row.calls >= min_calls then
        table.insert(appeared, row)
      end
    else
      local calls = row.calls - was.calls
      local total = row.total_ms - was.total_ms
      -- A counter that went backwards means the server was restarted or the
      -- table was reset; there is nothing to compare and pretending otherwise
      -- would report every statement as new.
      if calls >= min_calls and total >= 0 then
        local window_avg = total / calls
        local entry = vim.tbl_extend("force", {}, row)
        entry.window_calls = calls
        entry.window_avg_ms = window_avg
        entry.was_avg_ms = was.avg_ms
        entry.ratio = was.avg_ms > 0 and (window_avg / was.avg_ms) or nil

        if entry.ratio and entry.ratio >= threshold then
          table.insert(slower, entry)
        elseif entry.ratio and entry.ratio <= 1 / threshold then
          table.insert(faster, entry)
        end
      end
    end
  end

  local function by_impact(a, b)
    return (a.window_avg_ms * a.window_calls) > (b.window_avg_ms * b.window_calls)
  end
  table.sort(slower, by_impact)
  table.sort(faster, by_impact)
  table.sort(appeared, function(a, b)
    return a.total_ms > b.total_ms
  end)

  return { slower = slower, faster = faster, appeared = appeared }
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- Milliseconds as something readable at a glance.
---@param ms number
---@return string
function M.duration(ms)
  if ms < 1 then
    return ("%.2f ms"):format(ms)
  end
  if ms < 1000 then
    return ("%.0f ms"):format(ms)
  end
  if ms < 60000 then
    return ("%.1f s"):format(ms / 1000)
  end
  if ms < 3600000 then
    return ("%.1f min"):format(ms / 60000)
  end
  return ("%.1f h"):format(ms / 3600000)
end

---@param count number
---@return string
function M.thousands(count)
  local text = tostring(math.floor(count))
  local out = text:reverse():gsub("(%d%d%d)", "%1 "):reverse()
  return (out:gsub("^%s+", ""))
end

--- Render the ranking.
---@param rows table[]
---@param opts { source: string, connection: string, width?: integer }
---@return string[] lines, table[] marks, table<integer, table> index
function M.render(rows, opts)
  local width = opts.width or 100
  local lines, marks, index = {}, {}, {}

  local function add(text, group, entry)
    table.insert(lines, text)
    if group then
      table.insert(marks, { line = #lines - 1, group = group })
    end
    if entry then
      index[#lines] = entry
    end
  end

  add(("%s   %d statement%s   via %s"):format(
    opts.connection,
    #rows,
    #rows == 1 and "" or "s",
    opts.source
  ), "DBClientHeader")
  add("")
  add(("%10s  %9s  %9s  %s"):format("calls", "total", "average", "statement"), "DBClientHeader")

  for _, row in ipairs(rows) do
    local text = row.text
    local room = width - 34
    if #text > room then
      text = text:sub(1, room - 1) .. "…"
    end

    add(
      ("%10s  %9s  %9s  %s"):format(
        M.thousands(row.calls),
        M.duration(row.total_ms),
        M.duration(row.avg_ms),
        text
      ),
      -- Anything examining far more rows than it returns is the shape of a
      -- missing index, and worth being able to see from across the room.
      (row.rows_examined and row.rows_sent and row.rows_sent > 0 and row.rows_examined
          > row.rows_sent * 100)
          and "DBClientPlanHot"
        or nil,
      row
    )
  end

  return lines, marks, index
end

--- Render a comparison.
---@param diff table
---@param opts { before: table, after: table, connection: string, width?: integer }
---@return string[] lines, table[] marks, table<integer, table> index
function M.render_comparison(diff, opts)
  local lines, marks, index = {}, {}, {}
  local width = opts.width or 100

  local function add(text, group, entry)
    table.insert(lines, text)
    if group then
      table.insert(marks, { line = #lines - 1, group = group })
    end
    if entry then
      index[#lines] = entry
    end
  end

  add(("%s   %s  →  now"):format(
    opts.connection,
    os.date("%Y-%m-%d %H:%M", opts.before.taken_at or 0)
  ), "DBClientHeader")
  add(("%d slower · %d faster · %d new"):format(
    #diff.slower,
    #diff.faster,
    #diff.appeared
  ), "DBClientHelpText")

  local function section(title, entries, group, show_ratio)
    if #entries == 0 then
      return
    end
    add("")
    add(title, "DBClientHeader")
    for _, row in ipairs(entries) do
      local text = row.text
      local room = width - 40
      if #text > room then
        text = text:sub(1, room - 1) .. "…"
      end
      if show_ratio then
        add(
          ("  %6.1f×  %9s → %9s  %s"):format(
            row.ratio,
            M.duration(row.was_avg_ms),
            M.duration(row.window_avg_ms),
            text
          ),
          group,
          row
        )
      else
        add(
          ("  %8s  %9s  %s"):format(M.thousands(row.calls), M.duration(row.total_ms), text),
          group,
          row
        )
      end
    end
  end

  section("slower", diff.slower, "DBClientPlanHot", true)
  section("faster", diff.faster, "DBClientSeverityOk", true)
  section("new since then", diff.appeared, "DBClientSeverityWarn", false)

  if #diff.slower == 0 and #diff.faster == 0 and #diff.appeared == 0 then
    add("")
    add("nothing moved by enough to mention", "DBClientSeverityOk")
  end

  return lines, marks, index
end

--- Render the explanation for a server that is not collecting anything.
---@param availability table
---@param connection string
---@return string[] lines, table[] marks
function M.render_unavailable(availability, connection)
  local lines = {
    ("%s is not keeping statement statistics"):format(connection),
    "",
    "  " .. (availability.reason or "unknown"),
    "",
  }
  local marks = {
    { line = 0, group = "DBClientSeverityWarn" },
    { line = 2, group = "DBClientHelpText" },
  }
  for _, line in ipairs(availability.remedy or {}) do
    table.insert(lines, "  " .. line)
    table.insert(marks, { line = #lines - 1, group = "DBClientHelpText" })
  end

  table.insert(lines, "")
  table.insert(lines, "  Until then, `<leader>dl` lists the statements DBClient itself ran.")
  table.insert(marks, { line = #lines - 1, group = "DBClientSeverityHint" })
  return lines, marks
end

-- ---------------------------------------------------------------------------
-- The buffer
-- ---------------------------------------------------------------------------

M.views = {}
M.ns = vim.api.nvim_create_namespace("dbclient-statements")

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

---@param bufnr integer
---@param lines string[]
---@param marks table[]
local function paint(bufnr, lines, marks)
  local buffer = require("dbclient.ui.buffer")
  buffer.set_lines(bufnr, lines)
  require("dbclient.ui.highlights").lines(bufnr, marks, M.ns)
end

--- Handlers for the `statements` mapping group.
---@param bufnr integer
---@return table<string, function>
function M.handlers(bufnr)
  local function row_here()
    local view = M.views[bufnr]
    return view and view.index[vim.api.nvim_win_get_cursor(0)[1]], view
  end

  return {
    open = function()
      local row, view = row_here()
      if not row then
        return
      end
      -- Not EXPLAIN: a digest has its literals stripped, so `where id = ?`
      -- would either fail to parse or, worse, plan for a value nobody used.
      -- The statement goes into a query buffer to have its parameters put
      -- back, which is the only honest thing to do with it.
      local query = require("dbclient.ui.query")
      query.open({ session_id = view.session_id })
      local target = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(target, 0, -1, false, {
        "-- from the statement digest; fill in the parameters before running it",
        ("-- %s calls, %s total, %s average"):format(
          M.thousands(row.calls),
          M.duration(row.total_ms),
          M.duration(row.avg_ms)
        ),
        "",
        row.text,
      })
    end,

    yank = function()
      local row = row_here()
      if row then
        vim.fn.setreg(vim.v.register or '"', row.text)
        notify("statement yanked")
      end
    end,

    snapshot = function()
      local view = M.views[bufnr]
      if not view then
        return
      end
      require("dbclient.core.client").async(function()
        local path = M.save({ session_id = view.session_id, connection = view.connection })
        notify("snapshot saved to " .. vim.fn.fnamemodify(path, ":~"))
      end, function(err)
        require("dbclient.errors").handle(err, nil, { session_id = view.session_id })
      end)
    end,

    compare = function()
      local view = M.views[bufnr]
      if not view then
        return
      end
      M.pick_comparison(view.session_id, view.connection)
    end,

    refresh = function()
      local view = M.views[bufnr]
      if view then
        M.open({ session_id = view.session_id, connection = view.connection })
      end
    end,

    close = function()
      vim.cmd("close")
    end,

    help = require("dbclient.ui.help").handler("statements"),
  }
end

--- Show the ranking, or why there is none.
---@param opts { session_id: string, connection: string }
function M.open(opts)
  local client = require("dbclient.core.client")
  local buffer = require("dbclient.ui.buffer")

  client.async(function()
    local availability = M.availability(opts.session_id)
    local bufnr = buffer.scratch("dbclient://statements", { filetype = "dbclient-statements" })

    if not availability.available then
      local lines, marks = M.render_unavailable(availability, opts.connection)
      M.views[bufnr] = { session_id = opts.session_id, connection = opts.connection, index = {} }
      paint(bufnr, lines, marks)
      buffer.show(bufnr, "botright split")
      require("dbclient.keymap").apply("statements", bufnr, M.handlers(bufnr))
      return
    end

    local rows = M.collect(opts.session_id)
    local lines, marks, index = M.render(rows, {
      source = availability.source,
      connection = opts.connection,
      width = vim.o.columns - 4,
    })

    M.views[bufnr] = {
      session_id = opts.session_id,
      connection = opts.connection,
      rows = rows,
      index = index,
    }
    paint(bufnr, lines, marks)
    buffer.show(bufnr, "botright split")
    vim.wo.wrap = false
    require("dbclient.keymap").apply("statements", bufnr, M.handlers(bufnr))
  end, function(err)
    require("dbclient.errors").handle(err, nil, { session_id = opts.session_id })
  end)
end

--- Choose a saved snapshot and compare the server against it.
---@param session_id string
---@param connection string
function M.pick_comparison(session_id, connection)
  local saved = M.snapshots(connection)
  if #saved == 0 then
    return notify(
      "no snapshots for this connection yet; press `s` to take one",
      vim.log.levels.WARN
    )
  end

  vim.ui.select(saved, {
    prompt = "compare against",
    format_item = function(entry)
      return ("%s  %d statement(s)%s"):format(
        os.date("%Y-%m-%d %H:%M", entry.taken_at or 0),
        #(entry.rows or {}),
        entry.label and ("  " .. entry.label) or ""
      )
    end,
  }, function(chosen)
    if not chosen then
      return
    end
    local client = require("dbclient.core.client")
    local buffer = require("dbclient.ui.buffer")

    client.async(function()
      local now = M.collect(session_id)
      local diff = M.compare(chosen.rows or {}, now)
      local lines, marks, index = M.render_comparison(diff, {
        before = chosen,
        after = { rows = now },
        connection = connection,
        width = vim.o.columns - 4,
      })

      local bufnr = buffer.scratch("dbclient://statements-diff", {
        filetype = "dbclient-statements",
      })
      M.views[bufnr] = {
        session_id = session_id,
        connection = connection,
        rows = now,
        index = index,
      }
      paint(bufnr, lines, marks)
      buffer.show(bufnr, "botright split")
      vim.wo.wrap = false
      require("dbclient.keymap").apply("statements", bufnr, M.handlers(bufnr))
    end, function(err)
      require("dbclient.errors").handle(err, nil, { session_id = session_id })
    end)
  end)
end

--- Entry point for the mapping and the command.
function M.prompt()
  local target = session.current()
  if not target then
    return notify("no active connection", vim.log.levels.WARN)
  end
  M.open({ session_id = target.id, connection = target.name })
end

return M

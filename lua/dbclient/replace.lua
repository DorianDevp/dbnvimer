--- Find and replace across a whole schema.
---
--- "The company changed its name" is a support task that currently means
--- opening each table in turn and hoping you remembered all of them. You never
--- do — there is always one more `note` column holding the old string inside a
--- longer sentence.
---
--- Two rules make this safe enough to offer:
---
---   Search and replace are separate steps, always. The search reports every
---   table and every row count first; nothing is written until the counts have
---   been seen and confirmed.
---
---   The replacement runs in one transaction, so a failure halfway through
---   leaves nothing behind. `access = "read"` refuses outright, and `sandbox`
---   rolls back — both enforced in the core rather than here.

local client = require("dbclient.core.client")
local session = require("dbclient.session")

local M = {}

--- Column types worth searching. A search across every `int` in the schema
--- would be slow and meaningless.
local TEXT_TYPES = {
  ["char"] = true,
  ["varchar"] = true,
  ["text"] = true,
  ["tinytext"] = true,
  ["mediumtext"] = true,
  ["longtext"] = true,
  ["character"] = true,
  ["character varying"] = true,
  ["citext"] = true,
  ["name"] = true,
}

-- ---------------------------------------------------------------------------
-- Dialect
-- ---------------------------------------------------------------------------

---@param adapter string|nil
---@return "mysql"|"postgres"|"sqlite"
local function family(adapter)
  adapter = tostring(adapter or ""):lower()
  if adapter:find("postgres") or adapter == "pg" then
    return "postgres"
  end
  if adapter:find("sqlite") then
    return "sqlite"
  end
  return "mysql"
end

--- Quote an identifier for the dialect.
---@param name string
---@param dialect string
---@return string
function M.quote_ident(name, dialect)
  if dialect == "mysql" then
    return "`" .. name:gsub("`", "``") .. "`"
  end
  return '"' .. name:gsub('"', '""') .. '"'
end

--- Quote a string literal. Doubling the quote is the one escape every dialect
--- agrees on; backslash escaping is not, so it is not used.
---@param text string
---@return string
function M.quote_literal(text)
  return "'" .. text:gsub("'", "''") .. "'"
end

--- A LIKE pattern matching `needle` anywhere, with its wildcards defanged.
---
--- Without this, searching for `100%` matches every row: the `%` is a wildcard,
--- not a character. The escape clause is stated explicitly because the default
--- differs between servers.
---@param needle string
---@return string clause_value, string escape_clause
function M.like_pattern(needle)
  local escaped = needle:gsub("([\\%%_])", "\\%1")
  return "%" .. escaped .. "%", " escape '\\'"
end

-- ---------------------------------------------------------------------------
-- Finding candidate columns
-- ---------------------------------------------------------------------------

--- Every text column in the schema, grouped by table.
---
--- Runs on the coroutine.
---@param opts { session_id: string, schema: string, tables?: string[] }
---@return table[]  `{ table = name, columns = { ... } }`
function M.text_columns(opts)
  local wanted
  if opts.tables and #opts.tables > 0 then
    wanted = {}
    for _, name in ipairs(opts.tables) do
      wanted[name:lower()] = true
    end
  end

  local groups = {}
  for _, entry in ipairs(session.tables(opts.session_id, opts.schema) or {}) do
    local name = entry.name
    local kind = tostring(entry.kind or ""):lower()
    -- Views are not writable and would produce findings nobody can act on.
    local is_view = kind:find("view") ~= nil
    if not is_view and (not wanted or wanted[tostring(name):lower()]) then
      local columns = {}
      for _, column in ipairs(session.columns(opts.session_id, opts.schema, name) or {}) do
        local base = tostring(column.type or ""):lower():gsub("%(.*", ""):gsub("%s*$", "")
        if TEXT_TYPES[base] then
          table.insert(columns, column.name)
        end
      end
      if #columns > 0 then
        table.insert(groups, { table = name, columns = columns })
      end
    end
  end

  table.sort(groups, function(a, b)
    return a.table < b.table
  end)
  return groups
end

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------

--- Count matching rows per column, one query per table.
---
--- One query per table rather than per column: a schema of 286 tables with six
--- text columns each is 1716 round trips the slow way, and the FK walk already
--- taught that lesson once.
---@param group table
---@param needle string
---@param dialect string
---@param schema string
---@return string
function M.count_sql(group, needle, dialect, schema)
  local pattern, escape = M.like_pattern(needle)
  local literal = M.quote_literal(pattern)

  local selects = {}
  for _, column in ipairs(group.columns) do
    local quoted = M.quote_ident(column, dialect)
    table.insert(
      selects,
      ("sum(case when %s like %s%s then 1 else 0 end)"):format(quoted, literal, escape)
    )
  end

  return ("select %s from %s.%s"):format(
    table.concat(selects, ", "),
    M.quote_ident(schema, dialect),
    M.quote_ident(group.table, dialect)
  )
end

--- Search the schema.
---
--- Runs on the coroutine.
---@param opts { session_id: string, schema: string, needle: string, tables?: string[], on_progress?: fun(done: integer, total: integer) }
---@return { hits: table[], total: integer, searched: integer, skipped: table[] }
function M.search(opts)
  local target = session.require_session(opts.session_id)
  local dialect = family(target.info and target.info.adapter)
  local groups = M.text_columns(opts)

  local hits, skipped = {}, {}
  local total, searched = 0, 0

  for index, group in ipairs(groups) do
    local sql = M.count_sql(group, opts.needle, dialect, opts.schema)
    local ok, result = pcall(session.query, opts.session_id, sql, 1)

    if not ok then
      -- A table that cannot be read — a permission, a broken view, a collation
      -- that refuses the comparison — must not abandon the other 285.
      table.insert(skipped, { table = group.table, error = tostring(result) })
    else
      searched = searched + 1
      local row = result.rows and result.rows[1] or {}
      for position, column in ipairs(group.columns) do
        local count = tonumber(row[position]) or 0
        if count > 0 then
          table.insert(hits, { table = group.table, column = column, count = count })
          total = total + count
        end
      end
    end

    if opts.on_progress then
      opts.on_progress(index, #groups)
    end
  end

  table.sort(hits, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    if a.table ~= b.table then
      return a.table < b.table
    end
    return a.column < b.column
  end)

  return { hits = hits, total = total, searched = searched, skipped = skipped }
end

-- ---------------------------------------------------------------------------
-- Replace
-- ---------------------------------------------------------------------------

--- The UPDATE for one hit.
---
--- The WHERE clause repeats the LIKE so only matching rows are rewritten: an
--- unconditional `replace()` over the column would touch every row, bloat the
--- table and fire every trigger for nothing.
---@param hit table
---@param opts { needle: string, replacement: string, schema: string, dialect: string }
---@return string
function M.update_sql(hit, opts)
  local dialect = opts.dialect
  local column = M.quote_ident(hit.column, dialect)
  local needle = M.quote_literal(opts.needle)
  local replacement = M.quote_literal(opts.replacement)
  local pattern, escape = M.like_pattern(opts.needle)

  return ("update %s.%s set %s = replace(%s, %s, %s) where %s like %s%s"):format(
    M.quote_ident(opts.schema, dialect),
    M.quote_ident(hit.table, dialect),
    column,
    column,
    needle,
    replacement,
    column,
    M.quote_literal(pattern),
    escape
  )
end

--- Apply the replacement to the confirmed hits, in one transaction.
---
--- Runs on the coroutine.
---@param opts { session_id: string, schema: string, needle: string, replacement: string, hits: table[] }
---@return { applied: table[], rows: integer }
function M.apply(opts)
  local target = session.require_session(opts.session_id)
  local dialect = family(target.info and target.info.adapter)

  local already_open = target.in_transaction
  if not already_open then
    session.begin(opts.session_id)
  end

  local applied, rows = {}, 0
  local ok, err = pcall(function()
    for _, hit in ipairs(opts.hits) do
      local sql = M.update_sql(hit, {
        needle = opts.needle,
        replacement = opts.replacement,
        schema = opts.schema,
        dialect = dialect,
      })
      local result = session.query(opts.session_id, sql)
      local affected = tonumber(result and result.affected_rows) or hit.count
      table.insert(applied, {
        table = hit.table,
        column = hit.column,
        rows = affected,
        sql = sql,
      })
      rows = rows + affected
    end
  end)

  if not ok then
    if not already_open then
      pcall(session.rollback, opts.session_id)
    end
    error(err, 0)
  end

  if not already_open then
    session.commit(opts.session_id)
  end
  return { applied = applied, rows = rows }
end

-- ---------------------------------------------------------------------------
-- Report
-- ---------------------------------------------------------------------------

--- Render a search result.
---@param report table
---@param opts { needle: string, replacement?: string, schema: string }
---@return string[] lines, table[] marks, table[] index  index maps line to hit
function M.render(report, opts)
  local lines = {
    opts.replacement
        and ("%s   %s  →  %s"):format(opts.schema, opts.needle, opts.replacement)
      or ("%s   %s"):format(opts.schema, opts.needle),
    "",
  }
  local marks = { { line = 0, group = "DBClientHeader" } }
  local index = {}

  if #report.hits == 0 then
    table.insert(lines, ("no matches in %d tables"):format(report.searched))
    table.insert(marks, { line = #lines - 1, group = "DBClientSeverityOk" })
    return lines, marks, index
  end

  local table_width, column_width = 0, 0
  for _, hit in ipairs(report.hits) do
    table_width = math.max(table_width, #hit.table)
    column_width = math.max(column_width, #hit.column)
  end

  local tables = {}
  for _, hit in ipairs(report.hits) do
    tables[hit.table] = true
    table.insert(
      lines,
      ("  %-" .. table_width .. "s  %-" .. column_width .. "s  %6d"):format(
        hit.table,
        hit.column,
        hit.count
      )
    )
    index[#lines] = hit
    table.insert(marks, { line = #lines - 1, group = "DBClientTable" })
  end

  table.insert(lines, "")
  table.insert(
    lines,
    ("%d rows across %d columns in %d tables (%d tables searched)"):format(
      report.total,
      #report.hits,
      vim.tbl_count(tables),
      report.searched
    )
  )
  table.insert(marks, { line = #lines - 1, group = "DBClientHelpText" })

  if #report.skipped > 0 then
    table.insert(lines, ("%d table(s) could not be searched"):format(#report.skipped))
    table.insert(marks, { line = #lines - 1, group = "DBClientSeverityWarn" })
    for _, entry in ipairs(report.skipped) do
      table.insert(lines, ("  %s: %s"):format(entry.table, entry.error))
      table.insert(marks, { line = #lines - 1, group = "DBClientHelpText" })
    end
  end

  return lines, marks, index
end

-- ---------------------------------------------------------------------------
-- Command
-- ---------------------------------------------------------------------------

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

--- Search the schema and offer to replace.
---@param opts { needle?: string, replacement?: string, schema?: string, tables?: string[] }|nil
function M.open(opts)
  opts = opts or {}
  local target = session.current()
  if not target then
    return notify("no active connection", vim.log.levels.WARN)
  end
  local schema = opts.schema or (target.info and target.info.database)
  if not schema then
    return notify("no schema; pass one", vim.log.levels.ERROR)
  end

  local needle = opts.needle
  if not needle or needle == "" then
    needle = vim.fn.input("find in " .. schema .. ": ")
    if needle == "" then
      return
    end
  end

  local replacement = opts.replacement
  if replacement == nil then
    replacement = vim.fn.input("replace with: ")
  end

  notify(("searching %s…"):format(schema))
  client.async(function()
    local report = M.search({
      session_id = target.id,
      schema = schema,
      needle = needle,
      tables = opts.tables,
      -- Every table is scanned, so on a large schema this takes real time and
      -- silence would look like a hang. `:DBClientCancel` still works.
      on_progress = function(done, total)
        if total > 20 and done % 20 == 0 then
          notify(("searching %s… %d/%d tables"):format(schema, done, total))
        end
      end,
    })

    local lines, marks, index = M.render(report, {
      needle = needle,
      replacement = replacement ~= "" and replacement or nil,
      schema = schema,
    })

    local buffer = require("dbclient.ui.buffer")
    local bufnr = buffer.scratch("dbclient://replace", { filetype = "dbclient-replace" })
    buffer.set_lines(bufnr, lines)
    require("dbclient.ui.highlights").lines(bufnr, marks)
    buffer.show(bufnr, "botright split")

    if #report.hits == 0 or replacement == "" then
      return
    end

    -- `<CR>` opens the matching rows, `r` writes. Looking before writing is a
    -- keystroke away rather than a separate command.
    vim.keymap.set("n", "<CR>", function()
      local hit = index[vim.api.nvim_win_get_cursor(0)[1]]
      if not hit then
        return
      end
      local pattern = select(1, M.like_pattern(needle))
      require("dbclient.ui.data").open({
        session_id = target.id,
        schema = schema,
        table = hit.table,
        filter = ("%s like %s escape '\\'"):format(hit.column, M.quote_literal(pattern)),
      })
    end, { buffer = bufnr, silent = true, desc = "DBClient: show the matching rows" })

    vim.keymap.set("n", "r", function()
      local summary = ("Replace %q with %q in %d rows across %d columns?"):format(
        needle,
        replacement,
        report.total,
        #report.hits
      )
      if vim.fn.confirm(summary, "&No\n&Yes", 1) ~= 2 then
        return notify("nothing written")
      end

      client.async(function()
        local applied = M.apply({
          session_id = target.id,
          schema = schema,
          needle = needle,
          replacement = replacement,
          hits = report.hits,
        })
        notify(("replaced in %d rows across %d columns"):format(applied.rows, #applied.applied))
      end, function(err)
        notify(tostring(err), vim.log.levels.ERROR)
      end)
    end, { buffer = bufnr, silent = true, desc = "DBClient: apply the replacement" })
  end, function(err)
    notify(tostring(err), vim.log.levels.ERROR)
  end)
end

return M

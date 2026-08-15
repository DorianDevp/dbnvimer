--- A linter for schemas.
---
--- Most of these findings are things everyone knows to check and nobody checks:
--- a table without a primary key, a foreign key with no index behind it, two
--- indexes where one is a prefix of the other. They are cheap to detect from
--- metadata that is already cached, and expensive to discover from a slow
--- production query six months later.
---
--- Findings go to the quickfix list so `]q` walks them, and to a report buffer
--- so the whole picture is readable at once.

local client = require("dbclient.core.client")
local session = require("dbclient.session")

local M = {}

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

---@class dbclient.Finding
---@field severity "error"|"warn"|"hint"
---@field code string
---@field table string
---@field message string
---@field fix? string

--- Checks that need only cached metadata.
---
--- Each takes the collected schema information and appends findings; keeping
--- them separate makes each one readable and independently testable.
M.checks = {}

--- A table you cannot safely update a single row of.
function M.checks.missing_primary_key(schema, findings)
  for _, entry in ipairs(schema.tables) do
    if not entry.is_view and #entry.primary == 0 then
      table.insert(findings, {
        severity = "warn",
        code = "no-primary-key",
        table = entry.name,
        message = "no primary key: rows cannot be addressed individually",
        fix = ("alter table %s add primary key (…);"):format(entry.name),
      })
    end
  end
end

--- A foreign key with no index behind it turns every parent delete into a scan.
function M.checks.unindexed_foreign_key(schema, findings)
  for _, entry in ipairs(schema.tables) do
    for _, key in ipairs(entry.foreign_keys) do
      local covered = false
      for _, index in ipairs(entry.indexes) do
        local columns = index.columns or ""
        -- An index covers the key when the column is its first component.
        local first = vim.split(columns, ",")[1]
        if first and vim.trim(first) == key.column then
          covered = true
        end
      end
      if not covered then
        table.insert(findings, {
          severity = "warn",
          code = "unindexed-foreign-key",
          table = entry.name,
          message = ("%s references %s.%s but has no index"):format(
            key.column,
            key.ref_table,
            key.ref_column
          ),
          fix = ("create index on %s (%s);"):format(entry.name, key.column),
        })
      end
    end
  end
end

--- One index whose columns are a prefix of another's is dead weight.
function M.checks.redundant_index(schema, findings)
  for _, entry in ipairs(schema.tables) do
    for _, candidate in ipairs(entry.indexes) do
      for _, other in ipairs(entry.indexes) do
        if candidate.name ~= other.name and candidate.columns and other.columns then
          local prefix = candidate.columns .. ", "
          local longer = other.columns .. ", "
          if #candidate.columns < #other.columns and longer:sub(1, #prefix) == prefix then
            -- A unique index is not redundant even as a prefix: it enforces
            -- something the longer one does not.
            if not candidate.unique then
              table.insert(findings, {
                severity = "hint",
                code = "redundant-index",
                table = entry.name,
                message = ("%s (%s) is a prefix of %s (%s)"):format(
                  candidate.name,
                  candidate.columns,
                  other.name,
                  other.columns
                ),
                fix = ("drop index %s;"):format(candidate.name),
              })
            end
          end
        end
      end
    end
  end
end

--- Columns that reference the same thing under different types will not join
--- on an index.
function M.checks.foreign_key_type_mismatch(schema, findings)
  local types = {}
  for _, entry in ipairs(schema.tables) do
    types[entry.name] = {}
    for _, column in ipairs(entry.columns) do
      types[entry.name][column.name] = column.type
    end
  end

  for _, entry in ipairs(schema.tables) do
    for _, key in ipairs(entry.foreign_keys) do
      local here = types[entry.name] and types[entry.name][key.column]
      local there = types[key.ref_table] and types[key.ref_table][key.ref_column]
      if here and there and here:lower() ~= there:lower() then
        table.insert(findings, {
          severity = "warn",
          code = "foreign-key-type-mismatch",
          table = entry.name,
          message = ("%s is %s but %s.%s is %s"):format(
            key.column,
            here,
            key.ref_table,
            key.ref_column,
            there
          ),
        })
      end
    end
  end
end

--- A nullable column that every row fills is a missing constraint; a column no
--- row fills is dead. Both need a query, so this check is opt-in.
function M.checks.column_usage(schema, findings)
  for _, entry in ipairs(schema.tables) do
    local is_key = {}
    for _, name in ipairs(entry.primary) do
      is_key[name] = true
    end

    for _, column in ipairs(entry.stats or {}) do
      -- A primary key is never really nullable, whatever the catalog says:
      -- SQLite reports `integer primary key` as nullable because it is a rowid
      -- alias, and suggesting a NOT NULL constraint for it is noise.
      if column.total > 0 and not is_key[column.name] then
        if column.non_null == 0 then
          table.insert(findings, {
            severity = "hint",
            code = "always-null",
            table = entry.name,
            message = ("%s is NULL in every row"):format(column.name),
            fix = ("alter table %s drop column %s;"):format(entry.name, column.name),
          })
        elseif column.nullable and column.non_null == column.total then
          table.insert(findings, {
            severity = "hint",
            code = "never-null",
            table = entry.name,
            message = ("%s is nullable but never NULL"):format(column.name),
            fix = ("alter table %s alter column %s set not null;"):format(
              entry.name,
              column.name
            ),
          })
        elseif column.distinct == 1 and column.total > 10 then
          table.insert(findings, {
            severity = "hint",
            code = "single-value",
            table = entry.name,
            message = ("%s holds the same value in all %d rows"):format(
              column.name,
              column.total
            ),
          })
        end
      end
    end
  end
end

--- Gather everything the checks need.
--- Must run inside `client.async`.
---@param session_id string
---@param schema_name string
---@param opts? { deep?: boolean }
---@return table
function M.collect(session_id, schema_name, opts)
  opts = opts or {}
  local schema = { name = schema_name, tables = {} }

  -- One query for every foreign key in the schema, then grouped by table.
  local keys_by_table = {}
  local all_ok, all_keys = pcall(session.schema_foreign_keys, session_id, schema_name)
  if all_ok then
    for _, key in ipairs(all_keys) do
      keys_by_table[key.table] = keys_by_table[key.table] or {}
      table.insert(keys_by_table[key.table], key)
    end
  end

  for _, entry in ipairs(session.tables(session_id, schema_name)) do
    local is_view = tostring(entry.kind):find("VIEW") ~= nil
    local columns = {}
    local primary = {}

    local ok, list = pcall(session.columns, session_id, schema_name, entry.name)
    if ok then
      columns = list
      for _, column in ipairs(list) do
        if column.key == "PRI" then
          table.insert(primary, column.name)
        end
      end
    end

    local indexes = {}
    if not is_view then
      local indexes_ok, list_indexes = pcall(session.indexes, session_id, schema_name, entry.name)
      if indexes_ok then
        indexes = list_indexes
      end
    end

    local foreign_keys = is_view and {} or (keys_by_table[entry.name] or {})

    local stats = nil
    if opts.deep and not is_view then
      stats = {}
      for _, column in ipairs(columns) do
        local stats_ok, column_stats =
          pcall(session.column_stats, session_id, schema_name, entry.name, column.name)
        if stats_ok then
          table.insert(stats, {
            name = column.name,
            nullable = column.nullable,
            total = tonumber(column_stats.total) or 0,
            non_null = tonumber(column_stats.non_null) or 0,
            distinct = tonumber(column_stats.distinct) or 0,
          })
        end
      end
    end

    table.insert(schema.tables, {
      name = entry.name,
      is_view = is_view,
      estimated_rows = entry.estimated_rows,
      columns = columns,
      primary = primary,
      indexes = indexes,
      foreign_keys = foreign_keys,
      stats = stats,
    })
  end

  return schema
end

--- Run every check over collected schema information.
---@param schema table
---@return dbclient.Finding[]
function M.analyse(schema)
  local findings = {}
  local names = vim.tbl_keys(M.checks)
  table.sort(names)
  for _, name in ipairs(names) do
    M.checks[name](schema, findings)
  end

  local weight = { error = 1, warn = 2, hint = 3 }
  table.sort(findings, function(a, b)
    if a.severity ~= b.severity then
      return weight[a.severity] < weight[b.severity]
    end
    if a.table ~= b.table then
      return a.table < b.table
    end
    return a.message < b.message
  end)
  return findings
end

--- Render the findings as a report.
---@param schema table
---@param findings dbclient.Finding[]
---@return string[] lines, table[] marks
function M.report(schema, findings)
  local lines = {}
  local marks = {}

  local function add(text, group)
    table.insert(lines, text)
    if group then
      table.insert(marks, { line = #lines - 1, group = group })
    end
  end

  local counts = { error = 0, warn = 0, hint = 0 }
  for _, finding in ipairs(findings) do
    counts[finding.severity] = counts[finding.severity] + 1
  end

  add(
    ("%s  ·  %d tables  ·  %d warning(s), %d hint(s)"):format(
      schema.name,
      #schema.tables,
      counts.warn + counts.error,
      counts.hint
    ),
    "DBClientHeader"
  )
  add("")

  if #findings == 0 then
    add("nothing to report", "DBClientDetected")
    return lines, marks
  end

  local groups = {
    { "error", "problems", "DBClientPlanHot" },
    { "warn", "worth fixing", "DBClientPlanWarm" },
    { "hint", "worth a look", "DBClientHelpText" },
  }

  for _, group in ipairs(groups) do
    local severity, title, highlight = group[1], group[2], group[3]
    local subset = vim.tbl_filter(function(finding)
      return finding.severity == severity
    end, findings)

    if #subset > 0 then
      add(("%s (%d)"):format(title, #subset), "DBClientSchema")
      local current = nil
      for _, finding in ipairs(subset) do
        if finding.table ~= current then
          current = finding.table
          add("  " .. current, "DBClientTable")
        end
        add(("    %s"):format(finding.message), highlight)
        if finding.fix then
          add(("      %s"):format(finding.fix), "DBClientHelpText")
        end
      end
      add("")
    end
  end

  return lines, marks
end

--- Run the audit and show it.
---@param opts { session_id?: string, schema: string, deep?: boolean }
function M.run(opts)
  local target = session.get(opts.session_id)
  if not target then
    return notify("no active connection", vim.log.levels.WARN)
  end

  notify(opts.deep and "auditing (reading column statistics, this takes a moment)..." or "auditing...")

  client.async(function()
    local schema = M.collect(target.id, opts.schema, { deep = opts.deep })
    local findings = M.analyse(schema)
    local lines, marks = M.report(schema, findings)

    local buffer = require("dbclient.ui.buffer")
    local bufnr = buffer.scratch(
      ("dbclient://%s/%s.audit"):format(target.name, opts.schema),
      { modifiable = false }
    )
    vim.bo[bufnr].filetype = "dbclient-audit"
    buffer.set_lines(bufnr, lines)
    buffer.show(bufnr, "botright split")
    require("dbclient.ui.highlights").lines(bufnr, marks)

    -- The quickfix list makes the findings navigable with ]q and [q.
    local items = {}
    for _, finding in ipairs(findings) do
      table.insert(items, {
        text = ("[%s] %s: %s"):format(finding.severity, finding.table, finding.message),
        type = finding.severity == "hint" and "I" or (finding.severity == "warn" and "W" or "E"),
        user_data = {
          dbclient = true,
          session_id = target.id,
          schema = opts.schema,
          table = finding.table,
        },
      })
    end
    if #items > 0 then
      vim.fn.setqflist({}, " ", {
        title = ("DBClient audit: %s"):format(opts.schema),
        items = items,
      })
    end

    notify(("%d finding(s); :copen to walk them"):format(#findings))
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

--- Ask which schema, then audit it.
---@param opts? { session_id?: string, deep?: boolean }
function M.prompt(opts)
  opts = opts or {}
  local target = session.get(opts.session_id)
  if not target then
    return notify("no active connection", vim.log.levels.WARN)
  end

  client.async(function()
    local names = {}
    for _, entry in ipairs(session.schemas(target.id)) do
      table.insert(names, entry.name)
    end

    local preferred = target.info and target.info.database
    if preferred and vim.tbl_contains(names, preferred) then
      return M.run({ session_id = target.id, schema = preferred, deep = opts.deep })
    end

    vim.ui.select(names, { prompt = "audit schema" }, function(schema)
      if schema then
        M.run({ session_id = target.id, schema = schema, deep = opts.deep })
      end
    end)
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

return M

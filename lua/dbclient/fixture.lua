--- Extract a row together with everything it needs to exist.
---
--- "Give me this one customer as test data" is a question with a hard answer:
--- the row is useless without the address it points at, which is useless
--- without the country, and the inserts have to run in that order or the
--- foreign keys reject them. Everyone solves this by hand, badly.
---
--- Here the foreign key graph is walked from a starting row — upward to the
--- parents it requires, and optionally downward to the children that reference
--- it — the tables are sorted so parents come first, and the result is a
--- runnable `.sql` file. Cycles are reported rather than silently mis-ordered,
--- because a cycle genuinely cannot be expressed as a linear insert order.

local client = require("dbclient.core.client")
local session = require("dbclient.session")

local M = {}

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

local function key_of(schema, table_name, values)
  return ("%s.%s|%s"):format(schema, table_name, table.concat(values, "\1"))
end

local function literal(value)
  if value == nil or value == vim.NIL then
    return "null"
  end
  return "'" .. tostring(value):gsub("'", "''") .. "'"
end

--- Order tables so that a table always comes after the tables it points at.
---
--- Kahn's algorithm; whatever is left when no node has an empty in-degree is a
--- cycle, which is returned separately rather than ordered arbitrarily.
---@param tables string[]
---@param edges table<string, string[]>  table -> tables it depends on
---@return string[] ordered, string[] cyclic
function M.topological_sort(tables, edges)
  local remaining = {}
  for _, name in ipairs(tables) do
    remaining[name] = true
  end

  local ordered = {}
  local placed = {}

  local progress = true
  while progress do
    progress = false
    -- Sorted for a stable result: the same input must produce the same file.
    local candidates = vim.tbl_keys(remaining)
    table.sort(candidates)

    for _, name in ipairs(candidates) do
      local ready = true
      for _, dependency in ipairs(edges[name] or {}) do
        if remaining[dependency] and dependency ~= name then
          ready = false
        end
      end
      if ready then
        table.insert(ordered, name)
        placed[name] = true
        remaining[name] = nil
        progress = true
      end
    end
  end

  local cyclic = vim.tbl_keys(remaining)
  table.sort(cyclic)
  return ordered, cyclic
end

--- Walk the graph and collect rows.
--- Must run inside `client.async`.
---@param opts { session_id: string, schema: string, table: string, pk: table<string, any>, depth?: integer, children?: boolean, limit?: integer }
---@return { tables: table<string, table>, order: string[], cyclic: string[], count: integer }
function M.collect(opts)
  local depth = opts.depth or 3
  local child_limit = opts.limit or 50

  local collected = {}
  local edges = {}
  local seen = {}
  local count = 0

  local queue = {}
  do
    local filters = {}
    for column, value in pairs(opts.pk) do
      table.insert(filters, ("%s = %s"):format(column, literal(value)))
    end
    table.insert(queue, {
      schema = opts.schema,
      table = opts.table,
      filter = table.concat(filters, " and "),
      depth = 0,
      direction = "root",
    })
  end

  while #queue > 0 do
    local item = table.remove(queue, 1)
    local qualified = ("%s.%s"):format(item.schema, item.table)

    local ok, result = pcall(session.preview, opts.session_id, {
      schema = item.schema,
      table = item.table,
      filter = item.filter,
      limit = item.direction == "child" and child_limit or 200,
    })
    if ok and #result.rows > 0 then
      collected[qualified] = collected[qualified]
        or { columns = result.columns, rows = {}, schema = item.schema, table = item.table }

      local keys_ok, foreign_keys =
        pcall(session.foreign_keys, opts.session_id, item.schema, item.table)
      foreign_keys = keys_ok and foreign_keys or {}

      edges[qualified] = edges[qualified] or {}
      for _, key in ipairs(foreign_keys) do
        local parent = ("%s.%s"):format(
          key.ref_schema ~= "" and key.ref_schema or item.schema,
          key.ref_table
        )
        if not vim.tbl_contains(edges[qualified], parent) then
          table.insert(edges[qualified], parent)
        end
      end

      local primary = session.primary_key(opts.session_id, item.schema, item.table)

      for _, row in ipairs(result.rows) do
        local by_name = {}
        for index, column in ipairs(result.columns) do
          by_name[column.name] = row[index]
        end

        local identity = {}
        for _, name in ipairs(#primary > 0 and primary or {}) do
          table.insert(identity, tostring(by_name[name]))
        end
        if #identity == 0 then
          -- Without a key the whole row is its identity, which at least stops
          -- the same row being emitted twice.
          for _, value in ipairs(row) do
            table.insert(identity, tostring(value))
          end
        end

        local identifier = key_of(item.schema, item.table, identity)
        if not seen[identifier] then
          seen[identifier] = true
          count = count + 1
          table.insert(collected[qualified].rows, row)

          if item.depth < depth then
            -- Upward: everything this row points at is required.
            for _, key in ipairs(foreign_keys) do
              local value = by_name[key.column]
              if value ~= nil and value ~= vim.NIL then
                table.insert(queue, {
                  schema = key.ref_schema ~= "" and key.ref_schema or item.schema,
                  table = key.ref_table,
                  filter = ("%s = %s"):format(key.ref_column, literal(value)),
                  depth = item.depth + 1,
                  direction = "parent",
                })
              end
            end

            -- Downward: only from the row you asked about, and only one level,
            -- or a single customer drags in the whole database.
            if opts.children and item.direction == "root" then
              local refs_ok, references =
                pcall(session.referencing_keys, opts.session_id, item.schema, item.table)
              if refs_ok then
                for _, reference in ipairs(references) do
                  local value = by_name[reference.ref_column]
                  if value ~= nil and value ~= vim.NIL then
                    table.insert(queue, {
                      schema = reference.schema,
                      table = reference.table,
                      filter = ("%s = %s"):format(reference.column, literal(value)),
                      depth = item.depth + 1,
                      direction = "child",
                    })
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  local names = vim.tbl_keys(collected)
  local ordered, cyclic = M.topological_sort(names, edges)

  return { tables = collected, order = ordered, cyclic = cyclic, count = count }
end

--- Render the collected rows as inserts, parents first.
---
--- The SQL literals come from the core's export writer, so the escaping and
--- the dialect quoting are the ones already under test rather than a second
--- implementation that drifts.
--- Must run inside `client.async`.
---@param opts { session_id: string, collected: table, anonymize?: string[], connection?: string }
---@return string[]
function M.render(opts)
  local collected = opts.collected
  local lines = {
    ("-- @conn: %s"):format(opts.connection or ""),
    ("-- fixture: %d row(s) across %d table(s)"):format(collected.count, #collected.order),
    "-- Parents first, so the foreign keys are satisfiable in this order.",
    "",
  }

  if #collected.cyclic > 0 then
    table.insert(lines, "-- ! These tables reference each other, so no linear order exists:")
    for _, name in ipairs(collected.cyclic) do
      table.insert(lines, ("--   %s"):format(name))
    end
    table.insert(lines, "-- ! Insert them with the constraints deferred, or in two passes.")
    table.insert(lines, "")
  end

  local order = vim.deepcopy(collected.order)
  vim.list_extend(order, collected.cyclic)

  for _, qualified in ipairs(order) do
    local entry = collected.tables[qualified]
    if entry and #entry.rows > 0 then
      -- Build a filter that selects exactly the collected rows, then let the
      -- exporter render them.
      local primary = session.primary_key(opts.session_id, entry.schema, entry.table)
      local filter = M.filter_for(entry, primary)

      local ok, outcome = pcall(client.call, "export", {
        format = "sql",
        destination = "/dev/null",
        schema = entry.schema,
        table = entry.table,
        filter = filter,
        sql_table = entry.table,
        sql_batch = 50,
        preview = true,
        preview_rows = #entry.rows,
        manifest = false,
        redact = opts.anonymize or {},
        redact_with = "REDACTED",
      }, opts.session_id)

      table.insert(lines, ("-- %s  (%d row(s))"):format(qualified, #entry.rows))
      if ok and outcome.preview then
        for _, line in ipairs(vim.split(vim.trim(outcome.preview), "\n")) do
          table.insert(lines, line)
        end
      else
        table.insert(lines, ("-- could not render: %s"):format(tostring(outcome)))
      end
      table.insert(lines, "")
    end
  end

  return lines
end

--- A `where` clause selecting exactly the rows collected for a table.
---@param entry table
---@param primary string[]
---@return string
function M.filter_for(entry, primary)
  local index_of = {}
  for index, column in ipairs(entry.columns) do
    index_of[column.name] = index
  end

  if #primary == 1 and index_of[primary[1]] then
    local values = {}
    for _, row in ipairs(entry.rows) do
      table.insert(values, literal(row[index_of[primary[1]]]))
    end
    return ("%s in (%s)"):format(primary[1], table.concat(values, ", "))
  end

  -- A composite or missing key needs one predicate per row.
  local clauses = {}
  for _, row in ipairs(entry.rows) do
    local parts = {}
    local names = #primary > 0 and primary or vim.tbl_map(function(column)
      return column.name
    end, entry.columns)
    for _, name in ipairs(names) do
      local index = index_of[name]
      if index then
        local value = row[index]
        if value == nil or value == vim.NIL then
          table.insert(parts, ("%s is null"):format(name))
        else
          table.insert(parts, ("%s = %s"):format(name, literal(value)))
        end
      end
    end
    table.insert(clauses, "(" .. table.concat(parts, " and ") .. ")")
  end
  return table.concat(clauses, " or ")
end

--- Extract a fixture starting from the row under the cursor.
---@param opts { session_id?: string, schema: string, table: string, pk: table, children?: boolean, depth?: integer, anonymize?: string[] }
function M.extract(opts)
  local target = session.get(opts.session_id)
  if not target then
    return notify("no active connection", vim.log.levels.WARN)
  end

  notify("walking the foreign key graph...")

  client.async(function()
    local collected = M.collect({
      session_id = target.id,
      schema = opts.schema,
      table = opts.table,
      pk = opts.pk,
      depth = opts.depth,
      children = opts.children,
    })

    if collected.count == 0 then
      return notify("that row was not found", vim.log.levels.WARN)
    end

    local lines = M.render({
      session_id = target.id,
      collected = collected,
      connection = target.name,
      anonymize = opts.anonymize,
    })

    local buffer = require("dbclient.ui.buffer")
    local bufnr = buffer.scratch(
      ("dbclient://%s/fixture-%s.sql"):format(target.name, opts.table),
      { modifiable = true }
    )
    vim.bo[bufnr].filetype = "sql"
    buffer.set_lines(bufnr, lines)
    buffer.show(bufnr, "botright split")

    local query = require("dbclient.ui.query")
    if not query.buffers[bufnr] then
      query.attach(bufnr)
    end
    query.buffers[bufnr] = { session_id = target.id }

    notify(("fixture ready: %d row(s) across %d table(s)"):format(
      collected.count,
      #collected.order + #collected.cyclic
    ))
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

--- Extract from the data buffer's current row, asking about the options.
function M.from_cursor()
  local data = require("dbclient.ui.data")
  local cell = data.current_cell()
  if not cell then
    return notify("move onto a row first", vim.log.levels.WARN)
  end

  local view = cell.view
  if #view.primary == 0 then
    return notify("this table has no primary key", vim.log.levels.WARN)
  end

  local pk = {}
  for index, column in ipairs(view.columns) do
    for _, name in ipairs(view.primary) do
      if column.name == name then
        pk[name] = view.rows[cell.row_index][index]
      end
    end
  end

  vim.ui.select({
    "this row and what it requires",
    "this row, what it requires, and what references it",
  }, { prompt = "fixture" }, function(choice)
    if not choice then
      return
    end
    M.extract({
      session_id = view.session_id,
      schema = view.schema,
      table = view.table,
      pk = pk,
      children = choice:find("references") ~= nil,
    })
  end)
end

return M

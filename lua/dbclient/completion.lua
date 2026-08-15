--- Schema-aware completion, hover resolution and object search.
---
--- The metadata cache the sidebar already builds is a symbol index; this module
--- turns it into completion candidates and identifier resolution. Completion
--- itself must answer synchronously, so it only ever reads the warmed cache and
--- never blocks on the core.

local client = require("dbclient.core.client")
local session = require("dbclient.session")

local M = {
  --- session id -> index
  index = {},
  warming = {},
}

local function empty_index()
  return {
    schemas = {},
    tables = {},
    columns = {},
    routines = {},
    by_table = {},
    built_at = 0,
  }
end

--- Build the completion index for a session in the background.
---
--- Only the connection's own database is walked, because walking every schema
--- on a large server is slow and rarely what the user means.
---@param session_id string|nil
---@param opts? { force?: boolean, schemas?: string[] }
function M.warm(session_id, opts)
  opts = opts or {}
  local target = session.get(session_id)
  if not target then
    return
  end
  if M.warming[target.id] then
    return
  end
  if M.index[target.id] and not opts.force then
    return
  end

  M.warming[target.id] = true
  client.async(function()
    local index = empty_index()
    local schemas = opts.schemas

    if not schemas then
      schemas = {}
      local preferred = target.info and target.info.database
      for _, schema in ipairs(session.schemas(target.id)) do
        if not preferred or schema.name == preferred then
          table.insert(schemas, schema.name)
        end
      end
      -- Fall back to every schema when the database name matched nothing,
      -- which happens on PostgreSQL where `public` is the usual home.
      if #schemas == 0 then
        for _, schema in ipairs(session.schemas(target.id)) do
          table.insert(schemas, schema.name)
        end
      end
    end

    for _, schema in ipairs(schemas) do
      table.insert(index.schemas, schema)
      local ok, tables = pcall(session.tables, target.id, schema)
      if ok then
        for _, entry in ipairs(tables) do
          table.insert(index.tables, {
            schema = schema,
            name = entry.name,
            kind = entry.kind,
            comment = entry.comment,
            estimated_rows = entry.estimated_rows,
          })
        end
      end
      local routines_ok, routines = pcall(session.routines, target.id, schema)
      if routines_ok then
        for _, routine in ipairs(routines) do
          table.insert(index.routines, {
            schema = schema,
            name = routine.name,
            kind = routine.kind,
            arguments = routine.arguments,
          })
        end
      end
    end

    M.index[target.id] = index
    M.warming[target.id] = nil
  end, function()
    M.warming[target.id] = nil
  end)
end

--- Load a table's columns into the index, if they are not already there.
--- Must run inside `client.async`.
---@param session_id string
---@param schema string
---@param table_name string
---@return table[]
function M.columns(session_id, schema, table_name)
  local index = M.index[session_id]
  if not index then
    index = empty_index()
    M.index[session_id] = index
  end

  local key = schema .. "." .. table_name
  if not index.by_table[key] then
    local ok, columns = pcall(session.columns, session_id, schema, table_name)
    if not ok then
      return {}
    end
    index.by_table[key] = columns
    for _, column in ipairs(columns) do
      index.columns[column.name] = index.columns[column.name] or {}
      table.insert(index.columns[column.name], key)
    end
  end
  return index.by_table[key]
end

--- Resolve a possibly qualified identifier against the index.
--- Must run inside `client.async`.
---@param session_id string
---@param identifier string
---@return table|nil
function M.resolve(session_id, identifier)
  local index = M.index[session_id]
  if not index then
    M.warm(session_id)
    index = M.index[session_id] or empty_index()
  end

  local parts = vim.split(identifier, ".", { plain = true })

  local function find_table(schema, name)
    for _, entry in ipairs(index.tables) do
      if entry.name == name and (schema == nil or entry.schema == schema) then
        return entry
      end
    end
  end

  if #parts == 1 then
    local entry = find_table(nil, parts[1])
    if entry then
      return { kind = "table", schema = entry.schema, table = entry.name, info = entry }
    end
    return nil
  end

  if #parts >= 2 then
    -- `schema.table`
    local entry = find_table(parts[#parts - 1], parts[#parts])
    if entry then
      return { kind = "table", schema = entry.schema, table = entry.name, info = entry }
    end

    -- `table.column`
    local table_entry = find_table(nil, parts[#parts - 1])
    if table_entry then
      for _, column in ipairs(M.columns(session_id, table_entry.schema, table_entry.name)) do
        if column.name == parts[#parts] then
          return {
            kind = "column",
            schema = table_entry.schema,
            table = table_entry.name,
            column = column,
          }
        end
      end
      return { kind = "table", schema = table_entry.schema, table = table_entry.name, info = table_entry }
    end
  end

  return nil
end

-- ---------------------------------------------------------------------------
-- Completion
-- ---------------------------------------------------------------------------

--- Table names mentioned in the statement around the cursor, so column
--- completion can prefer their columns.
---@param bufnr integer
---@return string[]
local function tables_in_scope(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n"):lower()
  local names = {}
  for name in text:gmatch("from%s+([%w_.\"`]+)") do
    table.insert(names, (name:gsub('["`]', "")))
  end
  for name in text:gmatch("join%s+([%w_.\"`]+)") do
    table.insert(names, (name:gsub('["`]', "")))
  end
  for name in text:gmatch("update%s+([%w_.\"`]+)") do
    table.insert(names, (name:gsub('["`]', "")))
  end
  for name in text:gmatch("into%s+([%w_.\"`]+)") do
    table.insert(names, (name:gsub('["`]', "")))
  end
  return names
end

--- Candidate list for a prefix, read from the warmed index only.
---@param session_id string|nil
---@param prefix string
---@param bufnr integer|nil
---@return table[]  `{ word, kind, menu }`
function M.candidates(session_id, prefix, bufnr)
  local target = session.get(session_id)
  if not target then
    return {}
  end

  local index = M.index[target.id]
  if not index then
    M.warm(target.id)
    return {}
  end

  local lower = prefix:lower()
  local items = {}

  local function matches(name)
    return prefix == "" or name:lower():sub(1, #lower) == lower
  end

  -- Qualified prefix: `table.` completes that table's columns.
  local qualifier = prefix:match("^([%w_]+)%.")
  if qualifier then
    local tail = prefix:sub(#qualifier + 2):lower()
    for _, entry in ipairs(index.tables) do
      if entry.name:lower() == qualifier:lower() or entry.schema:lower() == qualifier:lower() then
        if entry.name:lower() == qualifier:lower() then
          for _, column in ipairs(index.by_table[entry.schema .. "." .. entry.name] or {}) do
            if tail == "" or column.name:lower():sub(1, #tail) == tail then
              table.insert(items, {
                word = qualifier .. "." .. column.name,
                kind = "column",
                menu = column.type,
              })
            end
          end
        else
          if tail == "" or entry.name:lower():sub(1, #tail) == tail then
            table.insert(items, {
              word = qualifier .. "." .. entry.name,
              kind = "table",
              menu = entry.kind,
            })
          end
        end
      end
    end
    return items
  end

  for _, entry in ipairs(index.tables) do
    if matches(entry.name) then
      table.insert(items, { word = entry.name, kind = "table", menu = entry.schema })
    end
  end

  -- Columns of the tables this statement already mentions come first in
  -- relevance because they are almost always what is wanted.
  local scope = bufnr and tables_in_scope(bufnr) or {}
  local seen = {}
  for _, name in ipairs(scope) do
    local short = name:match("([%w_]+)$")
    for _, entry in ipairs(index.tables) do
      if entry.name:lower() == (short or ""):lower() then
        for _, column in ipairs(index.by_table[entry.schema .. "." .. entry.name] or {}) do
          if matches(column.name) and not seen[column.name] then
            seen[column.name] = true
            table.insert(items, {
              word = column.name,
              kind = "column",
              menu = ("%s · %s"):format(entry.name, column.type),
            })
          end
        end
      end
    end
  end

  for _, entry in ipairs(index.routines) do
    if matches(entry.name) then
      table.insert(items, { word = entry.name, kind = "routine", menu = entry.kind })
    end
  end

  for _, schema in ipairs(index.schemas) do
    if matches(schema) then
      table.insert(items, { word = schema, kind = "schema", menu = "schema" })
    end
  end

  return items
end

--- `omnifunc` implementation, wired up in SQL buffers.
function M.omnifunc(findstart, base)
  local bufnr = vim.api.nvim_get_current_buf()

  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local column = vim.api.nvim_win_get_cursor(0)[2]
    local start = column
    while start > 0 and line:sub(start, start):match("[%w_.]") do
      start = start - 1
    end
    return start
  end

  local bound = require("dbclient.ui.query").buffers[bufnr]
  local session_id = bound and bound.session_id

  local items = {}
  for _, candidate in ipairs(M.candidates(session_id, base, bufnr)) do
    table.insert(items, {
      word = candidate.word,
      kind = candidate.kind:sub(1, 1),
      menu = candidate.menu,
    })
  end
  return items
end

--- Everything the object picker searches: tables and columns.
---@param session_id string|nil
---@return table[]
function M.search_entries(session_id)
  local target = session.get(session_id)
  if not target then
    return {}
  end
  local index = M.index[target.id]
  if not index then
    return {}
  end

  local entries = {}
  for _, entry in ipairs(index.tables) do
    table.insert(entries, {
      kind = "table",
      schema = entry.schema,
      table = entry.name,
      label = ("%s  %s.%s"):format(entry.kind == "VIEW" and "view " or "table", entry.schema, entry.name),
    })
  end
  for key, columns in pairs(index.by_table) do
    local schema, table_name = key:match("^(.-)%.(.*)$")
    for _, column in ipairs(columns) do
      table.insert(entries, {
        kind = "column",
        schema = schema,
        table = table_name,
        column = column.name,
        label = ("column %s.%s.%s  %s"):format(schema, table_name, column.name, column.type),
      })
    end
  end
  return entries
end

--- Load every table's columns so the picker can search them.
---@param session_id string|nil
---@param callback fun()
function M.load_all_columns(session_id, callback)
  local target = session.get(session_id)
  if not target then
    return callback()
  end
  client.async(function()
    M.warm(target.id)
    local index = M.index[target.id]
    if not index then
      return callback()
    end
    for _, entry in ipairs(index.tables) do
      M.columns(target.id, entry.schema, entry.name)
    end
    callback()
  end, function()
    callback()
  end)
end

--- An `nvim-cmp` source, registered automatically when cmp is installed.
function M.cmp_source()
  local source = {}

  function source:is_available()
    return vim.bo.filetype == "sql"
  end

  function source:get_trigger_characters()
    return { "." }
  end

  function source:complete(params, callback)
    local bufnr = vim.api.nvim_get_current_buf()
    local bound = require("dbclient.ui.query").buffers[bufnr]
    local prefix = params.context.cursor_before_line:match("[%w_.]*$") or ""

    local items = {}
    for _, candidate in ipairs(M.candidates(bound and bound.session_id, prefix, bufnr)) do
      table.insert(items, {
        label = candidate.word,
        detail = candidate.menu,
        kind = candidate.kind == "table" and 7 or 5, -- Class / Field
      })
    end
    callback({ items = items, isIncomplete = false })
  end

  return source
end

return M

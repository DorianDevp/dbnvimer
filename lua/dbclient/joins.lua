--- Join paths derived from the foreign key graph.
---
--- "How do I get from orders to countries" is a graph question, and the answer
--- is already in the catalog. Walking it by hand means opening three tables and
--- reading their keys; here it is a breadth-first search that comes back as SQL
--- you can run.
---
--- Edges are undirected for search — a join works in either direction — but
--- each edge remembers which side held the foreign key so the generated `ON`
--- clause is right.

local client = require("dbclient.core.client")
local session = require("dbclient.session")

local M = {
  --- "session:schema" -> graph
  cache = {},
}

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

--- Build the undirected foreign key graph for a schema.
--- Must run inside `client.async`.
---@param session_id string
---@param schema string
---@param opts? { force?: boolean }
---@return { nodes: string[], edges: table<string, table[]> }
function M.graph(session_id, schema, opts)
  opts = opts or {}
  local key = ("%s:%s"):format(session_id, schema)
  if M.cache[key] and not opts.force then
    return M.cache[key]
  end

  local graph = { nodes = {}, edges = {} }

  for _, entry in ipairs(session.tables(session_id, schema)) do
    table.insert(graph.nodes, entry.name)
    graph.edges[entry.name] = graph.edges[entry.name] or {}
  end

  -- One query for the whole schema; asking table by table was the slowest
  -- thing this did.
  local ok, keys = pcall(session.schema_foreign_keys, session_id, schema)
  if ok then
    for _, key_entry in ipairs(keys) do
      local name = key_entry.table
      local target = key_entry.ref_table
      if graph.edges[name] and graph.edges[target] then
        -- Forward: this table holds the foreign key.
        table.insert(graph.edges[name], {
          to = target,
          from_column = key_entry.column,
          to_column = key_entry.ref_column,
          constraint = key_entry.name,
        })
        -- Backwards, so the search can travel either way.
        table.insert(graph.edges[target], {
          to = name,
          from_column = key_entry.ref_column,
          to_column = key_entry.column,
          constraint = key_entry.name,
          reverse = true,
        })
      end
    end
  end

  M.cache[key] = graph
  return graph
end

--- Every shortest-ish path between two tables, breadth first.
---
--- Breadth first means the first path found is the shortest; the search keeps
--- going a little further so a second, equally plausible route is offered
--- rather than silently discarded.
---@param graph table
---@param from string
---@param to string
---@param opts? { max_paths?: integer, max_length?: integer }
---@return table[][]  each path is a list of edges
function M.paths(graph, from, to, opts)
  opts = opts or {}
  local max_paths = opts.max_paths or 4
  local max_length = opts.max_length or 5

  if not graph.edges[from] or not graph.edges[to] then
    return {}
  end
  if from == to then
    return { {} }
  end

  local found = {}
  local queue = { { node = from, path = {}, seen = { [from] = true } } }
  local shortest = nil

  while #queue > 0 and #found < max_paths do
    local current = table.remove(queue, 1)

    if #current.path >= max_length then
      goto continue
    end
    if shortest and #current.path >= shortest + 1 then
      -- Allow one step longer than the best route, no more; beyond that the
      -- suggestions stop being useful.
      goto continue
    end

    for _, edge in ipairs(graph.edges[current.node] or {}) do
      if not current.seen[edge.to] then
        local path = vim.deepcopy(current.path)
        table.insert(path, { from = current.node, edge = edge })

        if edge.to == to then
          shortest = shortest or #path
          table.insert(found, path)
          if #found >= max_paths then
            break
          end
        else
          local seen = vim.deepcopy(current.seen)
          seen[edge.to] = true
          table.insert(queue, { node = edge.to, path = path, seen = seen })
        end
      end
    end

    ::continue::
  end

  table.sort(found, function(a, b)
    return #a < #b
  end)
  return found
end

--- A short alias for a table name: `order_items` becomes `oi`.
---@param name string
---@param taken table<string, boolean>
---@return string
function M.alias(name, taken)
  local initials = {}
  for word in name:gmatch("[%w]+") do
    table.insert(initials, word:sub(1, 1))
  end
  local candidate = table.concat(initials):lower()
  if candidate == "" then
    candidate = name:sub(1, 1):lower()
  end

  local alias = candidate
  local suffix = 1
  while taken[alias] do
    suffix = suffix + 1
    alias = candidate .. suffix
  end
  taken[alias] = true
  return alias
end

--- Render a path as a `select`.
---@param path table[]
---@param opts { schema: string, from: string, qualify?: boolean }
---@return string[]
function M.render(path, opts)
  local taken = {}
  local aliases = { [opts.from] = M.alias(opts.from, taken) }

  local function qualified(name)
    if opts.qualify == false then
      return name
    end
    return ("%s.%s"):format(opts.schema, name)
  end

  local lines = {
    ("select %s.*"):format(aliases[opts.from]),
    ("from %s %s"):format(qualified(opts.from), aliases[opts.from]),
  }

  for _, step in ipairs(path) do
    local target = step.edge.to
    aliases[target] = aliases[target] or M.alias(target, taken)
    table.insert(
      lines,
      ("join %s %s on %s.%s = %s.%s"):format(
        qualified(target),
        aliases[target],
        aliases[target],
        step.edge.to_column,
        aliases[step.from],
        step.edge.from_column
      )
    )
  end

  table.insert(lines, "limit 100;")
  return lines
end

--- One-line description of a path, for the picker.
---@param path table[]
---@param from string
---@return string
function M.describe(path, from)
  if #path == 0 then
    return from
  end
  local parts = { from }
  for _, step in ipairs(path) do
    table.insert(parts, step.edge.to)
  end
  return ("%s   (%d join%s)"):format(
    table.concat(parts, " → "),
    #path,
    #path == 1 and "" or "s"
  )
end

--- Build a join between two tables and open it as a query.
---@param opts { session_id?: string, schema: string, from: string, to: string }
function M.build(opts)
  local target = session.get(opts.session_id)
  if not target then
    return notify("no active connection", vim.log.levels.WARN)
  end

  notify(("finding a path from %s to %s..."):format(opts.from, opts.to))

  client.async(function()
    local graph = M.graph(target.id, opts.schema)
    local paths = M.paths(graph, opts.from, opts.to)

    if #paths == 0 then
      return notify(
        ("no foreign key path connects %s and %s"):format(opts.from, opts.to),
        vim.log.levels.WARN
      )
    end

    local function open(path)
      local lines = M.render(path, { schema = opts.schema, from = opts.from })
      require("dbclient.ui.scratch").open({
        session_id = target.id,
        sql = table.concat(lines, "\n"),
      })
    end

    if #paths == 1 then
      return open(paths[1])
    end

    vim.ui.select(paths, {
      prompt = "join path",
      format_item = function(path)
        return M.describe(path, opts.from)
      end,
    }, function(choice)
      if choice then
        open(choice)
      end
    end)
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

--- Ask for the two tables, then build.
---@param opts? { session_id?: string, schema?: string, from?: string }
function M.prompt(opts)
  opts = opts or {}
  local target = session.get(opts.session_id)
  if not target then
    return notify("no active connection", vim.log.levels.WARN)
  end

  client.async(function()
    local schema = opts.schema
    if not schema then
      local schemas = session.schemas(target.id)
      schema = target.info and target.info.database
      if not schema or not vim.tbl_contains(
        vim.tbl_map(function(entry)
          return entry.name
        end, schemas),
        schema
      ) then
        schema = schemas[1] and schemas[1].name
      end
    end
    if not schema then
      return notify("no schema to search", vim.log.levels.WARN)
    end

    local names = {}
    for _, entry in ipairs(session.tables(target.id, schema)) do
      table.insert(names, entry.name)
    end

    local function pick(prompt, callback)
      vim.ui.select(names, { prompt = prompt }, function(choice)
        if choice then
          callback(choice)
        end
      end)
    end

    if opts.from then
      return pick("join " .. opts.from .. " to", function(to)
        M.build({ session_id = target.id, schema = schema, from = opts.from, to = to })
      end)
    end

    pick("join from", function(from)
      pick("join to", function(to)
        M.build({ session_id = target.id, schema = schema, from = from, to = to })
      end)
    end)
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

function M.invalidate()
  M.cache = {}
end

return M

--- The object sidebar.
---
--- Every configured connection is listed, not just the active one, and several
--- can be open at once: comparing dev against production is a normal thing to
--- want, and closing one connection to look at another loses the metadata cache
--- as well as your place.

local buffer = require("dbclient.ui.buffer")
local client = require("dbclient.core.client")
local config = require("dbclient.config")
local connections = require("dbclient.connections")
local help = require("dbclient.ui.help")
local highlights = require("dbclient.ui.highlights")
local keymap = require("dbclient.keymap")
local session = require("dbclient.session")

local M = {
  bufnr = nil,
  winid = nil,
  nodes = {},
  expanded = {},
  filter = nil,
}

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

local function is_open()
  return M.winid and vim.api.nvim_win_is_valid(M.winid)
end

-- ---------------------------------------------------------------------------
-- Tree construction
-- ---------------------------------------------------------------------------

local function matches_filter(text)
  if not M.filter or M.filter == "" then
    return true
  end
  return text:lower():find(M.filter:lower(), 1, true) ~= nil
end

local function add(nodes, node)
  table.insert(nodes, node)
  return node
end

--- Build the visible node list. Runs inside `client.async` because expanding a
--- node may need metadata that is not cached yet.
local function build()
  local nodes = {}
  local all = connections.all()
  local names = vim.tbl_keys(all)
  table.sort(names)

  for _, name in ipairs(names) do
    local spec = all[name]
    local target = session.find_by_name(name)
    local id = "connection:" .. name

    local marker = target and "●" or "○"
    local suffix = {}
    if spec.source == "project" then
      table.insert(suffix, "project")
    end
    if spec.access and spec.access ~= "write" then
      table.insert(suffix, spec.access)
    end
    if target and target.in_transaction then
      table.insert(suffix, "TX")
    end

    add(nodes, {
      id = id,
      kind = "connection",
      depth = 0,
      name = name,
      spec = spec,
      session_id = target and target.id,
      expandable = true,
      label = ("%s %s%s"):format(
        marker,
        name,
        #suffix > 0 and ("  (" .. table.concat(suffix, ", ") .. ")") or ""
      ),
      highlight = target and highlights.connection_group(spec.color) or "DBClientDetected",
    })

    if target and M.expanded[id] then
      local ok, schemas = pcall(session.schemas, target.id)
      if not ok then
        add(nodes, {
          id = id .. ":error",
          kind = "error",
          depth = 1,
          label = "! " .. tostring(schemas),
          highlight = "DBClientError",
        })
      else
        for _, schema in ipairs(schemas) do
          local schema_id = ("%s:schema:%s"):format(id, schema.name)
          add(nodes, {
            id = schema_id,
            kind = "schema",
            depth = 1,
            session_id = target.id,
            schema = schema.name,
            expandable = true,
            label = schema.name,
            highlight = "DBClientSchema",
          })

          if M.expanded[schema_id] then
            local tables_ok, tables = pcall(session.tables, target.id, schema.name)
            if tables_ok then
              for _, entry in ipairs(tables) do
                if matches_filter(entry.name) then
                  local table_id = ("%s:table:%s"):format(schema_id, entry.name)
                  local is_view = tostring(entry.kind):find("VIEW") ~= nil
                  add(nodes, {
                    id = table_id,
                    kind = "table",
                    depth = 2,
                    session_id = target.id,
                    schema = schema.name,
                    table = entry.name,
                    is_view = is_view,
                    expandable = true,
                    label = entry.name,
                    highlight = is_view and "DBClientView" or "DBClientTable",
                  })

                  if M.expanded[table_id] then
                    local columns_ok, columns =
                      pcall(session.columns, target.id, schema.name, entry.name)
                    if columns_ok then
                      for _, column in ipairs(columns) do
                        add(nodes, {
                          id = ("%s:column:%s"):format(table_id, column.name),
                          kind = "column",
                          depth = 3,
                          session_id = target.id,
                          schema = schema.name,
                          table = entry.name,
                          column = column.name,
                          label = ("%s  %s%s"):format(
                            column.name,
                            column.type,
                            column.key == "PRI" and "  PK" or ""
                          ),
                          highlight = column.key == "PRI" and "DBClientKey" or "DBClientColumn",
                        })
                      end
                    end
                  end
                end
              end
            end

            local routines_ok, routines = pcall(session.routines, target.id, schema.name)
            if routines_ok and #routines > 0 then
              local routines_id = schema_id .. ":routines"
              add(nodes, {
                id = routines_id,
                kind = "routines",
                depth = 2,
                session_id = target.id,
                schema = schema.name,
                expandable = true,
                label = ("routines (%d)"):format(#routines),
                highlight = "DBClientRoutine",
              })
              if M.expanded[routines_id] then
                for _, routine in ipairs(routines) do
                  if matches_filter(routine.name) then
                    add(nodes, {
                      id = ("%s:%s"):format(routines_id, routine.name),
                      kind = "routine",
                      depth = 3,
                      session_id = target.id,
                      schema = schema.name,
                      routine = routine.name,
                      arguments = routine.arguments,
                      label = ("%s %s"):format(tostring(routine.kind):lower(), routine.name),
                      highlight = "DBClientRoutine",
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

  if #nodes == 0 then
    add(nodes, {
      id = "empty",
      kind = "empty",
      depth = 0,
      label = "no connections; press a to add one",
      highlight = "DBClientDetected",
    })
  end

  return nodes
end

--- Redraw the tree.
function M.render()
  if not M.bufnr or not vim.api.nvim_buf_is_valid(M.bufnr) then
    return
  end

  client.async(function()
    local nodes = build()
    M.nodes = nodes

    local lines = {}
    local marks = {}
    for index, node in ipairs(nodes) do
      local indent = string.rep("  ", node.depth)
      local marker = "  "
      if node.expandable then
        marker = M.expanded[node.id] and "▾ " or "▸ "
      end
      table.insert(lines, indent .. marker .. node.label)
      if node.highlight then
        table.insert(marks, { line = index - 1, group = node.highlight })
      end
    end

    if M.filter and M.filter ~= "" then
      table.insert(lines, 1, ("filter: %s"):format(M.filter))
      for _, mark in ipairs(marks) do
        mark.line = mark.line + 1
      end
      table.insert(marks, 1, { line = 0, group = "DBClientTruncated" })
      table.insert(M.nodes, 1, { id = "filter", kind = "filter", depth = 0, label = "" })
    end

    buffer.set_lines(M.bufnr, lines)
    highlights.lines(M.bufnr, marks)
  end, function(err)
    buffer.set_lines(M.bufnr, { "! " .. tostring(err) })
  end)
end

local function node_at_cursor()
  if not is_open() then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(M.winid)[1]
  return M.nodes[row]
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

function M.open_node()
  local node = node_at_cursor()
  if not node then
    return
  end

  if node.kind == "connection" then
    if not node.session_id then
      return session.connect(node.name, function(target, err)
        if err then
          return notify(err, vim.log.levels.ERROR)
        end
        M.expanded[node.id] = true
        require("dbclient.completion").warm(target.id)
        M.render()
      end)
    end
    session.activate(node.session_id)
    M.expanded[node.id] = not M.expanded[node.id]
    return M.render()
  end

  if node.kind == "table" then
    return require("dbclient.ui.data").open({
      session_id = node.session_id,
      schema = node.schema,
      table = node.table,
    })
  end

  if node.kind == "routine" then
    local arguments = node.arguments and node.arguments ~= vim.NIL and tostring(node.arguments) or ""
    local placeholders = {}
    for _ in arguments:gmatch("[^,]+") do
      table.insert(placeholders, "?")
    end
    return require("dbclient.ui.query").open({
      session_id = node.session_id,
      sql = ("call %s.%s(%s);"):format(node.schema, node.routine, table.concat(placeholders, ", ")),
    })
  end

  if node.expandable then
    M.expanded[node.id] = not M.expanded[node.id]
    M.render()
  end
end

function M.expand()
  local node = node_at_cursor()
  if node and node.expandable and not M.expanded[node.id] then
    M.expanded[node.id] = true
    M.render()
  end
end

function M.collapse()
  local node = node_at_cursor()
  if not node then
    return
  end
  if node.expandable and M.expanded[node.id] then
    M.expanded[node.id] = false
    return M.render()
  end
  -- Otherwise jump to the parent, the way a file tree behaves.
  local row = vim.api.nvim_win_get_cursor(M.winid)[1]
  for index = row - 1, 1, -1 do
    if M.nodes[index] and M.nodes[index].depth < node.depth then
      pcall(vim.api.nvim_win_set_cursor, M.winid, { index, 0 })
      return
    end
  end
end

function M.open_data()
  local node = node_at_cursor()
  if node and node.table then
    require("dbclient.ui.data").open({
      session_id = node.session_id,
      schema = node.schema,
      table = node.table,
    })
  end
end

function M.open_ddl()
  local node = node_at_cursor()
  if not node then
    return
  end
  if node.table then
    return require("dbclient.ui.ddl").open({
      session_id = node.session_id,
      kind = node.is_view and "view" or "table",
      schema = node.schema,
      name = node.table,
    })
  end
  if node.routine then
    return require("dbclient.ui.ddl").open({
      session_id = node.session_id,
      kind = "routine",
      schema = node.schema,
      name = node.routine,
    })
  end
end

function M.inspect()
  local node = node_at_cursor()
  if not node then
    return
  end
  if node.column then
    return require("dbclient.ui.stats").show({
      session_id = node.session_id,
      schema = node.schema,
      table = node.table,
      column = node.column,
    })
  end
  if node.table then
    return M.show_indexes()
  end
  if node.schema then
    return M.table_sizes()
  end
end

function M.show_indexes()
  local node = node_at_cursor()
  if not node or not node.table then
    return
  end
  client.async(function()
    local indexes = session.indexes(node.session_id, node.schema, node.table)
    local keys = session.foreign_keys(node.session_id, node.schema, node.table)
    local rows = {}
    for _, index in ipairs(indexes) do
      table.insert(rows, {
        index.name,
        index.primary and "primary" or (index.unique and "unique" or ""),
        index.definition,
      })
    end
    for _, key in ipairs(keys) do
      table.insert(rows, {
        key.name,
        "foreign key",
        ("%s → %s.%s"):format(key.column, key.ref_table, key.ref_column),
      })
    end
    require("dbclient.ui.results").show({
      columns = {
        { name = "name", type = "text", class = "text" },
        { name = "kind", type = "text", class = "text" },
        { name = "definition", type = "text", class = "text" },
      },
      rows = rows,
      elapsed_ms = 0,
      affected_rows = 0,
    }, { session_id = node.session_id })
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

function M.table_sizes()
  local node = node_at_cursor()
  if not node or not node.schema then
    return
  end
  client.async(function()
    local result = session.table_sizes(node.session_id, node.schema)
    require("dbclient.ui.results").show(result, { session_id = node.session_id })
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

function M.open_query()
  local node = node_at_cursor()
  local target = node and node.session_id or nil
  require("dbclient.ui.query").open({ session_id = target })
end

function M.yank_name()
  local node = node_at_cursor()
  if not node then
    return
  end
  local parts = {}
  for _, key in ipairs({ "schema", "table", "column" }) do
    if node[key] then
      table.insert(parts, node[key])
    end
  end
  if node.routine then
    table.insert(parts, node.routine)
  end
  if #parts == 0 then
    return
  end
  local text = table.concat(parts, ".")
  vim.fn.setreg('"', text)
  vim.fn.setreg("+", text)
  notify("yanked " .. text)
end

function M.refresh()
  local node = node_at_cursor()
  if node and node.session_id then
    session.invalidate(node.session_id)
  end
  M.render()
end

function M.refresh_all()
  for _, target in ipairs(session.list()) do
    session.invalidate(target.id)
    require("dbclient.completion").warm(target.id, { force = true })
  end
  connections.rescan()
  M.render()
end

function M.filter_tree()
  vim.ui.input({ prompt = "filter ", default = M.filter or "" }, function(input)
    if input == nil then
      return
    end
    M.filter = vim.trim(input) ~= "" and input or nil
    M.render()
  end)
end

function M.clear_filter()
  M.filter = nil
  M.render()
end

function M.next_table(delta)
  if not is_open() then
    return
  end
  local row = vim.api.nvim_win_get_cursor(M.winid)[1]
  local candidates = {}
  for index, node in ipairs(M.nodes) do
    if node.kind == "table" then
      table.insert(candidates, index)
    end
  end
  if #candidates == 0 then
    return
  end

  if delta > 0 then
    for _, index in ipairs(candidates) do
      if index > row then
        return vim.api.nvim_win_set_cursor(M.winid, { index, 0 })
      end
    end
    return vim.api.nvim_win_set_cursor(M.winid, { candidates[1], 0 })
  end

  for position = #candidates, 1, -1 do
    if candidates[position] < row then
      return vim.api.nvim_win_set_cursor(M.winid, { candidates[position], 0 })
    end
  end
  vim.api.nvim_win_set_cursor(M.winid, { candidates[#candidates], 0 })
end

local function connection_ui()
  return require("dbclient.connections.ui")
end

function M.add_connection()
  connection_ui().create(function()
    M.render()
  end)
end

function M.edit_connection()
  local node = node_at_cursor()
  if not node or node.kind ~= "connection" then
    return notify("move onto a connection first", vim.log.levels.WARN)
  end
  connection_ui().edit(node.name, function()
    M.render()
  end)
end

function M.delete_connection()
  local node = node_at_cursor()
  if not node or node.kind ~= "connection" then
    return
  end
  connection_ui().delete(node.name, function()
    M.render()
  end)
end

function M.test_connection()
  local node = node_at_cursor()
  if not node or node.kind ~= "connection" then
    return
  end
  connection_ui().test(node.name)
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------

function M.open()
  if is_open() then
    return vim.api.nvim_set_current_win(M.winid)
  end

  M.bufnr = buffer.scratch("dbclient://sidebar", { modifiable = false })
  vim.bo[M.bufnr].filetype = "dbclient"

  vim.cmd(("topleft %dvnew"):format(config.get().ui.sidebar_width))
  M.winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.winid, M.bufnr)

  vim.wo[M.winid].number = false
  vim.wo[M.winid].relativenumber = false
  vim.wo[M.winid].cursorline = true
  vim.wo[M.winid].signcolumn = "no"
  vim.wo[M.winid].wrap = false
  vim.wo[M.winid].winfixwidth = true

  keymap.apply("sidebar", M.bufnr, {
    open_node = M.open_node,
    expand = M.expand,
    collapse = M.collapse,
    open_data = M.open_data,
    inspect = M.inspect,
    open_ddl = M.open_ddl,
    open_query = M.open_query,
    show_indexes = M.show_indexes,
    table_sizes = M.table_sizes,
    yank_name = M.yank_name,
    add_connection = M.add_connection,
    edit_connection = M.edit_connection,
    delete_connection = M.delete_connection,
    test_connection = M.test_connection,
    filter = M.filter_tree,
    clear_filter = M.clear_filter,
    next_table = function()
      M.next_table(1)
    end,
    prev_table = function()
      M.next_table(-1)
    end,
    refresh = M.refresh,
    refresh_all = M.refresh_all,
    close = M.close,
    help = help.handler("sidebar"),
  })

  M.render()
end

function M.close()
  if is_open() then
    pcall(vim.api.nvim_win_close, M.winid, false)
  end
  M.winid = nil
end

function M.toggle()
  if is_open() then
    M.close()
  else
    M.open()
  end
end

return M

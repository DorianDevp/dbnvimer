local config = require("dbclient.config")
local buffer = require("dbclient.ui.buffer")
local data = require("dbclient.ui.data")
local highlights = require("dbclient.ui.highlights")
local inspect = require("dbclient.ui.inspect")
local query = require("dbclient.ui.query")
local state = require("dbclient.state")
local window = require("dbclient.ui.window")

local M = {
  buf = nil,
  win = nil,
  nodes = {},
  expanded = {},
  table_matches = {},
  table_match_index = 0,
}

local function valid_window()
  return M.win and vim.api.nvim_win_is_valid(M.win)
end

local function line_for(node)
  local prefix = string.rep("  ", node.depth)
  local marker = node.expandable and (M.expanded[node.id] and "v " or "> ") or "  "
  return prefix .. marker .. node.label
end

local function add_node(nodes, node)
  table.insert(nodes, node)
end

local function build_nodes()
  local nodes = {}

  add_node(nodes, {
    id = "connection:" .. (state.active_name or "none"),
    kind = "connection",
    depth = 0,
    label = "[db] " .. (state.active_name or "no connection"),
    expandable = true,
  })

  if state.active_name and M.expanded[nodes[1].id] == nil then
    M.expanded[nodes[1].id] = true
  end

  if state.active_name and M.expanded[nodes[1].id] then
    for _, schema in ipairs(state.schemas(false)) do
      local schema_id = "schema:" .. schema
      add_node(nodes, {
        id = schema_id,
        kind = "schema",
        schema = schema,
        depth = 1,
        label = "[schema] " .. schema,
        expandable = true,
      })

      if M.expanded[schema_id] then
        local tables_group_id = "tables:" .. schema
        if M.expanded[tables_group_id] == nil then
          M.expanded[tables_group_id] = true
        end
        add_node(nodes, {
          id = tables_group_id,
          kind = "tables",
          schema = schema,
          depth = 2,
          label = "tables",
          expandable = true,
        })

        if M.expanded[tables_group_id] then
          for _, table_info in ipairs(state.tables(schema, false)) do
            local table_id = "table:" .. schema .. "." .. table_info.name
            add_node(nodes, {
              id = table_id,
              kind = "table",
              schema = schema,
              table = table_info.name,
              depth = 3,
              label = "[table] " .. table_info.name,
              expandable = true,
            })

            if M.expanded[table_id] then
              for _, column in ipairs(state.columns(schema, table_info.name, false)) do
                add_node(nodes, {
                  id = "column:" .. schema .. "." .. table_info.name .. "." .. column.name,
                  kind = "column",
                  depth = 4,
                  label = "[col] " .. column.name .. " : " .. column.type,
                })
              end
            end
          end
        end

        local routines_group_id = "routines:" .. schema
        add_node(nodes, {
          id = routines_group_id,
          kind = "routines",
          schema = schema,
          depth = 2,
          label = "procedures/functions",
          expandable = true,
        })

        if M.expanded[routines_group_id] then
          for _, routine in ipairs(state.routines(schema, false)) do
            add_node(nodes, {
              id = "routine:" .. schema .. "." .. routine.name,
              kind = "routine",
              schema = schema,
              routine = routine.name,
              depth = 3,
              label = "[" .. routine.kind:lower() .. "] " .. routine.name,
            })
          end
        end
      end
    end
  end

  return nodes
end

function M.render()
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    return
  end

  local ok, nodes = pcall(build_nodes)
  if not ok then
    nodes = {
      {
        id = "error",
        kind = "error",
        depth = 0,
        label = "[error] " .. nodes,
      },
    }
  end

  M.nodes = nodes
  local lines = vim.tbl_map(line_for, nodes)
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  highlights.sidebar(M.buf, nodes)
end

local function node_under_cursor()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return M.nodes[row]
end

function M.open_node()
  local node = node_under_cursor()
  if not node then
    return
  end

  if node.kind == "connection" and not state.active_name then
    require("dbclient").pick_connection()
    return
  end

  if node.kind == "routine" then
    query.open_with("call " .. node.schema .. "." .. node.routine .. "();")
    return
  end

  if node.expandable then
    M.expanded[node.id] = not M.expanded[node.id]
    M.render()
  end
end

local function visible_tables()
  local tables = {}
  for index, node in ipairs(M.nodes) do
    if node.kind == "table" then
      table.insert(tables, { index = index, node = node })
    end
  end
  return tables
end

local function jump_to_line(line)
  if valid_window() then
    vim.api.nvim_win_set_cursor(M.win, { line, 0 })
  end
end

function M.next_table(delta)
  local tables = visible_tables()
  if #tables == 0 then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(M.win)[1]
  local fallback = delta > 0 and tables[1] or tables[#tables]
  for _, item in ipairs(delta > 0 and tables or vim.fn.reverse(vim.deepcopy(tables))) do
    if (delta > 0 and item.index > cursor) or (delta < 0 and item.index < cursor) then
      jump_to_line(item.index)
      return
    end
  end
  jump_to_line(fallback.index)
end

function M.search_table()
  vim.ui.input({ prompt = "table /" }, function(pattern)
    if not pattern or pattern == "" then
      return
    end

    M.table_matches = {}
    for _, item in ipairs(visible_tables()) do
      if item.node.table:lower():find(pattern:lower(), 1, true) then
        table.insert(M.table_matches, item.index)
      end
    end

    M.table_match_index = 0
    M.next_table_match()
  end)
end

function M.next_table_match()
  if #M.table_matches == 0 then
    vim.notify("DBClient: no table matches", vim.log.levels.WARN)
    return
  end
  M.table_match_index = (M.table_match_index % #M.table_matches) + 1
  jump_to_line(M.table_matches[M.table_match_index])
end

function M.open_data()
  local node = node_under_cursor()
  if node and node.kind == "table" then
    data.open(node.schema, node.table)
  end
end

function M.inspect_object()
  local node = node_under_cursor()
  if not node then
    return
  end
  if node.kind == "schema" then
    inspect.schema(node.schema)
  elseif node.kind == "table" then
    inspect.table(node.schema, node.table)
  end
end

function M.refresh()
  if state.active_name then
    state.invalidate()
    state.schemas(true)
  end
  M.render()
end

function M.open()
  if valid_window() then
    vim.api.nvim_set_current_win(M.win)
    return
  end

  M.buf, M.win = buffer.open_named("DBClient", "topleft " .. config.get().ui.sidebar_width .. "vnew")
  vim.bo[M.buf].buftype = "nofile"
  vim.bo[M.buf].bufhidden = "hide"
  vim.bo[M.buf].swapfile = false
  vim.bo[M.buf].filetype = "dbclient"
  vim.bo[M.buf].modifiable = false
  M.buf = buffer.set_name(M.buf, "DBClient")
  vim.wo[M.win].number = false
  vim.wo[M.win].relativenumber = false
  vim.wo[M.win].cursorline = true
  vim.wo[M.win].signcolumn = "no"

  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = M.buf, silent = true })
  vim.keymap.set("n", "<CR>", M.open_node, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "o", M.open_node, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "gd", M.open_data, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "gs", M.inspect_object, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "gq", query.open, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "r", M.refresh, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "e", query.open, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "]t", function() M.next_table(1) end, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "[t", function() M.next_table(-1) end, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "s", M.search_table, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "n", M.next_table_match, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "F", window.toggle_fullscreen, { buffer = M.buf, silent = true })

  M.render()
end

return M

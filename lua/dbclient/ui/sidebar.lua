local config = require("dbclient.config")
local query = require("dbclient.ui.query")
local state = require("dbclient.state")

local M = {
  buf = nil,
  win = nil,
  nodes = {},
  expanded = {},
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
        for _, table_info in ipairs(state.tables(schema, false)) do
          local table_id = "table:" .. schema .. "." .. table_info.name
          add_node(nodes, {
            id = table_id,
            kind = "table",
            schema = schema,
            table = table_info.name,
            depth = 2,
            label = "[table] " .. table_info.name,
            expandable = true,
          })

          if M.expanded[table_id] then
            for _, column in ipairs(state.columns(schema, table_info.name, false)) do
              add_node(nodes, {
                id = "column:" .. schema .. "." .. table_info.name .. "." .. column.name,
                kind = "column",
                depth = 3,
                label = "[col] " .. column.name .. " : " .. column.type,
              })
            end
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

  if node.expandable then
    M.expanded[node.id] = not M.expanded[node.id]
    M.render()
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

  vim.cmd("topleft " .. config.get().ui.sidebar_width .. "vnew")
  M.win = vim.api.nvim_get_current_win()
  M.buf = vim.api.nvim_get_current_buf()
  vim.bo[M.buf].buftype = "nofile"
  vim.bo[M.buf].bufhidden = "hide"
  vim.bo[M.buf].swapfile = false
  vim.bo[M.buf].filetype = "dbclient"
  vim.bo[M.buf].modifiable = false
  vim.wo[M.win].number = false
  vim.wo[M.win].relativenumber = false
  vim.wo[M.win].signcolumn = "no"
  vim.api.nvim_buf_set_name(M.buf, "DBClient")

  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = M.buf, silent = true })
  vim.keymap.set("n", "<CR>", M.open_node, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "o", M.open_node, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "r", M.refresh, { buffer = M.buf, silent = true })
  vim.keymap.set("n", "e", query.open, { buffer = M.buf, silent = true })

  M.render()
end

return M

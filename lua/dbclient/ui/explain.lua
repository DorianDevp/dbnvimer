--- Query plans as a foldable tree.
---
--- A flat table of plan rows is nearly unreadable. A tree with folds, per-node
--- cost, and — the part that actually answers "why is this slow" — the ratio
--- between estimated and actual rows, is not.

local client = require("dbclient.core.client")
local help = require("dbclient.ui.help")
local highlights = require("dbclient.ui.highlights")
local keymap = require("dbclient.keymap")
local session = require("dbclient.session")
local window = require("dbclient.ui.window")

local M = {
  views = {},
}

--- Threshold at which an estimate is called out as wrong.
local MISESTIMATE_FACTOR = 100

local function number(value)
  local numeric = tonumber(value)
  if not numeric then
    return tostring(value)
  end
  if numeric >= 1e9 then
    return ("%.1fG"):format(numeric / 1e9)
  end
  if numeric >= 1e6 then
    return ("%.1fM"):format(numeric / 1e6)
  end
  if numeric >= 1e3 then
    return ("%.1fk"):format(numeric / 1e3)
  end
  return ("%d"):format(numeric)
end

--- Flatten a PostgreSQL JSON plan into display rows.
---@param node table
---@param depth integer
---@param out table[]
---@param totals table
local function walk_postgres(node, depth, out, totals)
  local label = node["Node Type"] or "Node"
  local details = {}

  if node["Relation Name"] then
    table.insert(details, "on " .. node["Relation Name"])
  end
  if node["Index Name"] then
    table.insert(details, "using " .. node["Index Name"])
  end
  if node["Join Type"] then
    table.insert(details, node["Join Type"] .. " join")
  end

  local estimated = tonumber(node["Plan Rows"])
  local actual = tonumber(node["Actual Rows"])
  local cost = tonumber(node["Total Cost"])
  local time = tonumber(node["Actual Total Time"])

  local misestimate = nil
  if estimated and actual and estimated > 0 then
    local ratio = math.max(actual, 1) / estimated
    if ratio >= MISESTIMATE_FACTOR or (ratio > 0 and 1 / ratio >= MISESTIMATE_FACTOR) then
      misestimate = ratio >= 1 and ratio or (1 / ratio)
    end
  end

  if cost then
    totals.max_cost = math.max(totals.max_cost, cost)
  end
  if time then
    totals.max_time = math.max(totals.max_time, time)
  end

  table.insert(out, {
    depth = depth,
    label = label,
    details = table.concat(details, " "),
    cost = cost,
    time = time,
    estimated = estimated,
    actual = actual,
    misestimate = misestimate,
    loops = tonumber(node["Actual Loops"]),
  })

  for _, child in ipairs(node["Plans"] or {}) do
    walk_postgres(child, depth + 1, out, totals)
  end
end

--- Flatten a MySQL/MariaDB JSON plan.
local function walk_mysql(node, depth, out, totals, label)
  if type(node) ~= "table" then
    return
  end

  local entry_label = label
  local details = {}

  if node.table_name then
    table.insert(details, "on " .. node.table_name)
  end
  if node.access_type then
    table.insert(details, node.access_type)
  end
  if node.key then
    table.insert(details, "using " .. node.key)
  end

  local rows = tonumber(node.rows_examined_per_scan) or tonumber(node.rows) or tonumber(node.r_rows)
  local cost = tonumber(node.cost_info and node.cost_info.query_cost)
    or tonumber(node.cost_info and node.cost_info.read_cost)

  if entry_label then
    if cost then
      totals.max_cost = math.max(totals.max_cost, cost)
    end
    table.insert(out, {
      depth = depth,
      label = entry_label,
      details = table.concat(details, " "),
      cost = cost,
      estimated = rows,
      actual = tonumber(node.r_rows),
      filtered = node.filtered,
    })
    depth = depth + 1
  end

  for key, child in pairs(node) do
    if type(child) == "table" and key ~= "cost_info" then
      if vim.islist(child) then
        for _, item in ipairs(child) do
          walk_mysql(item, depth, out, totals, key)
        end
      else
        walk_mysql(child, depth, out, totals, key)
      end
    end
  end
end

--- Render a tabular plan.
---
--- SQLite's `explain query plan` is a table with `id`, `parent` and `detail`
--- columns that describe a tree; rendering it as rows throws that structure
--- away, so it is rebuilt here. Anything else falls back to aligned columns.
---@param payload { columns: table[], rows: table[] }
---@return string[] lines, table[] marks, table[] nodes
function M.render_table(payload)
  local columns = payload.columns or {}
  local rows = payload.rows or {}

  local index_of = {}
  for index, column in ipairs(columns) do
    index_of[column.name:lower()] = index
  end

  local lines = {}
  local marks = {}

  if index_of.id and index_of.parent and index_of.detail then
    local children = {}
    for _, row in ipairs(rows) do
      local parent = tostring(row[index_of.parent] or "0")
      children[parent] = children[parent] or {}
      table.insert(children[parent], row)
    end

    local function walk(parent, depth)
      for _, row in ipairs(children[parent] or {}) do
        local detail = tostring(row[index_of.detail] or "")
        table.insert(lines, ("%s%s"):format(string.rep("  ", depth), detail))
        -- A full table scan is the thing worth spotting in a SQLite plan.
        if detail:match("^SCAN") and not detail:match("USING") then
          table.insert(marks, { line = #lines - 1, group = "DBClientPlanHot" })
        end
        walk(tostring(row[index_of.id]), depth + 1)
      end
    end

    walk("0", 0)
    if #lines > 0 then
      return lines, marks, {}
    end
  end

  local widths = {}
  for index, column in ipairs(columns) do
    widths[index] = #column.name
    for _, row in ipairs(rows) do
      local value = row[index]
      widths[index] = math.max(widths[index], #(value == vim.NIL and "" or tostring(value)))
    end
  end

  for _, row in ipairs(rows) do
    local cells = {}
    for index in ipairs(columns) do
      local value = row[index]
      cells[index] = ("%-" .. widths[index] .. "s"):format(value == vim.NIL and "" or tostring(value))
    end
    table.insert(lines, vim.trim(table.concat(cells, "  ")))
  end

  return lines, marks, {}
end

--- Convert a plan payload into rendered lines plus highlight marks.
---@param payload table
---@return string[] lines, table[] marks, table[] nodes
function M.render(payload)
  local nodes = {}
  local totals = { max_cost = 0, max_time = 0 }

  if payload.format == "postgres-json" then
    local plan = payload.plan
    local root = plan
    if vim.islist(plan) and plan[1] then
      root = plan[1].Plan or plan[1]
    end
    if root then
      walk_postgres(root, 0, nodes, totals)
    end
  elseif payload.format == "mysql-json" then
    local plan = payload.plan
    walk_mysql(plan.query_block or plan, 0, nodes, totals, "query")
  elseif payload.format == "table" then
    return M.render_table(payload.table)
  end

  local lines = {}
  local marks = {}

  for index, node in ipairs(nodes) do
    local indent = string.rep("  ", node.depth)
    local stats = {}

    if node.cost then
      table.insert(stats, ("cost %s"):format(number(node.cost)))
    end
    if node.time then
      table.insert(stats, ("%.2f ms"):format(node.time))
    end
    if node.actual and node.estimated then
      table.insert(stats, ("rows %s/%s"):format(number(node.actual), number(node.estimated)))
    elseif node.estimated then
      table.insert(stats, ("rows ~%s"):format(number(node.estimated)))
    end
    if node.loops and node.loops > 1 then
      table.insert(stats, ("loops %d"):format(node.loops))
    end

    local text = ("%s%s %s"):format(indent, node.label, node.details)
    if #stats > 0 then
      text = ("%-60s %s"):format(text, table.concat(stats, "  "))
    end
    table.insert(lines, text)

    -- Heat by share of the most expensive node.
    local group = "DBClientPlanCheap"
    local weight = node.time and totals.max_time > 0 and (node.time / totals.max_time)
      or (node.cost and totals.max_cost > 0 and (node.cost / totals.max_cost))
      or 0
    if weight >= 0.6 then
      group = "DBClientPlanHot"
    elseif weight >= 0.25 then
      group = "DBClientPlanWarm"
    end
    table.insert(marks, { line = index - 1, group = group })
    node.line = index - 1
    node.weight = weight

    if node.misestimate then
      table.insert(lines, ("%s  ! estimate off by %sx"):format(indent, number(node.misestimate)))
      table.insert(marks, { line = #lines - 1, group = "DBClientPlanMisestimate" })
    end
  end

  if #lines == 0 then
    lines = { "the server returned an empty plan" }
  end

  return lines, marks, nodes
end

--- Fetch and display a plan.
---@param opts { session_id?: string, sql: string, analyze?: boolean }
function M.show(opts)
  client.async(function()
    local payload = session.explain(opts.session_id, opts.sql, opts.analyze)
    local lines, marks, nodes = M.render(payload)

    local header = ("%s  ·  %s"):format(
      opts.analyze and "EXPLAIN ANALYZE" or "EXPLAIN",
      opts.sql:gsub("%s+", " "):sub(1, 80)
    )
    table.insert(lines, 1, header)
    table.insert(lines, 2, "")
    for _, mark in ipairs(marks) do
      mark.line = mark.line + 2
    end
    for _, node in ipairs(nodes) do
      node.line = node.line + 2
    end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].filetype = "dbclient-plan"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false

    local winid = window.float(bufnr, {
      title = "query plan",
      max_width = 0.95,
      max_height = 0.85,
    })

    highlights.lines(bufnr, marks)
    highlights.lines(bufnr, { { line = 0, group = "DBClientHeader" } }, highlights.ns_virt)

    M.views[bufnr] = { nodes = nodes, opts = opts, winid = winid }

    -- Folds follow the indentation of the tree, so `zc` collapses a subtree.
    vim.wo[winid].foldmethod = "indent"
    vim.wo[winid].foldlevel = 99

    keymap.apply("explain", bufnr, {
      toggle_fold = function()
        pcall(vim.cmd, "normal! za")
      end,
      worst_node = function()
        local worst, best_weight = nil, -1
        for _, node in ipairs(nodes) do
          if (node.weight or 0) > best_weight then
            worst, best_weight = node, node.weight or 0
          end
        end
        if worst then
          pcall(vim.api.nvim_win_set_cursor, winid, { worst.line + 1, 0 })
        end
      end,
      rerun = function()
        window.close(winid, bufnr)
        M.show(opts)
      end,
      analyze = function()
        window.close(winid, bufnr)
        M.show(vim.tbl_extend("force", opts, { analyze = true }))
      end,
      close = function()
        window.close(winid, bufnr)
      end,
      help = help.handler("explain"),
    })
    window.close_keys(bufnr, winid)
  end, function(err)
    vim.notify("DBClient: " .. err, vim.log.levels.ERROR)
  end)
end

return M

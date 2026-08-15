--- Hypothetical indexes: would this index help, before building it.
---
--- Creating an index on a large table is an expensive, sometimes locking,
--- occasionally regrettable operation, and the only way most people find out
--- whether it helps is by doing it. PostgreSQL's HypoPG extension registers an
--- index the planner can see but that occupies no disk, so the plan can be
--- compared before and after for nothing.
---
--- MySQL and MariaDB have no equivalent; rather than pretend, this says so and
--- points at what can be answered there.

local client = require("dbclient.core.client")
local highlights = require("dbclient.ui.highlights")
local session = require("dbclient.session")
local window = require("dbclient.ui.window")

local M = {}

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

--- Is HypoPG installed on this connection?
--- Must run inside `client.async`.
---@param session_id string
---@return boolean available, string|nil reason
function M.available(session_id)
  local target = session.get(session_id)
  if not target then
    return false, "no connection"
  end
  if target.spec.adapter ~= "postgres" then
    return false,
      ("%s has no hypothetical indexes; :DBClientIndexes shows real index usage instead"):format(
        target.spec.adapter
      )
  end

  local ok, result = pcall(
    session.query,
    session_id,
    "select extversion from pg_extension where extname = 'hypopg'"
  )
  if not ok or #(result.rows or {}) == 0 then
    return false,
      "HypoPG is not installed on this database. Install it with: create extension hypopg;"
  end
  return true, nil
end

--- Total cost of the top plan node.
---@param plan table
---@return number|nil
local function total_cost(plan)
  local root = plan.plan
  if type(root) ~= "table" then
    return nil
  end
  if vim.islist(root) then
    root = root[1] and (root[1].Plan or root[1])
  end
  if type(root) ~= "table" then
    return nil
  end
  return tonumber(root["Total Cost"])
end

--- The node types a plan uses, so a Seq Scan turning into an Index Scan shows.
---@param plan table
---@return string[]
local function node_types(plan)
  local found = {}
  local function walk(node)
    if type(node) ~= "table" then
      return
    end
    if node["Node Type"] then
      table.insert(found, node["Node Type"])
    end
    for _, child in ipairs(node["Plans"] or {}) do
      walk(child)
    end
  end

  local root = plan.plan
  if vim.islist(root) then
    root = root[1] and (root[1].Plan or root[1])
  end
  walk(root)
  return found
end

--- Try an index and report what the planner does with it.
--- Must run inside `client.async`.
---@param opts { session_id: string, sql: string, index: string }
---@return table
function M.try(opts)
  local before = session.explain(opts.session_id, opts.sql, false)

  -- Register the hypothetical index, re-plan, then drop it again. The reset is
  -- in a pcall chain so a failure cannot leave a phantom index behind for the
  -- rest of the session.
  local created = session.query(
    opts.session_id,
    ("select indexrelid, indexname from hypopg_create_index(%s)"):format(
      "'" .. opts.index:gsub("'", "''") .. "'"
    )
  )

  local name = created.rows[1] and created.rows[1][2] or "hypothetical"
  local ok, after = pcall(session.explain, opts.session_id, opts.sql, false)
  pcall(session.query, opts.session_id, "select hypopg_reset()")

  if not ok then
    error(after, 0)
  end

  return {
    index = opts.index,
    name = name,
    before = before,
    after = after,
    cost_before = total_cost(before),
    cost_after = total_cost(after),
    nodes_before = node_types(before),
    nodes_after = node_types(after),
  }
end

--- Render the comparison.
---@param report table
---@return string[] lines, table[] marks
function M.report(report)
  local lines = {}
  local marks = {}

  local function add(text, group)
    table.insert(lines, text)
    if group then
      table.insert(marks, { line = #lines - 1, group = group })
    end
  end

  local before = report.cost_before
  local after = report.cost_after
  local verdict, group

  if before and after and before > 0 then
    local ratio = after / before
    if ratio <= 0.5 then
      verdict = ("%.1fx cheaper"):format(before / math.max(after, 0.01))
      group = "DBClientPlanCheap"
    elseif ratio < 0.95 then
      verdict = ("%.0f%% cheaper"):format((1 - ratio) * 100)
      group = "DBClientPlanWarm"
    elseif ratio <= 1.05 then
      verdict = "no measurable difference — the planner would not use it"
      group = "DBClientPlanHot"
    else
      verdict = "more expensive; the planner ignores it and pays for the estimate"
      group = "DBClientPlanHot"
    end
  else
    verdict = "the plans could not be compared"
    group = "DBClientPlanHot"
  end

  add(report.index, "DBClientHeader")
  add("")
  add(verdict, group)
  add("")
  add(("cost   %s  →  %s"):format(
    before and ("%.2f"):format(before) or "?",
    after and ("%.2f"):format(after) or "?"
  ))

  local function summarise(nodes)
    local seen, order = {}, {}
    for _, node in ipairs(nodes) do
      if not seen[node] then
        seen[node] = true
        table.insert(order, node)
      end
    end
    return table.concat(order, ", ")
  end

  add(("plan   %s"):format(summarise(report.nodes_before)))
  add(("  →    %s"):format(summarise(report.nodes_after)))

  local used = false
  for _, node in ipairs(report.nodes_after) do
    if node:find("Index") then
      used = true
    end
  end
  add("")
  if used then
    add("The planner chose the index.", "DBClientPlanCheap")
    add("")
    add("To build it for real:", "DBClientHelpText")
    add("  " .. report.index .. ";")
  else
    add("The planner did not choose it, so building it would cost disk and", "DBClientPlanHot")
    add("write time for nothing.", "DBClientPlanHot")
  end

  add("")
  add("Nothing was created; the hypothetical index is already gone.", "DBClientHelpText")

  return lines, marks
end

--- Ask what index to try, then try it.
---@param opts { session_id?: string, sql?: string, table?: string, column?: string }
function M.prompt(opts)
  opts = opts or {}
  local target = session.get(opts.session_id)
  if not target then
    return notify("no active connection", vim.log.levels.WARN)
  end

  client.async(function()
    local available, reason = M.available(target.id)
    if not available then
      return notify(reason, vim.log.levels.WARN)
    end

    local sql = opts.sql
    if not sql then
      local view = require("dbclient.ui.results").view()
      sql = view and view.sql
    end
    if not sql or not sql:match("%S") then
      return notify("run the query you want to speed up first", vim.log.levels.WARN)
    end

    local suggestion = opts.table
        and opts.column
        and ("create index on %s (%s)"):format(opts.table, opts.column)
      or "create index on "

    vim.schedule(function()
      vim.ui.input({ prompt = "hypothetical index ", default = suggestion }, function(index)
        if not index or not index:match("%S") then
          return
        end
        client.async(function()
          local report = M.try({ session_id = target.id, sql = sql, index = index })
          local lines, marks = M.report(report)

          local bufnr = vim.api.nvim_create_buf(false, true)
          vim.bo[bufnr].bufhidden = "wipe"
          vim.bo[bufnr].filetype = "dbclient-hypo"
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
          vim.bo[bufnr].modifiable = false

          local winid = window.float(bufnr, {
            title = "what if this index existed",
            max_width = 0.85,
            max_height = 0.7,
            cursorline = false,
          })
          highlights.lines(bufnr, marks)
          window.close_keys(bufnr, winid)
        end, function(err)
          notify(err, vim.log.levels.ERROR)
        end)
      end)
    end)
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

M.total_cost = total_cost
M.node_types = node_types

return M

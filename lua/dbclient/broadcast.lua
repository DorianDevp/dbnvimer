--- Run one statement against several connections at once.
---
--- For sharded or multi-tenant setups the question is rarely "what does this
--- return" but "does it return the same thing everywhere". The summary is
--- therefore the primary output and the individual result sets are secondary.

local client = require("dbclient.core.client")
local session = require("dbclient.session")

local M = {}

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

--- A stable fingerprint of a result set, so identical answers group together.
---@param result table
---@return string
local function fingerprint(result)
  local parts = {}
  for _, row in ipairs(result.rows or {}) do
    local cells = {}
    for _, value in ipairs(row) do
      table.insert(cells, value == nil or value == vim.NIL and "\0" or tostring(value))
    end
    table.insert(parts, table.concat(cells, "\1"))
  end
  table.sort(parts)
  return table.concat(parts, "\2")
end

--- Execute `sql` on every listed session and show a comparison.
---@param opts { sql: string, sessions?: table[], limit?: integer }
function M.run(opts)
  local targets = opts.sessions or session.list()
  if #targets == 0 then
    return notify("no connections are open", vim.log.levels.WARN)
  end

  local pending = #targets
  local outcomes = {}

  for index, target in ipairs(targets) do
    client.async(function()
      local result = client.call(
        "query",
        { sql = opts.sql, limit = opts.limit or 1000 },
        target.id
      )
      outcomes[index] = { target = target, result = result, ok = true }
      pending = pending - 1
    end, function(err)
      outcomes[index] = { target = target, error = err, ok = false }
      pending = pending - 1
    end)
  end

  local waited = 0
  local timer = vim.uv.new_timer()
  timer:start(
    100,
    100,
    vim.schedule_wrap(function()
      waited = waited + 100
      if pending > 0 and waited < 120000 then
        return
      end
      timer:stop()
      timer:close()
      M.report(opts.sql, outcomes, targets)
    end)
  )
end

--- Build and show the comparison buffer.
---@param sql string
---@param outcomes table[]
---@param targets table[]
function M.report(sql, outcomes, targets)
  local groups = {}
  local order = {}

  for index = 1, #targets do
    local outcome = outcomes[index]
    if outcome and outcome.ok then
      local key = fingerprint(outcome.result)
      if not groups[key] then
        groups[key] = { members = {}, result = outcome.result }
        table.insert(order, key)
      end
      table.insert(groups[key].members, outcome.target.name)
    end
  end

  local columns = {
    { name = "connection", type = "text", class = "text" },
    { name = "rows", type = "int", class = "number" },
    { name = "ms", type = "int", class = "number" },
    { name = "group", type = "text", class = "text" },
    { name = "status", type = "text", class = "text" },
  }

  local rows = {}
  for index = 1, #targets do
    local outcome = outcomes[index]
    local target = targets[index]
    if not outcome then
      table.insert(rows, { target.name, "", "", "", "no answer" })
    elseif outcome.ok then
      local key = fingerprint(outcome.result)
      local group = 0
      for position, candidate in ipairs(order) do
        if candidate == key then
          group = position
        end
      end
      table.insert(rows, {
        target.name,
        tostring(#(outcome.result.rows or {})),
        tostring(outcome.result.elapsed_ms or 0),
        ("#%d"):format(group),
        "ok",
      })
    else
      table.insert(rows, { target.name, "", "", "", "error: " .. tostring(outcome.error) })
    end
  end

  local notices = {}
  if #order <= 1 then
    table.insert(notices, "every connection returned the same rows")
  else
    table.insert(notices, ("%d distinct results across %d connections"):format(#order, #targets))
    for position, key in ipairs(order) do
      table.insert(
        notices,
        ("  #%d  %s"):format(position, table.concat(groups[key].members, ", "))
      )
    end
  end

  require("dbclient.ui.results").show({
    columns = columns,
    rows = rows,
    elapsed_ms = 0,
    affected_rows = 0,
    notices = notices,
    kind = "broadcast",
  }, { session_name = "broadcast", sql = sql })
end

--- Prompt for the statement and the connections, then broadcast.
function M.prompt()
  local sessions = session.list()
  if #sessions == 0 then
    return notify("connect first", vim.log.levels.WARN)
  end

  local default = ""
  local view = require("dbclient.ui.results").view()
  if view and view.sql then
    default = view.sql
  end

  vim.ui.input({ prompt = "broadcast sql ", default = default }, function(sql)
    if not sql or not sql:match("%S") then
      return
    end
    -- Broadcasting a write to every environment at once is not something to
    -- do by accident.
    client.async(function()
      local diagnostics = client.call("lint-sql", { sql = sql }).diagnostics or {}
      local risky = vim.tbl_filter(function(entry)
        return entry.severity == "error" or entry.code == "destructive"
      end, diagnostics)

      local function go()
        M.run({ sql = sql, sessions = sessions })
        notify(("running on %d connection(s)"):format(#sessions))
      end

      if #risky == 0 then
        return go()
      end

      vim.schedule(function()
        vim.ui.select({ "no", "yes" }, {
          prompt = ("%s — run it on all %d connections?"):format(risky[1].message, #sessions),
        }, function(choice)
          if choice == "yes" then
            go()
          end
        end)
      end)
    end, function(err)
      notify(err, vim.log.levels.ERROR)
    end)
  end)
end

M.fingerprint = fingerprint

return M

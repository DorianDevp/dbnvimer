--- Blast radius: show which rows a write would touch, before it touches them.
---
--- The failure that actually costs people is not a syntax error, it is a
--- `WHERE` that matches more than they thought. The core rewrites the statement
--- into the equivalent `SELECT`, so this preview is of exactly the rows the
--- write will hit rather than an approximation, and the count comes from the
--- server rather than from the previewed page.

local client = require("dbclient.core.client")
local config = require("dbclient.config")
local grid = require("dbclient.ui.grid")
local highlights = require("dbclient.ui.highlights")
local window = require("dbclient.ui.window")

local M = {}

local PREVIEW_ROWS = 50

--- Ask the core what a statement would affect.
--- Must run inside `client.async`.
---@param session_id string
---@param sql string
---@return table  `{ supported, count, kind, result, reason }`
function M.inspect(session_id, sql)
  return client.call("blast-radius", { sql = sql, limit = PREVIEW_ROWS }, session_id)
end

--- Render the preview into display lines.
---@param report table
---@param opts { sql: string, connection?: string, warnings?: string[] }
---@return string[] lines, table[] marks
function M.lines(report, opts)
  local lines = {}
  local marks = {}

  local function add(text, group)
    table.insert(lines, text)
    if group then
      table.insert(marks, { line = #lines - 1, group = group })
    end
  end

  local verb = (report.kind or "statement"):upper()
  add(
    ("%s would affect %d row(s)%s"):format(
      verb,
      report.count or 0,
      opts.connection and (" on " .. opts.connection) or ""
    ),
    (report.count or 0) > 0 and "DBClientPlanHot" or "DBClientHeader"
  )
  add("")

  for _, warning in ipairs(opts.warnings or {}) do
    add("! " .. warning, "DBClientPlanMisestimate")
  end
  if #(opts.warnings or {}) > 0 then
    add("")
  end

  for _, line in ipairs(vim.split(vim.trim(opts.sql), "\n")) do
    add("  " .. line, "DBClientHelpText")
  end
  add("")

  local result = report.result or {}
  local columns = result.columns or {}
  local rows = result.rows or {}

  if #rows == 0 then
    add("no rows match; the statement would change nothing", "DBClientDetected")
  else
    local sizes = grid.widths(columns, rows)
    local header, underline = grid.render_header(columns, sizes)
    add(header, "DBClientHeader")
    add(underline, "DBClientSeparator")
    for _, row in ipairs(rows) do
      add((grid.render_row(row, columns, sizes)))
    end
    if (report.count or 0) > #rows then
      add(("… and %d more"):format(report.count - #rows), "DBClientTruncated")
    end
  end

  add("")
  add("<CR> run it    q cancel", "DBClientHelpText")
  return lines, marks
end

--- Show the preview and call back with the decision.
---@param opts { session_id: string, sql: string, connection?: string, warnings?: string[], on_decide: fun(proceed: boolean) }
function M.confirm(opts)
  client.async(function()
    local report = M.inspect(opts.session_id, opts.sql)

    if not report.supported then
      -- Nothing to preview; fall back to a plain question so the guard still
      -- guards rather than silently letting the statement through.
      return vim.schedule(function()
        vim.ui.select({ "no", "yes" }, {
          prompt = ("%s. Run it?"):format(
            (opts.warnings and opts.warnings[1]) or report.reason or "this cannot be previewed"
          ),
        }, function(choice)
          opts.on_decide(choice == "yes")
        end)
      end)
    end

    local lines, marks = M.lines(report, opts)

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].filetype = "dbclient-blast"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false

    local winid = window.float(bufnr, {
      title = "what this would change",
      max_width = 0.9,
      max_height = 0.8,
      cursorline = false,
    })
    highlights.lines(bufnr, marks)

    local decided = false
    local function decide(proceed)
      if decided then
        return
      end
      decided = true
      window.close(winid, bufnr)
      opts.on_decide(proceed)
    end

    vim.keymap.set("n", "<CR>", function()
      decide(true)
    end, { buffer = bufnr, silent = true, nowait = true })
    vim.keymap.set("n", "q", function()
      decide(false)
    end, { buffer = bufnr, silent = true, nowait = true })
    vim.keymap.set("n", "<Esc>", function()
      decide(false)
    end, { buffer = bufnr, silent = true, nowait = true })
  end, function(err)
    vim.notify("DBClient: could not preview the change: " .. err, vim.log.levels.WARN)
    vim.schedule(function()
      vim.ui.select({ "no", "yes" }, { prompt = "Run it anyway?" }, function(choice)
        opts.on_decide(choice == "yes")
      end)
    end)
  end)
end

--- Whether a statement should be previewed before it runs.
---
--- Single-row updates are the common case and previewing them would be noise;
--- anything wider, unfiltered or destructive is worth a look.
---@param report table
---@param warnings string[]
---@return boolean
function M.should_confirm(report, warnings)
  local settings = config.get().guard
  if #warnings > 0 then
    return true
  end
  local threshold = settings.preview_writes_over
  if threshold == nil or threshold < 0 then
    return false
  end
  return (report.count or 0) > threshold
end

--- Preview on demand, from a query buffer.
---@param opts { session_id: string, sql: string, connection?: string }
function M.show(opts)
  client.async(function()
    local report = M.inspect(opts.session_id, opts.sql)
    if not report.supported then
      return vim.notify(
        "DBClient: " .. (report.reason or "this statement cannot be previewed"),
        vim.log.levels.WARN
      )
    end

    local lines, marks = M.lines(report, opts)
    -- Drop the confirmation footer; nothing is being decided here.
    table.remove(lines)
    table.remove(lines)

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].filetype = "dbclient-blast"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false

    local winid = window.float(bufnr, {
      title = "blast radius",
      max_width = 0.9,
      max_height = 0.8,
      cursorline = false,
    })
    highlights.lines(bufnr, marks)
    window.close_keys(bufnr, winid)
  end, function(err)
    vim.notify("DBClient: " .. err, vim.log.levels.ERROR)
  end)
end

return M

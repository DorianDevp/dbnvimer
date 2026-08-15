--- Column profile: the "what is actually in this column" view.

local client = require("dbclient.core.client")
local grid = require("dbclient.ui.grid")
local highlights = require("dbclient.ui.highlights")
local session = require("dbclient.session")
local window = require("dbclient.ui.window")

local M = {}

local BAR_WIDTH = 24

local function number(value)
  local numeric = tonumber(value)
  if not numeric then
    return value or "?"
  end
  -- Thousands separators make row counts readable at a glance.
  local formatted = tostring(math.floor(numeric))
  local result = formatted:reverse():gsub("(%d%d%d)", "%1 "):reverse()
  return (result:gsub("^%s+", ""))
end

--- Render the stats payload into display lines.
---@param stats table
---@return string[] lines, table[] marks
function M.lines(stats)
  local lines = {}
  local marks = {}

  local function add(text, group)
    table.insert(lines, text)
    if group then
      table.insert(marks, { line = #lines - 1, group = group })
    end
  end

  add(("%s  %s"):format(stats.column, stats.type or ""), "DBClientHeader")
  add("")

  local total = tonumber(stats.total) or 0
  local non_null = tonumber(stats.non_null) or 0
  local nulls = math.max(0, total - non_null)
  local null_pct = total > 0 and (nulls / total * 100) or 0

  add(("rows       %s"):format(number(stats.total)))
  add(("distinct   %s"):format(number(stats.distinct)))
  add(("null       %s  (%.1f%%)"):format(number(nulls), null_pct))

  for label, key in pairs({ min = "min", max = "max", avg = "avg", stddev = "stddev" }) do
    if stats[key] and stats[key] ~= "" and stats[key] ~= vim.NIL then
      add(("%-10s %s"):format(label, stats[key]))
    end
  end

  local top = stats.top or {}
  if #top > 0 then
    add("")
    add("most common values", "DBClientHeader")

    local widest_value, largest = 0, 0
    for _, entry in ipairs(top) do
      local text = entry.value == vim.NIL and "NULL" or tostring(entry.value)
      widest_value = math.max(widest_value, math.min(28, grid.width(text)))
      largest = math.max(largest, tonumber(entry.count) or 0)
    end

    for _, entry in ipairs(top) do
      local is_null = entry.value == vim.NIL or entry.value == nil
      local text = is_null and "NULL" or grid.escape(tostring(entry.value))
      local count = tonumber(entry.count) or 0
      local filled = largest > 0 and math.floor(count / largest * BAR_WIDTH) or 0
      local bar = string.rep("█", filled) .. string.rep("·", BAR_WIDTH - filled)
      local share = total > 0 and (count / total * 100) or 0
      add(
        ("  %s  %s  %s  %5.1f%%"):format(
          grid.pad(grid.truncate(text, widest_value), widest_value, "left"),
          bar,
          grid.pad(number(entry.count), 9, "right"),
          share
        ),
        is_null and "DBClientNull" or nil
      )
    end
  end

  return lines, marks
end

--- Fetch and display statistics for a column.
---@param opts { session_id?: string, schema: string, table: string, column: string }
function M.show(opts)
  client.async(function()
    local stats = session.column_stats(opts.session_id, opts.schema, opts.table, opts.column)
    local lines, marks = M.lines(stats)

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].filetype = "dbclient-stats"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false

    local winid = window.float(bufnr, {
      title = ("%s.%s"):format(opts.table, opts.column),
      max_width = 0.8,
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

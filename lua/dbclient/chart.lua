--- Charts drawn in a buffer.
---
--- "Revenue by month" is a question whose answer is a shape, and reading a
--- shape out of a column of numbers is work. A bar chart made of block
--- characters is not a replacement for a plotting library, but it answers the
--- question without leaving the editor — which is the difference between
--- looking and not bothering.

local grid = require("dbclient.ui.grid")
local highlights = require("dbclient.ui.highlights")
local window = require("dbclient.ui.window")

local M = {}

--- Eighth-block characters, so a bar has sub-character resolution.
local BLOCKS = { "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" }
local SPARK = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

--- Draw a horizontal bar `width` cells wide for `value` out of `max`.
---@param value number
---@param max number
---@param width integer
---@return string
function M.bar(value, max, width)
  if max <= 0 or value <= 0 then
    return ""
  end
  local exact = (value / max) * width
  local full = math.floor(exact)
  local remainder = exact - full

  local bar = string.rep("█", math.min(full, width))
  if full < width and remainder > 0 then
    local index = math.max(1, math.min(#BLOCKS, math.ceil(remainder * #BLOCKS)))
    bar = bar .. BLOCKS[index]
  end
  return bar
end

--- A one-line sparkline.
---@param values number[]
---@return string
function M.sparkline(values)
  if #values == 0 then
    return ""
  end

  local min, max = math.huge, -math.huge
  for _, value in ipairs(values) do
    min = math.min(min, value)
    max = math.max(max, value)
  end

  local span = max - min
  local out = {}
  for _, value in ipairs(values) do
    local level = span > 0 and ((value - min) / span) or 0.5
    local index = math.max(1, math.min(#SPARK, math.ceil(level * #SPARK)))
    table.insert(out, SPARK[index])
  end
  return table.concat(out)
end

--- Format a number for an axis label: compact, but not lossy at small scales.
---@param value number
---@return string
function M.format(value)
  local absolute = math.abs(value)
  if absolute >= 1e9 then
    return ("%.2fG"):format(value / 1e9)
  end
  if absolute >= 1e6 then
    return ("%.2fM"):format(value / 1e6)
  end
  if absolute >= 1e4 then
    return ("%.1fk"):format(value / 1e3)
  end
  if value == math.floor(value) then
    return ("%d"):format(value)
  end
  return ("%.2f"):format(value)
end

--- Whether every non-null value in a column parses as a number.
---
--- The declared class is not always available: a computed column like
--- `count(*)` has no declared type in SQLite, and a driver that cannot name the
--- type reports `unknown`. Charting those anyway is the difference between the
--- feature working on `group by` output and not.
---@param rows table[]
---@param index integer
---@return boolean
local function looks_numeric(rows, index)
  local seen = 0
  for _, row in ipairs(rows) do
    local value = row[index]
    if value ~= nil and value ~= vim.NIL and tostring(value) ~= "" then
      if not tonumber(value) then
        return false
      end
      seen = seen + 1
    end
  end
  return seen > 0
end

--- Choose the label and value columns of a result set.
---
--- The first non-numeric column labels; the first numeric one is the measure.
--- That covers `group by` output, which is what people chart.
---@param columns table[]
---@param rows? table[]  used to sniff types the backend did not declare
---@return integer|nil label_index, integer|nil value_index
function M.pick_columns(columns, rows)
  local function numeric(index)
    if columns[index].class == "number" then
      return true
    end
    if columns[index].class == "text" or columns[index].class == "temporal" then
      return false
    end
    return rows ~= nil and looks_numeric(rows, index)
  end

  local label_index, value_index
  for index in ipairs(columns) do
    if numeric(index) then
      if not value_index then
        value_index = index
      end
    elseif not label_index then
      label_index = index
    end
  end
  return label_index, value_index
end

--- Render a bar chart from a result set.
---@param result table
---@param opts? { width?: integer, label_index?: integer, value_index?: integer, title?: string }
---@return string[] lines, table[] marks, string|nil err
function M.render(result, opts)
  opts = opts or {}
  local columns = result.columns or {}
  local rows = result.rows or {}

  local label_index = opts.label_index
  local value_index = opts.value_index
  if not value_index then
    label_index, value_index = M.pick_columns(columns, rows)
  end

  if not value_index then
    return {}, {}, "no numeric column to chart"
  end
  if #rows == 0 then
    return {}, {}, "no rows to chart"
  end

  local points = {}
  local max, min = -math.huge, math.huge
  for index, row in ipairs(rows) do
    local raw = row[value_index]
    local value = tonumber(raw)
    if value then
      local label = label_index and row[label_index] or tostring(index)
      if label == nil or label == vim.NIL then
        label = require("dbclient.config").get().ui.null_display
      end
      table.insert(points, { label = tostring(label), value = value })
      max = math.max(max, value)
      min = math.min(min, value)
    end
  end

  if #points == 0 then
    return {}, {}, "the chosen column holds no numbers"
  end

  local label_width = 0
  local value_width = 0
  for _, point in ipairs(points) do
    label_width = math.max(label_width, grid.width(point.label))
    value_width = math.max(value_width, #M.format(point.value))
  end
  label_width = math.min(label_width, 28)

  local total_width = opts.width or math.min(vim.o.columns - 12, 100)
  local bar_width = math.max(10, total_width - label_width - value_width - 6)

  -- Negative values are drawn from a zero line rather than pretending the
  -- smallest value is the origin, which would invert the story.
  local scale_max = math.max(max, 0)
  local scale_min = math.min(min, 0)
  local span = scale_max - scale_min
  local zero_at = span > 0 and math.floor((0 - scale_min) / span * bar_width) or 0

  local lines = {}
  local marks = {}

  local title = opts.title
    or ("%s by %s"):format(
      columns[value_index].name,
      label_index and columns[label_index].name or "row"
    )
  table.insert(lines, title)
  table.insert(marks, { line = 0, group = "DBClientHeader" })
  table.insert(lines, "")

  for _, point in ipairs(points) do
    local label = grid.pad(grid.truncate(point.label, label_width), label_width, "left")
    local body

    if scale_min < 0 then
      -- Two-sided: pad to the zero line, then draw left or right of it.
      local length = span > 0 and math.floor(math.abs(point.value) / span * bar_width) or 0
      if point.value >= 0 then
        body = string.rep(" ", zero_at) .. "│" .. string.rep("█", length)
      else
        body = string.rep(" ", math.max(0, zero_at - length))
          .. string.rep("█", length)
          .. "│"
      end
    else
      body = M.bar(point.value, scale_max, bar_width)
    end

    table.insert(
      lines,
      ("%s  %s  %s"):format(label, body, ("%" .. value_width .. "s"):format(M.format(point.value)))
    )
    table.insert(marks, {
      line = #lines - 1,
      group = point.value < 0 and "DBClientPlanHot" or "DBClientNumber",
    })
  end

  table.insert(lines, "")
  table.insert(
    lines,
    ("%d point(s)   min %s   max %s   %s"):format(
      #points,
      M.format(min),
      M.format(max),
      M.sparkline(vim.tbl_map(function(point)
        return point.value
      end, points))
    )
  )
  table.insert(marks, { line = #lines - 1, group = "DBClientHelpText" })

  return lines, marks, nil
end

--- Chart the result buffer's current contents.
---@param opts? { result?: table, title?: string }
function M.show(opts)
  opts = opts or {}
  local result = opts.result or require("dbclient.ui.results").view()
  if not result then
    return vim.notify("DBClient: run a query first", vim.log.levels.WARN)
  end

  local lines, marks, err = M.render(result, { title = opts.title })
  if err then
    return vim.notify("DBClient: " .. err, vim.log.levels.WARN)
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "dbclient-chart"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  local winid = window.float(bufnr, {
    title = "chart",
    max_width = 0.9,
    max_height = 0.8,
    cursorline = false,
  })
  highlights.lines(bufnr, marks)
  window.close_keys(bufnr, winid)
end

--- Chart a column of the current result set, chosen interactively.
function M.pick_and_show()
  local result = require("dbclient.ui.results").view()
  if not result then
    return vim.notify("DBClient: run a query first", vim.log.levels.WARN)
  end

  local numeric = {}
  for index, column in ipairs(result.columns or {}) do
    local _, candidate = M.pick_columns({ column }, {
      vim.tbl_map(function(row)
        return row[index]
      end, result.rows or {}),
    })
    if column.class == "number" or candidate then
      table.insert(numeric, { index = index, name = column.name })
    end
  end

  if #numeric == 0 then
    return vim.notify("DBClient: no numeric column to chart", vim.log.levels.WARN)
  end
  if #numeric == 1 then
    return M.show()
  end

  vim.ui.select(numeric, {
    prompt = "chart which column",
    format_item = function(entry)
      return entry.name
    end,
  }, function(choice)
    if not choice then
      return
    end
    local label_index = M.pick_columns(result.columns, result.rows)
    local lines, marks, err = M.render(result, {
      label_index = label_index,
      value_index = choice.index,
    })
    if err then
      return vim.notify("DBClient: " .. err, vim.log.levels.WARN)
    end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    local winid = window.float(bufnr, { title = "chart", max_width = 0.9, max_height = 0.8 })
    highlights.lines(bufnr, marks)
    window.close_keys(bufnr, winid)
  end)
end

return M

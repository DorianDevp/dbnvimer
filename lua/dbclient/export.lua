--- Yanking and exporting result sets.
---
--- Two paths, deliberately: this module renders what is already in a buffer,
--- for registers, pipes and notebooks, where the data is small and in memory
--- anyway. Writing a *file* goes through the core instead
--- (`dbclient.export.ui`), because that path streams from a cursor and can
--- therefore export more rows than fit in memory — and because that is where
--- the encoding, NULL and locale decisions belong.

local config = require("dbclient.config")
local grid = require("dbclient.ui.grid")

local M = {}

--- Formats keyed by the file extension that selects them.
M.formats = {
  csv = "csv",
  tsv = "tsv",
  json = "json",
  jsonl = "jsonl",
  ndjson = "jsonl",
  md = "markdown",
  markdown = "markdown",
  sql = "sql",
  txt = "table",
}

local function raw(value)
  if value == nil or value == vim.NIL then
    return nil
  end
  return tostring(value)
end

local function csv_field(value, separator)
  local text = raw(value)
  if text == nil then
    return ""
  end
  if text:find('[",\n\r]') or text:find(separator, 1, true) then
    return '"' .. text:gsub('"', '""') .. '"'
  end
  return text
end

local function sql_literal(value)
  local text = raw(value)
  if text == nil then
    return "NULL"
  end
  return "'" .. text:gsub("'", "''") .. "'"
end

local function json_row(columns, row)
  local object = {}
  for index, column in ipairs(columns) do
    local text = raw(row[index])
    object[column.name] = text == nil and vim.NIL or text
  end
  return vim.json.encode(object)
end

--- Render a result set in the requested format.
---@param data { columns: table[], rows: table[], schema?: string, table?: string }
---@param format string
---@return string[]
function M.render(data, format)
  local columns = data.columns or {}
  local rows = data.rows or {}
  local lines = {}

  if format == "csv" or format == "tsv" then
    local separator = format == "csv" and "," or "\t"
    local header = {}
    for _, column in ipairs(columns) do
      table.insert(header, csv_field(column.name, separator))
    end
    table.insert(lines, table.concat(header, separator))
    for _, row in ipairs(rows) do
      local cells = {}
      for index in ipairs(columns) do
        table.insert(cells, csv_field(row[index], separator))
      end
      table.insert(lines, table.concat(cells, separator))
    end
    return lines
  end

  if format == "jsonl" then
    for _, row in ipairs(rows) do
      table.insert(lines, json_row(columns, row))
    end
    return lines
  end

  if format == "json" then
    local encoded = {}
    for _, row in ipairs(rows) do
      table.insert(encoded, "  " .. json_row(columns, row))
    end
    if #encoded == 0 then
      return { "[]" }
    end
    table.insert(lines, "[")
    for index, entry in ipairs(encoded) do
      table.insert(lines, entry .. (index < #encoded and "," or ""))
    end
    table.insert(lines, "]")
    return lines
  end

  if format == "markdown" then
    local header, divider = {}, {}
    for _, column in ipairs(columns) do
      table.insert(header, column.name)
      table.insert(divider, column.class == "number" and "---:" or "---")
    end
    table.insert(lines, "| " .. table.concat(header, " | ") .. " |")
    table.insert(lines, "| " .. table.concat(divider, " | ") .. " |")
    for _, row in ipairs(rows) do
      local cells = {}
      for index in ipairs(columns) do
        local text = raw(row[index])
        table.insert(cells, text == nil and "" or (text:gsub("|", "\\|"):gsub("\n", "<br>")))
      end
      table.insert(lines, "| " .. table.concat(cells, " | ") .. " |")
    end
    return lines
  end

  if format == "sql" then
    local target = ("%s.%s"):format(data.schema or "schema", data.table or "table")
    local names = {}
    for _, column in ipairs(columns) do
      table.insert(names, column.name)
    end
    for _, row in ipairs(rows) do
      local values = {}
      for index in ipairs(columns) do
        table.insert(values, sql_literal(row[index]))
      end
      table.insert(
        lines,
        ("insert into %s (%s) values (%s);"):format(
          target,
          table.concat(names, ", "),
          table.concat(values, ", ")
        )
      )
    end
    return lines
  end

  -- Default: the aligned grid, as shown on screen.
  local sizes = grid.widths(columns, rows)
  local header, underline = grid.render_header(columns, sizes)
  table.insert(lines, header)
  table.insert(lines, underline)
  for _, row in ipairs(rows) do
    table.insert(lines, (grid.render_row(row, columns, sizes)))
  end
  return lines
end

--- Pick a format from a file name.
---@param path string
---@return string
function M.format_for(path)
  local extension = path:match("%.([%w]+)$")
  return M.formats[extension and extension:lower() or ""] or "table"
end

--- Write the rows already in a buffer straight to a file.
---
--- The quick path behind `:w report.csv`: no streaming, no options, just the
--- rows on screen. Anything that needs choices goes through the export editor.
---@param data table
---@param path string
---@return boolean ok, string|nil err
function M.write_file(data, path)
  path = vim.fn.expand(path)
  local directory = vim.fs.dirname(path)
  if vim.fn.isdirectory(directory) == 0 then
    vim.fn.mkdir(directory, "p")
  end

  local lines = M.render(data, M.format_for(path))
  local ok, err = pcall(vim.fn.writefile, lines, path)
  if not ok then
    return false, tostring(err)
  end
  return true
end

--- Open the export editor for a result set or a table.
---
--- Everything about how the bytes are written lives there, because the answer
--- is never one setting: "for Excel" means a BOM and CRLF and a semicolon, and
--- a wizard that asks those one at a time is how the file ends up wrong.
---@param data table  the result view, or `{ table = ..., schema = ... }`
function M.export(data)
  data = data or {}
  require("dbclient.export.ui").open({
    session_id = data.session_id,
    sql = data.sql,
    table = data.table,
    schema = data.schema,
  })
end

local function set_register(lines)
  local text = table.concat(lines, "\n")
  vim.fn.setreg('"', text)
  vim.fn.setreg("+", text)
  return text
end

--- Rows currently selected in visual mode, or the row under the cursor.
---@param view table
---@param header_lines integer
---@return table[] rows
local function selected_rows(view, header_lines)
  local mode = vim.fn.mode()
  local first, last

  if mode:match("[vV\22]") then
    first = vim.fn.line("v")
    last = vim.fn.line(".")
  else
    local marks = { vim.fn.line("'<"), vim.fn.line("'>") }
    if marks[1] > 0 and marks[2] > 0 and marks[1] ~= marks[2] then
      first, last = marks[1], marks[2]
    end
  end

  if not first then
    return nil
  end
  if first > last then
    first, last = last, first
  end

  local rows = {}
  for line = first, last do
    local index = line - header_lines
    if view.rows[index] then
      table.insert(rows, view.rows[index])
    end
  end
  return #rows > 0 and rows or nil
end

--- The `gy` menu.
---@param view table|nil
---@param cell table|nil
---@param header_lines integer|nil
function M.yank_menu(view, cell, header_lines)
  if not view then
    return vim.notify("DBClient: nothing to yank", vim.log.levels.WARN)
  end
  header_lines = header_lines or 3

  local choices = {
    "cell value",
    "row as CSV",
    "row as JSON",
    "row as INSERT",
    "row WHERE clause",
    "column as CSV",
    "all rows as CSV",
    "all rows as JSON",
    "all rows as markdown",
    "all rows as INSERT",
  }

  vim.ui.select(choices, { prompt = "yank" }, function(choice)
    if not choice then
      return
    end

    local rows = selected_rows(view, header_lines) or (cell and { cell.row } or view.rows)
    local single = { cell and cell.row or view.rows[1] }

    local function one(format, subset)
      return M.render(
        { columns = view.columns, rows = subset, schema = view.schema, table = view.table },
        format
      )
    end

    local lines
    if choice == "cell value" then
      local text = raw(cell and cell.value)
      lines = { text == nil and "NULL" or text }
    elseif choice == "row as CSV" then
      lines = vim.list_slice(one("csv", single), 2)
    elseif choice == "row as JSON" then
      lines = one("jsonl", single)
    elseif choice == "row as INSERT" then
      lines = one("sql", single)
    elseif choice == "row WHERE clause" then
      local terms = {}
      for index, column in ipairs(view.columns) do
        for _, name in ipairs(view.primary or {}) do
          if column.name == name then
            table.insert(terms, ("%s = %s"):format(name, sql_literal(single[1][index])))
          end
        end
      end
      if #terms == 0 then
        for index, column in ipairs(view.columns) do
          table.insert(terms, ("%s = %s"):format(column.name, sql_literal(single[1][index])))
        end
      end
      lines = { "where " .. table.concat(terms, " and ") }
    elseif choice == "column as CSV" then
      local column_index = cell and cell.column_index or 1
      lines = { view.columns[column_index].name }
      for _, row in ipairs(view.rows) do
        local text = raw(row[column_index])
        table.insert(lines, text == nil and "" or text)
      end
    elseif choice == "all rows as CSV" then
      lines = one("csv", rows)
    elseif choice == "all rows as JSON" then
      lines = one("json", rows)
    elseif choice == "all rows as markdown" then
      lines = one("markdown", rows)
    else
      lines = one("sql", rows)
    end

    set_register(lines)
    vim.notify(("DBClient: yanked %d line(s)"):format(#lines))
  end)
end

return M

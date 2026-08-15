--- Export specifications and presets.
---
--- A spec is a flat table of settings, rendered as an editable buffer and sent
--- to the core as JSON. Presets exist because the interesting settings are not
--- independent: "open this in Excel" means a BOM *and* CRLF *and* a semicolon
--- when the locale writes `1,5`, and asking a user to know that is how every
--- other tool ends up with a mangled file.

local M = {}

--- Every setting, in the order it appears in the editor, with the comment that
--- explains it. Grouping is by blank `section` entries.
M.fields = {
  { section = "what to write" },
  { key = "format", default = "csv", hint = "csv tsv json jsonl markdown html xml sql xlsx text" },
  { key = "destination", default = "", hint = "file, or a directory when partitioned" },

  { section = "what to export" },
  { key = "table", default = "", hint = "leave blank to use the statement below" },
  { key = "schema", default = "" },
  { key = "filter", default = "", hint = "a WHERE expression" },
  { key = "order", default = "", hint = "an ORDER BY expression; set it for a stable diff" },
  { key = "limit", default = "", kind = "number" },

  { section = "delimited text" },
  { key = "delimiter", default = "", hint = "default , — and ; when the decimal is a comma" },
  { key = "quote", default = '"' },
  { key = "quoting", default = "minimal", hint = "minimal all non_numeric none" },
  { key = "escape", default = "double", hint = "double (RFC 4180) or backslash (MySQL)" },
  { key = "header", default = "true", kind = "boolean" },
  { key = "line_ending", default = "lf", hint = "lf or crlf" },
  { key = "bom", default = "false", kind = "boolean", hint = "Excel needs one to read UTF-8" },
  { key = "decimal_separator", default = "", hint = "set to , for a European locale" },

  { section = "fidelity" },
  {
    key = "null_as",
    default = "",
    hint = "how NULL is written; \\N tells it apart from an empty string",
  },
  { key = "binary", default = "hex", hint = "hex base64 omit" },
  { key = "json_mode", default = "inline", hint = "inline embeds JSON; string keeps it escaped" },
  { key = "json_columns", default = "", kind = "list", hint = "JSON columns the backend types as text" },

  { section = "SQL output" },
  { key = "sql_table", default = "", hint = "target table name for the INSERTs" },
  { key = "sql_mode", default = "insert", hint = "insert upsert ignore replace" },
  { key = "sql_key_columns", default = "", kind = "list", hint = "conflict target for an upsert" },
  { key = "sql_batch", default = "100", kind = "number", hint = "rows per INSERT" },
  { key = "sql_transaction", default = "false", kind = "boolean" },
  { key = "sql_dialect", default = "", hint = "defaults to the connection's own" },

  { section = "shaping" },
  { key = "columns", default = "", kind = "list", hint = "subset and order; blank means all" },
  { key = "redact", default = "", kind = "list", hint = "columns to mask before writing" },
  { key = "redact_with", default = "***" },

  { section = "output" },
  { key = "compress", default = "", hint = "gzip, or blank" },
  { key = "partition_rows", default = "", kind = "number", hint = "split every N rows" },
  { key = "partition_by", default = "", hint = "split into one file per value of a column" },
  { key = "manifest", default = "true", kind = "boolean", hint = "a sidecar recording what was written" },
  { key = "checksum", default = "true", kind = "boolean", hint = "SHA-256 of each file" },
  { key = "overwrite", default = "false", kind = "boolean" },
  { key = "sheet_name", default = "data", hint = "xlsx only" },
}

--- Named combinations that are correct together.
M.presets = {
  excel = {
    label = "Excel — opens correctly in a European locale",
    values = {
      format = "csv",
      bom = "true",
      line_ending = "crlf",
      decimal_separator = ",",
      quoting = "non_numeric",
      null_as = "",
    },
  },
  csv_strict = {
    label = "RFC 4180 CSV — the interchange default",
    values = {
      format = "csv",
      delimiter = ",",
      quote = '"',
      quoting = "minimal",
      escape = "double",
      line_ending = "crlf",
      bom = "false",
    },
  },
  postgres_copy = {
    label = "PostgreSQL COPY — reads back with \\copy",
    values = {
      format = "csv",
      delimiter = ",",
      quoting = "minimal",
      escape = "double",
      null_as = "\\N",
      header = "true",
      line_ending = "lf",
      bom = "false",
    },
  },
  mysql_load = {
    label = "MySQL LOAD DATA — backslash escapes and \\N",
    values = {
      format = "csv",
      delimiter = "\t",
      quoting = "none",
      escape = "backslash",
      null_as = "\\N",
      header = "false",
      line_ending = "lf",
    },
  },
  api = {
    label = "JSON lines — one object per row, JSON columns embedded",
    values = { format = "jsonl", json_mode = "inline", null_as = "" },
  },
  backup = {
    label = "SQL — batched inserts in one transaction",
    values = {
      format = "sql",
      sql_mode = "insert",
      sql_batch = "500",
      sql_transaction = "true",
    },
  },
  spreadsheet = {
    label = "XLSX — numbers stay numbers, header frozen",
    values = { format = "xlsx", header = "true" },
  },
  report = {
    label = "Markdown — pastes into a ticket or a README",
    values = { format = "markdown", null_as = "—" },
  },
  archive = {
    label = "Archive — gzipped chunks with a manifest",
    values = {
      format = "csv",
      compress = "gzip",
      partition_rows = "100000",
      manifest = "true",
      checksum = "true",
      null_as = "\\N",
    },
  },
  share = {
    label = "Share — redacted, no manifest, safe to send on",
    values = { format = "csv", manifest = "false", checksum = "false", redact_with = "***" },
  },
}

--- Preset names in a stable order.
---@return string[]
function M.preset_names()
  local names = vim.tbl_keys(M.presets)
  table.sort(names)
  return names
end

--- A fresh spec with the defaults filled in.
---@return table<string, string>
function M.defaults()
  local values = {}
  for _, field in ipairs(M.fields) do
    if field.key then
      values[field.key] = field.default
    end
  end
  return values
end

--- Apply a preset on top of a spec.
---@param values table
---@param name string
---@return table values, string|nil err
function M.apply_preset(values, name)
  local preset = M.presets[name]
  if not preset then
    return values, ("unknown preset `%s`"):format(name)
  end
  local merged = vim.tbl_extend("force", {}, values)
  for key, value in pairs(preset.values) do
    merged[key] = value
  end
  return merged, nil
end

--- Render a spec as the editable buffer.
---@param values table
---@param context? { title?: string, sql?: string, connection?: string }
---@return string[]
function M.render(values, context)
  context = context or {}
  local lines = {
    "# Export. Edit, then :w to run it.",
    "# gp picks a preset   gP previews without writing   q cancels   g? help",
  }

  if context.connection then
    table.insert(lines, ("# connection: %s"):format(context.connection))
  end
  if context.sql then
    table.insert(lines, "#")
    for _, line in ipairs(vim.split(vim.trim(context.sql), "\n")) do
      table.insert(lines, "# " .. line)
    end
  end

  local width = 0
  for _, field in ipairs(M.fields) do
    if field.key then
      width = math.max(width, #field.key)
    end
  end

  for _, field in ipairs(M.fields) do
    if field.section then
      table.insert(lines, "")
      table.insert(lines, "# " .. field.section)
    else
      local value = values[field.key]
      if value == nil then
        value = field.default
      end
      -- A tab is invisible in a settings file, so it is written as an escape.
      value = tostring(value):gsub("\t", "\\t")
      local line = ("%-" .. width .. "s = %s"):format(field.key, value)
      if field.hint then
        line = ("%-46s # %s"):format(line, field.hint)
      end
      table.insert(lines, line)
    end
  end

  return lines
end

--- Parse the buffer back into a spec.
---@param lines string[]
---@return table<string, string>
function M.parse(lines)
  local values = {}
  for _, line in ipairs(lines) do
    if not line:match("^%s*#") then
      local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if key then
        -- Strip a trailing comment, but not a `#` inside a quoted value.
        value = value:gsub("%s+#%s.*$", "")
        values[key] = (value:gsub("\\t", "\t"))
      end
    end
  end
  return values
end

local function to_boolean(value)
  return value == "true" or value == "yes" or value == "1"
end

local function to_list(value)
  local list = {}
  for item in tostring(value):gmatch("[^,]+") do
    local trimmed = vim.trim(item)
    if trimmed ~= "" then
      table.insert(list, trimmed)
    end
  end
  return list
end

--- Convert an edited spec into the payload the core expects.
---
--- Empty strings become absent rather than empty, so the core's own defaults
--- apply instead of an accidental empty delimiter.
---@param values table
---@param context? { sql?: string, table?: string, schema?: string }
---@return table payload, string|nil err
function M.to_payload(values, context)
  context = context or {}
  local kinds = {}
  for _, field in ipairs(M.fields) do
    if field.key then
      kinds[field.key] = field.kind or "string"
    end
  end

  local payload = {}
  for key, kind in pairs(kinds) do
    local raw = values[key]
    if raw ~= nil and raw ~= "" then
      if kind == "boolean" then
        payload[key] = to_boolean(raw)
      elseif kind == "number" then
        local number = tonumber(raw)
        if not number then
          return {}, ("`%s` must be a number"):format(key)
        end
        payload[key] = math.floor(number)
      elseif kind == "list" then
        payload[key] = to_list(raw)
      else
        payload[key] = raw
      end
    elseif kind == "boolean" and raw == "false" then
      payload[key] = false
    end
  end

  -- Booleans that default to true have to be sent explicitly when turned off.
  for _, key in ipairs({ "header", "manifest", "checksum" }) do
    payload[key] = to_boolean(values[key] or "true")
  end

  if payload.destination == nil or payload.destination == "" then
    return {}, "the export needs a destination"
  end
  payload.destination = vim.fn.expand(payload.destination)

  -- A table beats a statement, since it is the more specific instruction.
  if payload.table and payload.table ~= "" then
    payload.sql = nil
  else
    payload.table = nil
    payload.schema = payload.schema or context.schema
    payload.sql = context.sql
    if not payload.sql or not payload.sql:match("%S") then
      return {}, "there is nothing to export: give a table or run a query first"
    end
  end

  return payload, nil
end

--- A sensible destination for a source.
---@param opts { dir: string, table?: string, format?: string, connection?: string }
---@return string
function M.suggest_destination(opts)
  local stem = opts.table or "export"
  stem = tostring(stem):gsub("[^%w_.-]", "_")
  if opts.connection then
    stem = ("%s-%s"):format(tostring(opts.connection):gsub("[^%w_.-]", "_"), stem)
  end
  local extension = ({
    csv = "csv",
    tsv = "tsv",
    json = "json",
    jsonl = "jsonl",
    markdown = "md",
    html = "html",
    xml = "xml",
    sql = "sql",
    xlsx = "xlsx",
    text = "txt",
  })[opts.format or "csv"] or "csv"
  return ("%s/%s-%s.%s"):format(opts.dir, stem, os.date("%Y%m%d-%H%M%S"), extension)
end

--- Guess the format from a file name, for the `:w report.csv` shortcut.
---@param path string
---@return string|nil
function M.format_for(path)
  local extension = path:match("%.([%w]+)$")
  if not extension then
    return nil
  end
  return ({
    csv = "csv",
    tsv = "tsv",
    txt = "text",
    text = "text",
    json = "json",
    jsonl = "jsonl",
    ndjson = "jsonl",
    md = "markdown",
    markdown = "markdown",
    html = "html",
    htm = "html",
    xml = "xml",
    sql = "sql",
    xlsx = "xlsx",
  })[extension:lower()]
end

return M

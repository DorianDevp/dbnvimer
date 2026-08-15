--- Generate source code from a table definition.
---
--- Templates are plain Lua functions so a project can add or replace one in
--- `setup({ codegen = { ... } })` without waiting for the plugin to grow a
--- language.

local session = require("dbclient.session")
local client = require("dbclient.core.client")
local config = require("dbclient.config")

local M = {}

--- `snake_case` to `PascalCase`.
---@param name string
---@return string
function M.pascal(name)
  return (name:gsub("[_%s]+(%w)", function(char)
    return char:upper()
  end):gsub("^%w", string.upper))
end

--- `snake_case` to `camelCase`.
---@param name string
---@return string
function M.camel(name)
  local pascal = M.pascal(name)
  return pascal:sub(1, 1):lower() .. pascal:sub(2)
end

--- Singularise the common English plurals used in table names.
---
--- Words that merely end in `s` without being plural — `status`, `address`,
--- `analysis` — are left alone, because generating a type called `Statu` is
--- worse than not singularising at all.
---@param name string
---@return string
function M.singular(name)
  local lower = name:lower()
  if lower:match("[^aeiou]ies$") then
    return name:gsub("[iI][eE][sS]$", "y")
  end
  if lower:match("sses$") or lower:match("shes$") or lower:match("ches$") or lower:match("xes$") then
    return name:sub(1, #name - 2)
  end
  -- `us`, `ss`, `is` and `as` endings are singular nouns, not plurals.
  if lower:match("[uios]s$") or lower:match("as$") then
    return name
  end
  if lower:match("s$") then
    return name:sub(1, #name - 1)
  end
  return name
end

--- Map a database type onto a language type.
---
--- The mapping is an ordered list, not a table, because the patterns overlap:
--- `bigint` also contains `int`, so whichever is checked first wins. With
--- `pairs()` that order is unspecified and the generated type would change
--- between runs.
---@param column table
---@param mapping table[]  `{ pattern, mapped }` pairs, most specific first
---@param fallback string
---@return string
local function map_type(column, mapping, fallback)
  local lower = tostring(column.type or ""):lower()
  for _, entry in ipairs(mapping) do
    if lower:find(entry[1]) then
      return entry[2]
    end
  end
  return fallback
end

--- Whether a column should be generated as optional.
---
--- A primary key is never optional in practice, whatever the catalog says:
--- SQLite reports `id integer primary key` as nullable because it is a rowid
--- alias, and a generated `*int` there is just wrong.
---@param column table
---@return boolean
local function optional(column)
  if column.key == "PRI" then
    return false
  end
  return column.nullable == true
end

M.templates = {
  go = function(context)
    local mapping = {
      { "timestamp", "time.Time" },
      { "numeric", "float64" },
      { "decimal", "float64" },
      { "bigint", "int64" },
      { "serial", "int64" },
      { "double", "float64" },
      { "^bool", "bool" },
      { "float", "float64" },
      { "bytea", "[]byte" },
      { "int8", "int64" },
      { "real", "float64" },
      { "date", "time.Time" },
      { "time", "time.Time" },
      { "json", "json.RawMessage" },
      { "blob", "[]byte" },
      { "uuid", "string" },
      { "int", "int" },
    }

    local lines = { ("type %s struct {"):format(M.pascal(M.singular(context.table))) }
    local width = 0
    for _, column in ipairs(context.columns) do
      width = math.max(width, #M.pascal(column.name))
    end
    for _, column in ipairs(context.columns) do
      local go_type = map_type(column, mapping, "string")
      if optional(column) and not go_type:match("^%[%]") then
        go_type = "*" .. go_type
      end
      table.insert(
        lines,
        ("\t%-" .. width .. "s %-16s `db:\"%s\" json:\"%s\"`"):format(
          M.pascal(column.name),
          go_type,
          column.name,
          column.name
        )
      )
    end
    table.insert(lines, "}")
    return lines
  end,

  typescript = function(context)
    local mapping = {
      { "timestamp", "string" },
      { "numeric", "number" },
      { "decimal", "number" },
      { "serial", "number" },
      { "double", "number" },
      { "^bool", "boolean" },
      { "float", "number" },
      { "real", "number" },
      { "json", "unknown" },
      { "date", "string" },
      { "int", "number" },
    }

    local lines = { ("export interface %s {"):format(M.pascal(M.singular(context.table))) }
    for _, column in ipairs(context.columns) do
      local ts_type = map_type(column, mapping, "string")
      table.insert(
        lines,
        ("  %s%s: %s%s;"):format(
          column.name,
          optional(column) and "?" or "",
          ts_type,
          optional(column) and " | null" or ""
        )
      )
    end
    table.insert(lines, "}")
    return lines
  end,

  rust = function(context)
    local mapping = {
      { "timestamp", "chrono::NaiveDateTime" },
      { "smallint", "i16" },
      { "numeric", "rust_decimal::Decimal" },
      { "decimal", "rust_decimal::Decimal" },
      { "bigint", "i64" },
      { "serial", "i32" },
      { "double", "f64" },
      { "^bool", "bool" },
      { "float", "f64" },
      { "bytea", "Vec<u8>" },
      { "int8", "i64" },
      { "real", "f32" },
      { "date", "chrono::NaiveDate" },
      { "json", "serde_json::Value" },
      { "blob", "Vec<u8>" },
      { "uuid", "uuid::Uuid" },
      { "int", "i32" },
    }

    local lines = {
      "#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]",
      ("pub struct %s {"):format(M.pascal(M.singular(context.table))),
    }
    for _, column in ipairs(context.columns) do
      local rust_type = map_type(column, mapping, "String")
      if optional(column) then
        rust_type = ("Option<%s>"):format(rust_type)
      end
      table.insert(lines, ("    pub %s: %s,"):format(column.name, rust_type))
    end
    table.insert(lines, "}")
    return lines
  end,

  python = function(context)
    local mapping = {
      { "timestamp", "datetime.datetime" },
      { "numeric", "decimal.Decimal" },
      { "decimal", "decimal.Decimal" },
      { "serial", "int" },
      { "double", "float" },
      { "^bool", "bool" },
      { "float", "float" },
      { "bytea", "bytes" },
      { "real", "float" },
      { "date", "datetime.date" },
      { "json", "dict" },
      { "blob", "bytes" },
      { "int", "int" },
    }

    local lines = {
      "@dataclasses.dataclass",
      ("class %s:"):format(M.pascal(M.singular(context.table))),
    }
    for _, column in ipairs(context.columns) do
      local python_type = map_type(column, mapping, "str")
      if optional(column) then
        python_type = ("%s | None"):format(python_type)
      end
      table.insert(lines, ("    %s: %s"):format(column.name, python_type))
    end
    return lines
  end,

  zod = function(context)
    local mapping = {
      { "timestamp", "z.coerce.date()" },
      { "numeric", "z.number()" },
      { "decimal", "z.number()" },
      { "serial", "z.number().int()" },
      { "double", "z.number()" },
      { "^bool", "z.boolean()" },
      { "float", "z.number()" },
      { "real", "z.number()" },
      { "date", "z.coerce.date()" },
      { "uuid", "z.string().uuid()" },
      { "json", "z.unknown()" },
      { "int", "z.number().int()" },
    }

    local lines = { ("export const %s = z.object({"):format(M.camel(M.singular(context.table))) }
    for _, column in ipairs(context.columns) do
      local schema = map_type(column, mapping, "z.string()")
      if optional(column) then
        schema = schema .. ".nullable()"
      end
      table.insert(lines, ("  %s: %s,"):format(column.name, schema))
    end
    table.insert(lines, "});")
    return lines
  end,

  sql_select = function(context)
    local names = {}
    for _, column in ipairs(context.columns) do
      table.insert(names, column.name)
    end
    return {
      ("select %s"):format(table.concat(names, ", ")),
      ("from %s.%s"):format(context.schema, context.table),
      "limit 100;",
    }
  end,

  sql_insert = function(context)
    local names, placeholders = {}, {}
    for _, column in ipairs(context.columns) do
      if column.key ~= "PRI" or column.extra ~= "auto_increment" then
        table.insert(names, column.name)
        table.insert(placeholders, ":" .. column.name)
      end
    end
    return {
      ("insert into %s.%s (%s)"):format(context.schema, context.table, table.concat(names, ", ")),
      ("values (%s);"):format(table.concat(placeholders, ", ")),
    }
  end,
}

--- Template names, user templates included.
---@return string[]
function M.names()
  local names = vim.tbl_keys(M.templates)
  for name in pairs(config.get().codegen or {}) do
    if not M.templates[name] then
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

--- Generate code and open it in a scratch buffer.
---@param opts { session_id?: string, schema: string, table: string, template?: string }
function M.generate(opts)
  local function run(template_name)
    client.async(function()
      local columns = session.columns(opts.session_id, opts.schema, opts.table)
      local template = (config.get().codegen or {})[template_name] or M.templates[template_name]
      if not template then
        return vim.notify("DBClient: unknown template " .. template_name, vim.log.levels.ERROR)
      end

      local lines = template({
        schema = opts.schema,
        table = opts.table,
        columns = columns,
        helpers = { pascal = M.pascal, camel = M.camel, singular = M.singular },
      })

      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.bo[bufnr].bufhidden = "hide"
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.bo[bufnr].filetype = ({
        go = "go",
        typescript = "typescript",
        zod = "typescript",
        rust = "rust",
        python = "python",
        sql_select = "sql",
        sql_insert = "sql",
      })[template_name] or ""

      vim.cmd("vsplit")
      vim.api.nvim_win_set_buf(0, bufnr)
    end, function(err)
      vim.notify("DBClient: " .. err, vim.log.levels.ERROR)
    end)
  end

  if opts.template then
    return run(opts.template)
  end

  vim.ui.select(M.names(), { prompt = "generate" }, function(choice)
    if choice then
      run(choice)
    end
  end)
end

return M

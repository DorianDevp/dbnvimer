--- Checking an edit against what the schema already declares.
---
--- The schema has already said what is legal: the type, the length, whether
--- NULL is allowed, which values an enum admits. All of it arrives with the
--- column metadata the client fetches anyway. Sending an edit to the server to
--- be told `Data too long for column 'label' at row 1` is asking a question
--- whose answer was already in hand.
---
--- So this checks first. Nothing here talks to the database and nothing here
--- guesses: a column with no declared constraints produces no findings, which
--- is the correct outcome — the better the schema, the more this can say. That
--- is the whole trade, and it is the right way round.
---
--- What is deliberately *not* checked, because it cannot be done locally
--- without lying about how much it knows:
---
---   * whether a foreign key's target row exists — that is a query per edit;
---   * whether a CHECK expression holds — the expression is not in the metadata
---     and evaluating SQL in Lua would disagree with the server sooner or later;
---   * uniqueness — same reason.
---
--- Those still fail at the server, where `dbclient.errors` explains them.

local M = {}

-- ---------------------------------------------------------------------------
-- Reading a declared type
-- ---------------------------------------------------------------------------

--- Integer ranges, by base type name.
---
--- Stated as strings because a `bigint` bound does not survive a Lua number:
--- 9223372036854775807 rounds to 9223372036854775808 as a double, so the
--- largest legal value would be reported as out of range.
local INTEGER_RANGE = {
  tinyint = { "-128", "127", "255" },
  smallint = { "-32768", "32767", "65535" },
  int2 = { "-32768", "32767", "65535" },
  mediumint = { "-8388608", "8388607", "16777215" },
  int = { "-2147483648", "2147483647", "4294967295" },
  integer = { "-2147483648", "2147483647", "4294967295" },
  int4 = { "-2147483648", "2147483647", "4294967295" },
  bigint = { "-9223372036854775808", "9223372036854775807", "18446744073709551615" },
  int8 = { "-9223372036854775808", "9223372036854775807", "18446744073709551615" },
  serial = { "1", "2147483647", "2147483647" },
  bigserial = { "1", "9223372036854775807", "9223372036854775807" },
}

local STRING_TYPES = {
  char = true,
  varchar = true,
  character = true,
  ["character varying"] = true,
  varchar2 = true,
  nvarchar = true,
  bpchar = true,
}

--- Byte limits for the text families that have one but do not state it.
local TEXT_LIMIT = {
  tinytext = 255,
  text = 65535,
  mediumtext = 16777215,
  longtext = 4294967295,
}

local TEMPORAL = {
  date = "date",
  datetime = "datetime",
  timestamp = "datetime",
  timestamptz = "datetime",
  ["timestamp with time zone"] = "datetime",
  ["timestamp without time zone"] = "datetime",
  time = "time",
  ["time without time zone"] = "time",
  year = "year",
}

--- Take a declared type apart.
---
--- `varchar(80)`, `decimal(10,2)`, `int(10) unsigned`, `enum('a','b')` — the
--- parenthesised part means something different in each and all four turn up in
--- the same schema.
---@param column table
---@return table
function M.parse(column)
  -- PostgreSQL enums are user-defined types, so `format_type` reports the type
  -- *name* and the labels arrive separately. The adapter rewrites them into
  -- MySQL's spelling so there is one shape to read here rather than one per
  -- backend. Absent, the field arrives as JSON null rather than missing, which
  -- `tostring` would happily turn into a type name.
  local labels = type(column.values) == "string" and column.values ~= "" and column.values or nil
  local declared = tostring(labels or column.type or ""):lower()
  local spec = {
    nullable = column.nullable ~= false,
    has_default = column.default ~= nil and column.default ~= vim.NIL,
    class = column.class,
    declared = declared,
  }

  local unsigned = declared:find("unsigned") ~= nil
  spec.unsigned = unsigned

  local base = declared:gsub("%b()", ""):gsub("unsigned", ""):gsub("zerofill", "")
  base = vim.trim(base)
  spec.base = base

  local arguments = declared:match("%((.*)%)")

  -- MySQL's `tinyint(1)` is how a boolean is spelled; treating it as an
  -- integer would accept 7.
  if base == "tinyint" and declared:match("%(%s*1%s*%)") then
    spec.kind = "bool"
    return spec
  end

  if base == "bool" or base == "boolean" then
    spec.kind = "bool"
    return spec
  end

  -- MariaDB implements JSON as `longtext` plus a check constraint, so the
  -- declared type does not say so and only the adapter knows. It worked this
  -- out for the value renderer already; trusting it here has to happen before
  -- the text branches, which would otherwise claim `longtext` first.
  if base == "json" or base == "jsonb" or column.class == "json" then
    spec.kind = "json"
    return spec
  end

  if base == "enum" or base == "set" then
    spec.kind = base
    spec.values = {}
    for value in (arguments or ""):gmatch("'([^']*)'") do
      table.insert(spec.values, value)
    end
    return spec
  end

  if INTEGER_RANGE[base] then
    spec.kind = "integer"
    local range = INTEGER_RANGE[base]
    spec.min = unsigned and "0" or range[1]
    spec.max = unsigned and range[3] or range[2]
    return spec
  end

  if base == "decimal" or base == "numeric" then
    spec.kind = "decimal"
    local precision, scale = (arguments or ""):match("^(%d+)%s*,?%s*(%d*)$")
    spec.precision = tonumber(precision)
    spec.scale = tonumber(scale) or 0
    return spec
  end

  if
    base == "float"
    or base == "double"
    or base == "real"
    or base == "double precision"
    or base == "numeric"
  then
    spec.kind = "float"
    return spec
  end

  if STRING_TYPES[base] then
    spec.kind = "string"
    spec.max_length = tonumber((arguments or ""):match("^(%d+)"))
    return spec
  end

  if TEXT_LIMIT[base] then
    spec.kind = "string"
    spec.max_length = TEXT_LIMIT[base]
    -- A soft limit: it is in bytes and enormous, so it only ever catches a
    -- genuinely absurd paste.
    spec.limit_is_bytes = true
    return spec
  end

  if TEMPORAL[base] then
    spec.kind = TEMPORAL[base]
    return spec
  end

  if base == "uuid" then
    spec.kind = "uuid"
    return spec
  end

  spec.kind = "other"
  return spec
end

-- ---------------------------------------------------------------------------
-- Comparing numbers that do not fit in a double
-- ---------------------------------------------------------------------------

--- Compare two integers written as strings.
---
--- `bigint` bounds exceed what a Lua number represents exactly, so comparing
--- through `tonumber` reports the largest legal `bigint` as out of range. This
--- compares sign, then length, then digits.
---@param a string
---@param b string
---@return integer  -1, 0 or 1
function M.compare_integers(a, b)
  local function split(text)
    local negative = text:sub(1, 1) == "-"
    local digits = text:gsub("^[+-]", ""):gsub("^0+", "")
    if digits == "" then
      digits = "0"
      negative = false
    end
    return negative, digits
  end

  local a_negative, a_digits = split(a)
  local b_negative, b_digits = split(b)

  if a_negative ~= b_negative then
    return a_negative and -1 or 1
  end

  local order
  if #a_digits ~= #b_digits then
    order = #a_digits < #b_digits and -1 or 1
  elseif a_digits == b_digits then
    order = 0
  else
    order = a_digits < b_digits and -1 or 1
  end

  return a_negative and -order or order
end

-- ---------------------------------------------------------------------------
-- Checking a value
-- ---------------------------------------------------------------------------

local DATE = "^%d%d%d%d%-%d%d%-%d%d$"
local DATETIME = "^%d%d%d%d%-%d%d%-%d%d[ T]%d%d:%d%d"
local TIME = "^%-?%d+:%d%d"

--- Days in a month, so 2026-02-30 is caught before the server catches it.
local function valid_calendar_date(text)
  local year, month, day = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  if not year or month < 1 or month > 12 or day < 1 then
    return false
  end
  local lengths = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  local limit = lengths[month]
  if month == 2 and (year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)) then
    limit = 29
  end
  return day <= limit
end

--- Check one value against one column.
---
--- `value` is what the buffer holds: a string, or `vim.NIL` for a SQL NULL.
---@param value any
---@param column table
---@param opts? { bool_display?: string[] }
---@return { message: string, hint?: string }|nil
function M.check(value, column, opts)
  opts = opts or {}
  local spec = M.parse(column)

  local is_null = value == nil or value == vim.NIL
  if is_null then
    if not spec.nullable then
      return {
        message = ("`%s` is NOT NULL"):format(column.name),
        hint = spec.has_default and "leave the cell out of the insert to take the default"
          or "this column has no default either",
      }
    end
    return nil
  end

  local text = tostring(value)

  if spec.kind == "bool" then
    local labels = opts.bool_display or { "true", "false" }
    local accepted = {
      ["0"] = true,
      ["1"] = true,
      ["true"] = true,
      ["false"] = true,
      ["t"] = true,
      ["f"] = true,
      [labels[1]:lower()] = true,
      [labels[2]:lower()] = true,
    }
    if not accepted[text:lower()] then
      return { message = ("`%s` is a boolean"):format(column.name), hint = "0 or 1" }
    end
    return nil
  end

  if spec.kind == "enum" or spec.kind == "set" then
    if #spec.values == 0 then
      return nil
    end
    local candidates = spec.kind == "set" and vim.split(text, ",", { plain = true }) or { text }
    for _, candidate in ipairs(candidates) do
      candidate = vim.trim(candidate)
      if not vim.tbl_contains(spec.values, candidate) then
        return {
          message = ("`%s` does not accept %q"):format(column.name, candidate),
          hint = "one of: " .. table.concat(spec.values, ", "),
        }
      end
    end
    return nil
  end

  if spec.kind == "integer" then
    if not text:match("^[+-]?%d+$") then
      return {
        message = ("`%s` is %s and this is not a whole number"):format(column.name, spec.base),
      }
    end
    if spec.min and M.compare_integers(text, spec.min) < 0 then
      return {
        message = ("`%s` cannot go below %s"):format(column.name, spec.min),
        hint = spec.unsigned and "the column is unsigned, so negatives are out" or nil,
      }
    end
    if spec.max and M.compare_integers(text, spec.max) > 0 then
      return {
        message = ("%s is beyond the range of %s"):format(text, spec.base),
        hint = spec.base == "int" and "`bigint` is the usual answer" or nil,
      }
    end
    return nil
  end

  if spec.kind == "decimal" then
    if not text:match("^[+-]?%d*%.?%d+$") then
      return { message = ("`%s` is %s and this is not a number"):format(column.name, spec.base) }
    end
    local whole, fraction = text:gsub("^[+-]", ""):match("^(%d*)%.?(%d*)$")
    if spec.scale and #(fraction or "") > spec.scale then
      return {
        message = ("`%s` keeps %d decimal place%s"):format(
          column.name,
          spec.scale,
          spec.scale == 1 and "" or "s"
        ),
        hint = "the rest would be rounded away",
      }
    end
    if spec.precision and #(whole or "") > (spec.precision - (spec.scale or 0)) then
      return {
        message = ("`%s` holds at most %d digit%s before the point"):format(
          column.name,
          spec.precision - (spec.scale or 0),
          (spec.precision - (spec.scale or 0)) == 1 and "" or "s"
        ),
      }
    end
    return nil
  end

  if spec.kind == "float" then
    if not tonumber(text) then
      return { message = ("`%s` is %s and this is not a number"):format(column.name, spec.base) }
    end
    return nil
  end

  if spec.kind == "string" then
    if spec.max_length then
      -- Characters, not bytes: `varchar(8)` counts characters on both MySQL
      -- and PostgreSQL, and counting bytes would reject `Świętochłowice` from
      -- a column that accepts it.
      local length = spec.limit_is_bytes and #text or vim.fn.strchars(text)
      if length > spec.max_length then
        return {
          message = ("%d %s, and `%s` holds %d"):format(
            length,
            spec.limit_is_bytes and "bytes" or "characters",
            column.name,
            spec.max_length
          ),
        }
      end
    end
    return nil
  end

  if spec.kind == "date" then
    if not text:match(DATE) then
      return { message = ("`%s` is a date"):format(column.name), hint = "YYYY-MM-DD" }
    end
    if not valid_calendar_date(text) then
      return { message = ("there is no such date as %s"):format(text) }
    end
    return nil
  end

  if spec.kind == "datetime" then
    if not text:match(DATETIME) then
      return {
        message = ("`%s` is a timestamp"):format(column.name),
        hint = "YYYY-MM-DD HH:MM:SS",
      }
    end
    if not valid_calendar_date(text) then
      return { message = ("there is no such date as %s"):format(text:sub(1, 10)) }
    end
    return nil
  end

  if spec.kind == "time" then
    if not text:match(TIME) then
      return { message = ("`%s` is a time"):format(column.name), hint = "HH:MM:SS" }
    end
    return nil
  end

  if spec.kind == "json" then
    local ok = pcall(vim.json.decode, text)
    if not ok then
      return { message = ("`%s` holds JSON and this does not parse"):format(column.name) }
    end
    return nil
  end

  if spec.kind == "uuid" then
    if not text:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
      return { message = ("`%s` is a uuid"):format(column.name) }
    end
    return nil
  end

  return nil
end

--- Check a whole change set.
---
--- Returns one finding per offending cell, carrying enough to place a
--- diagnostic on it.
---@param opts { changes: table[], columns: table[], bool_display?: string[] }
---@return table[]
function M.check_changes(opts)
  local by_name = {}
  for _, column in ipairs(opts.columns or {}) do
    by_name[column.name] = column
  end

  local findings = {}
  for index, change in ipairs(opts.changes or {}) do
    local values = change.set or change.values or {}
    -- Where each edited cell sits, when the caller recorded it.
    local column_index = {}
    for _, cell in ipairs(change.cells or {}) do
      column_index[cell.column] = cell.column_index
    end

    for name, value in pairs(values) do
      local column = by_name[name]
      if column then
        local problem = M.check(value, column, { bool_display = opts.bool_display })
        if problem then
          table.insert(findings, {
            change_index = index,
            op = change.op,
            column = name,
            column_index = column_index[name],
            line = change.line,
            value = value,
            message = problem.message,
            hint = problem.hint,
          })
        end
      end
    end
  end

  -- An insert that leaves out a NOT NULL column with no default fails at the
  -- server for a reason the buffer can see: the cell is simply empty.
  for index, change in ipairs(opts.changes or {}) do
    if change.op == "insert" then
      for _, column in ipairs(opts.columns or {}) do
        local spec = M.parse(column)
        local supplied = (change.values or {})[column.name]
        local missing = supplied == nil or supplied == vim.NIL
        local generated = tostring(column.extra or ""):lower():find("auto_increment") ~= nil
          or tostring(column.default or ""):lower():find("nextval") ~= nil
        if missing and not spec.nullable and not spec.has_default and not generated then
          table.insert(findings, {
            change_index = index,
            op = "insert",
            column = column.name,
            line = change.line,
            message = ("`%s` is NOT NULL and has no default"):format(column.name),
            hint = "every inserted row has to carry a value for it",
          })
        end
      end
    end
  end

  table.sort(findings, function(a, b)
    if a.change_index ~= b.change_index then
      return a.change_index < b.change_index
    end
    return a.column < b.column
  end)
  return findings
end

return M

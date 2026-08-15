--- Derive a migration from two versions of a `create table` statement.
---
--- Deliberately conservative. The output is never executed directly: it is
--- opened as an ordinary SQL buffer for the user to read, edit and run. That
--- keeps a wrong guess from becoming a wrong migration, and it means the tool
--- can be useful on the cases it only partly understands instead of refusing.
---
--- In particular, a dropped column plus an added column is reported as exactly
--- that, with a note when it looks like a rename, because guessing wrong there
--- is the difference between keeping and losing a column of data.

local M = {}

--- Split a parenthesised body on commas that are not nested or quoted.
---@param body string
---@return string[]
function M.split_items(body)
  local items = {}
  local current = {}
  local depth = 0
  local quote = nil
  local index = 1

  while index <= #body do
    local char = body:sub(index, index)

    if quote then
      table.insert(current, char)
      if char == quote then
        -- A doubled quote is an escape, not a terminator.
        if body:sub(index + 1, index + 1) == quote then
          table.insert(current, quote)
          index = index + 1
        else
          quote = nil
        end
      end
    elseif char == "'" or char == '"' or char == "`" then
      quote = char
      table.insert(current, char)
    elseif char == "(" then
      depth = depth + 1
      table.insert(current, char)
    elseif char == ")" then
      depth = depth - 1
      table.insert(current, char)
    elseif char == "," and depth == 0 then
      table.insert(items, vim.trim(table.concat(current)))
      current = {}
    else
      table.insert(current, char)
    end

    index = index + 1
  end

  local tail = vim.trim(table.concat(current))
  if tail ~= "" then
    table.insert(items, tail)
  end
  return items
end

local CONSTRAINT_STARTS = {
  "constraint",
  "primary",
  "unique",
  "foreign",
  "key",
  "check",
  "index",
  "fulltext",
  "spatial",
  "exclude",
  "period",
}

local function is_constraint(item)
  local first = item:match("^([%a_]+)")
  if not first then
    return false
  end
  return vim.tbl_contains(CONSTRAINT_STARTS, first:lower())
end

local function unquote(name)
  return (name:gsub('^["`%[]', ""):gsub('["`%]]$', ""))
end

--- Parse a `create table` statement into columns and constraints.
---@param ddl string
---@return { columns: table[], constraints: string[], order: string[] }
function M.parse(ddl)
  local result = { columns = {}, constraints = {}, order = {} }
  if not ddl or ddl == "" then
    return result
  end

  -- Ignore anything before the first `(` that opens the column list, and the
  -- trailing table options MySQL appends after the closing `)`.
  local open = ddl:find("%(")
  if not open then
    return result
  end

  local depth = 0
  local close = nil
  local quote = nil
  for index = open, #ddl do
    local char = ddl:sub(index, index)
    if quote then
      if char == quote then
        quote = nil
      end
    elseif char == "'" or char == '"' or char == "`" then
      quote = char
    elseif char == "(" then
      depth = depth + 1
    elseif char == ")" then
      depth = depth - 1
      if depth == 0 then
        close = index
        break
      end
    end
  end

  if not close then
    return result
  end

  for _, item in ipairs(M.split_items(ddl:sub(open + 1, close - 1))) do
    if item ~= "" then
      if is_constraint(item) then
        table.insert(result.constraints, item)
      else
        -- A quoted name may contain spaces; a bare one may not, or the type
        -- that follows it would be swallowed into the name.
        local name = item:match('^(".-")')
          or item:match("^(`.-`)")
          or item:match("^(%[.-%])")
          or item:match("^([%w_]+)")
        if name then
          local plain = unquote(vim.trim(name))
          local definition = vim.trim(item:sub(#name + 1))
          result.columns[plain] = {
            name = plain,
            definition = definition,
            raw = item,
            position = #result.order + 1,
          }
          table.insert(result.order, plain)
        end
      end
    end
  end

  return result
end

--- Normalise a definition for comparison: collapse whitespace and case-fold
--- the keywords while leaving quoted literals alone.
local function normalise(definition)
  return (definition:gsub("%s+", " "):gsub("%s+$", ""):lower())
end

local function quote_ident(name, adapter)
  if adapter == "mariadb" then
    return "`" .. name:gsub("`", "``") .. "`"
  end
  return '"' .. name:gsub('"', '""') .. '"'
end

--- Compute a migration between two DDL texts.
---@param opts { before: string, after: string, adapter: string, schema: string, table: string }
---@return { statements: string[], notes: string[] }
function M.compute(opts)
  local before = M.parse(opts.before)
  local after = M.parse(opts.after)
  local adapter = opts.adapter or "postgres"
  local target = ("%s.%s"):format(
    quote_ident(opts.schema, adapter),
    quote_ident(opts.table, adapter)
  )

  local statements = {}
  local notes = {}

  local added, removed, changed = {}, {}, {}

  for _, name in ipairs(after.order) do
    if not before.columns[name] then
      table.insert(added, after.columns[name])
    elseif normalise(before.columns[name].definition) ~= normalise(after.columns[name].definition) then
      table.insert(changed, { before = before.columns[name], after = after.columns[name] })
    end
  end

  for _, name in ipairs(before.order) do
    if not after.columns[name] then
      table.insert(removed, before.columns[name])
    end
  end

  for _, column in ipairs(added) do
    table.insert(
      statements,
      ("alter table %s add column %s %s;"):format(
        target,
        quote_ident(column.name, adapter),
        column.definition
      )
    )
  end

  for _, change in ipairs(changed) do
    if adapter == "mariadb" then
      table.insert(
        statements,
        ("alter table %s modify column %s %s;"):format(
          target,
          quote_ident(change.after.name, adapter),
          change.after.definition
        )
      )
    elseif adapter == "postgres" then
      local name = quote_ident(change.after.name, adapter)
      local definition = change.after.definition
      local type_name = definition:match("^([%w_%s]+%b()|^[%w_ ]+)") or definition:match("^([%w_ ]+)")
      if type_name then
        table.insert(
          statements,
          ("alter table %s alter column %s type %s;"):format(target, name, vim.trim(type_name))
        )
      end

      local was_not_null = normalise(change.before.definition):find("not null") ~= nil
      local is_not_null = normalise(change.after.definition):find("not null") ~= nil
      if was_not_null ~= is_not_null then
        table.insert(
          statements,
          ("alter table %s alter column %s %s not null;"):format(
            target,
            name,
            is_not_null and "set" or "drop"
          )
        )
      end

      local before_default = change.before.definition:match("[Dd]efault%s+(.-)%s*$")
      local after_default = change.after.definition:match("[Dd]efault%s+(.-)%s*$")
      if before_default ~= after_default then
        if after_default then
          table.insert(
            statements,
            ("alter table %s alter column %s set default %s;"):format(target, name, after_default)
          )
        else
          table.insert(
            statements,
            ("alter table %s alter column %s drop default;"):format(target, name)
          )
        end
      end
    else
      table.insert(
        notes,
        ("SQLite cannot alter column `%s` in place; recreate the table instead"):format(
          change.after.name
        )
      )
    end
  end

  for _, column in ipairs(removed) do
    table.insert(
      statements,
      ("alter table %s drop column %s;"):format(target, quote_ident(column.name, adapter))
    )
  end

  -- A drop paired with an add at the same position is very often a rename, and
  -- the two are not interchangeable: a rename keeps the data.
  if #added == 1 and #removed == 1 then
    local same_type = normalise(added[1].definition) == normalise(removed[1].definition)
    table.insert(
      notes,
      ("`%s` was removed and `%s` added%s. If this is a rename, replace the two statements below with:\n  alter table %s rename column %s to %s;"):format(
        removed[1].name,
        added[1].name,
        same_type and " with the same definition" or "",
        target,
        quote_ident(removed[1].name, adapter),
        quote_ident(added[1].name, adapter)
      )
    )
  end

  local before_constraints = {}
  for _, constraint in ipairs(before.constraints) do
    before_constraints[normalise(constraint)] = constraint
  end
  local after_constraints = {}
  for _, constraint in ipairs(after.constraints) do
    after_constraints[normalise(constraint)] = constraint
  end

  for key, constraint in pairs(after_constraints) do
    if not before_constraints[key] then
      table.insert(statements, ("alter table %s add %s;"):format(target, constraint))
    end
  end
  for key, constraint in pairs(before_constraints) do
    if not after_constraints[key] then
      local name = constraint:match("^[Cc]onstraint%s+([\"`%w_]+)")
      if name then
        table.insert(
          statements,
          ("alter table %s drop constraint %s;"):format(target, name)
        )
      else
        table.insert(notes, ("constraint removed but not named, drop it manually: %s"):format(constraint))
      end
    end
  end

  if #statements == 0 and #notes == 0 then
    table.insert(notes, "no differences found")
  end

  return { statements = statements, notes = notes }
end

return M

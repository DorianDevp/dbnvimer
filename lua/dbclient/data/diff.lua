--- Turn an edited data buffer back into a change set.
---
--- Pure and free of Neovim API calls so it can be tested directly. The data
--- buffer supplies the buffer's current rows plus the snapshot it rendered
--- from; everything else is comparison.
---
--- Rules that matter:
---
--- * A cell is unchanged when its text still equals what was rendered. That
---   comparison, rather than comparing values, is what makes truncated cells
---   and preserved whitespace behave.
--- * A visibly truncated cell that *was* edited is rejected instead of written,
---   because writing it back would silently shorten the stored value.
--- * On an inserted row an empty cell is omitted so column defaults and
---   sequences apply; the NULL placeholder means an explicit NULL.

local grid = require("dbclient.ui.grid")

local M = {}

local ELLIPSIS = "…"

--- Indices of the columns that are actually rendered, in order.
---@param columns table[]
---@param hidden table<integer, boolean>|nil
---@return integer[]
function M.visible_columns(columns, hidden)
  local visible = {}
  for index in ipairs(columns) do
    if not (hidden and hidden[index]) then
      table.insert(visible, index)
    end
  end
  return visible
end

local function values_equal(left, right)
  if left == vim.NIL or left == nil then
    return right == vim.NIL or right == nil
  end
  if right == vim.NIL or right == nil then
    return false
  end
  return tostring(left) == tostring(right)
end

--- Assign a snapshot row to each buffer line.
---
--- Extmarks are the fast path, but they are not sufficient on their own: a
--- line-wise edit (`:m`, a block paste, anything that replaces a whole line)
--- deletes the line from the mark tree's point of view, and a mark sitting on
--- the boundary can end up on a neighbouring row. Attributing an edit to the
--- wrong row would write to the wrong record, so the primary key — the thing
--- that actually identifies a row — decides first, and marks only fill in for
--- lines whose key was itself edited.
---@param entries { id: integer|nil, cells: string[] }[]
---@param opts { columns: table[], hidden?: table<integer, boolean>, primary: string[], snapshot: table }
---@return { id: integer|nil, cells: string[] }[]
function M.reconcile(entries, opts)
  local visible = M.visible_columns(opts.columns, opts.hidden)
  local primary = opts.primary or {}

  -- Which visible position holds each primary key column, and whether all of
  -- them are actually on screen.
  local key_positions = {}
  for _, name in ipairs(primary) do
    for position, column_index in ipairs(visible) do
      if opts.columns[column_index] and opts.columns[column_index].name == name then
        key_positions[name] = position
      end
    end
  end
  local key_visible = #primary > 0
  for _, name in ipairs(primary) do
    if not key_positions[name] then
      key_visible = false
    end
  end

  local function key_of_cells(cells)
    if not key_visible then
      return nil
    end
    local parts = {}
    for _, name in ipairs(primary) do
      local text = cells[key_positions[name]]
      if text == nil or text == "" then
        return nil
      end
      table.insert(parts, text)
    end
    return table.concat(parts, "\0")
  end

  local function key_of_snapshot(id)
    if not key_visible then
      return nil
    end
    local snapshot = opts.snapshot[id]
    if not snapshot then
      return nil
    end
    local parts = {}
    for _, name in ipairs(primary) do
      local position = key_positions[name]
      local text = snapshot.rendered[visible[position]]
      if text == nil then
        return nil
      end
      table.insert(parts, text)
    end
    return table.concat(parts, "\0")
  end

  local by_key = {}
  for id in pairs(opts.snapshot) do
    local key = key_of_snapshot(id)
    if key then
      -- A duplicate key makes the mapping ambiguous, so drop both.
      by_key[key] = by_key[key] == nil and id or false
    end
  end

  local claimed = {}
  local resolved = {}

  -- Pass one: unambiguous key matches win outright.
  for index, entry in ipairs(entries) do
    local key = key_of_cells(entry.cells)
    local id = key and by_key[key]
    if id and not claimed[id] then
      claimed[id] = true
      resolved[index] = id
    end
  end

  -- Pass two: fall back to the extmark for lines whose key changed.
  for index, entry in ipairs(entries) do
    if not resolved[index] and entry.id and opts.snapshot[entry.id] and not claimed[entry.id] then
      claimed[entry.id] = true
      resolved[index] = entry.id
    end
  end

  local out = {}
  for index, entry in ipairs(entries) do
    table.insert(out, { id = resolved[index], cells = entry.cells })
  end
  return out
end

--- Compute the change set.
---@param opts { schema: string, table: string, columns: table[], hidden?: table<integer, boolean>, primary: string[], snapshot: table<integer, { values: table, rendered: string[] }>, entries: { id: integer|nil, cells: string[] }[] }
---@return { changes: table[], summary: table[], errors: string[] }
function M.compute(opts)
  local visible = M.visible_columns(opts.columns, opts.hidden)
  opts = vim.tbl_extend("force", opts, {
    entries = M.reconcile(opts.entries, opts),
  })
  local changes = {}
  local summary = {}
  local errors = {}
  local seen = {}

  local function column_at(cell_index)
    local column_index = visible[cell_index]
    return column_index, opts.columns[column_index]
  end

  local function primary_key(values)
    local pk = {}
    for _, name in ipairs(opts.primary) do
      for index, column in ipairs(opts.columns) do
        if column.name == name then
          pk[name] = values[index]
          break
        end
      end
    end
    return pk
  end

  for _, entry in ipairs(opts.entries) do
    if entry.id then
      seen[entry.id] = true
      local original = opts.snapshot[entry.id]
      if original then
        local set = {}
        local expect = {}
        local described = {}

        for cell_index, cell_text in ipairs(entry.cells) do
          local column_index, column = column_at(cell_index)
          if column then
            local rendered = original.rendered[column_index] or ""
            if vim.trim(cell_text) ~= vim.trim(rendered) then
              if rendered:sub(-#ELLIPSIS) == ELLIPSIS then
                table.insert(
                  errors,
                  ("%s was truncated for display; edit it with K instead of in the grid")
                    :format(column.name)
                )
              else
                local new_value = grid.parse_value(cell_text, column)
                local old_value = original.values[column_index]
                if not values_equal(new_value, old_value) then
                  set[column.name] = new_value
                  expect[column.name] = old_value
                  table.insert(described, {
                    column = column.name,
                    from = old_value,
                    to = new_value,
                  })
                end
              end
            end
          end
        end

        if next(set) then
          local pk = primary_key(original.values)
          if vim.tbl_isempty(pk) then
            table.insert(errors, "cannot update a row without a primary key")
          else
            table.insert(changes, {
              op = "update",
              schema = opts.schema,
              table = opts.table,
              set = set,
              pk = pk,
              expect = expect,
            })
            table.insert(summary, {
              op = "update",
              pk = pk,
              columns = described,
            })
          end
        end
      end
    else
      -- A line with no mark is a new row.
      local values = {}
      local described = {}
      local any = false

      for cell_index, cell_text in ipairs(entry.cells) do
        local column_index, column = column_at(cell_index)
        if column and vim.trim(cell_text) ~= "" then
          local value = grid.parse_value(cell_text, column)
          values[column.name] = value
          table.insert(described, { column = column.name, to = value })
          any = true
        end
      end

      if any then
        table.insert(changes, {
          op = "insert",
          schema = opts.schema,
          table = opts.table,
          values = values,
        })
        table.insert(summary, { op = "insert", columns = described })
      end
    end
  end

  -- Anything present in the snapshot but gone from the buffer was deleted.
  local removed = {}
  for id in pairs(opts.snapshot) do
    if not seen[id] then
      table.insert(removed, id)
    end
  end
  table.sort(removed)

  for _, id in ipairs(removed) do
    local original = opts.snapshot[id]
    local pk = primary_key(original.values)
    if vim.tbl_isempty(pk) then
      table.insert(errors, "cannot delete a row without a primary key")
    else
      table.insert(changes, {
        op = "delete",
        schema = opts.schema,
        table = opts.table,
        pk = pk,
        expect = vim.empty_dict(),
      })
      table.insert(summary, { op = "delete", pk = pk })
    end
  end

  return { changes = changes, summary = summary, errors = errors }
end

--- Human readable preview lines for the confirmation window.
---@param result table  the value returned by `M.compute`
---@param target string  `schema.table`
---@return string[]
function M.describe(result, target)
  local grid_module = require("dbclient.ui.grid")
  local lines = {}

  local counts = { update = 0, insert = 0, delete = 0 }
  for _, entry in ipairs(result.summary) do
    counts[entry.op] = counts[entry.op] + 1
  end

  local parts = {}
  for _, op in ipairs({ "update", "insert", "delete" }) do
    if counts[op] > 0 then
      table.insert(parts, ("%d %s"):format(counts[op], op))
    end
  end
  table.insert(lines, ("%s  —  %s"):format(target, table.concat(parts, ", ")))
  table.insert(lines, "")

  local function render(value)
    if value == nil or value == vim.NIL then
      return "NULL"
    end
    local text = grid_module.escape(tostring(value))
    if #text > 40 then
      text = text:sub(1, 39) .. "…"
    end
    return ("'%s'"):format(text)
  end

  local function key_text(pk)
    local names = vim.tbl_keys(pk)
    table.sort(names)
    local rendered = {}
    for _, name in ipairs(names) do
      table.insert(rendered, ("%s=%s"):format(name, render(pk[name])))
    end
    return table.concat(rendered, ", ")
  end

  for _, entry in ipairs(result.summary) do
    if entry.op == "update" then
      table.insert(lines, ("  update  %s"):format(key_text(entry.pk)))
      for _, column in ipairs(entry.columns) do
        table.insert(
          lines,
          ("            %s: %s → %s"):format(column.column, render(column.from), render(column.to))
        )
      end
    elseif entry.op == "insert" then
      local assignments = {}
      for _, column in ipairs(entry.columns) do
        table.insert(assignments, ("%s=%s"):format(column.column, render(column.to)))
      end
      table.insert(lines, ("  insert  %s"):format(table.concat(assignments, ", ")))
    else
      table.insert(lines, ("  delete  %s"):format(key_text(entry.pk)))
    end
  end

  if #result.errors > 0 then
    table.insert(lines, "")
    table.insert(lines, "problems:")
    for _, err in ipairs(result.errors) do
      table.insert(lines, "  ! " .. err)
    end
  end

  return lines
end

return M

--- One row, and everything the schema says is connected to it.
---
--- The question support work asks all day is "show me everything about this
--- ticket". Answering it today means opening the row, reading off a foreign
--- key, opening that table, filtering it, going back, reading the next key —
--- and the answer was fully determined by the schema before any of that
--- started. Both directions of every declared key, one buffer.
---
--- It is a *record detail page* that nobody wrote: there is no template here
--- and no per-table configuration. A table that declares its keys gets one for
--- free, and a table that declares none gets a plain row, which is the correct
--- amount of help for a table that has said nothing.
---
--- Folds do the work, because Vim already has folds. Each section is one fold
--- whose first line is its summary, so closed reads as an index and `zo` opens
--- what you asked for. No new verbs.
---
--- Costs, because this could easily be a hundred round trips and is not:
---
---   * parents are grouped by the table they point at, so the three keys on an
---     inquiry that all reference `user` are one query, not three;
---   * every child count arrives in a single `union all`, so a table with 23
---     things pointing at it costs one round trip rather than 23;
---   * child rows are only fetched for children that have any.

local buffer = require("dbclient.ui.buffer")
local config = require("dbclient.config")
local grid = require("dbclient.ui.grid")
local highlights = require("dbclient.ui.highlights")
local session = require("dbclient.session")

local M = {
  --- Keyed by buffer.
  ---@type table<integer, table>
  views = {},
}

M.ns = vim.api.nvim_create_namespace("dbclient-neighbourhood")

--- How many rows of each child to show before saying "and N more".
M.CHILD_ROWS = 5

-- ---------------------------------------------------------------------------
-- Choosing what to show
-- ---------------------------------------------------------------------------

--- Column names that name a thing, in the order worth trying.
local LABEL_NAMES = {
  "name",
  "title",
  "label",
  "email",
  "subject",
  "description",
  "code",
  "symbol",
  "number",
  "value",
}

--- The column that best identifies a row to a human.
---
--- A row summarised as `#4412` is a row you have to open. `#4412 Awaria
--- drukarki` is one you do not.
---@param columns table[]
---@return integer|nil
function M.label_column(columns)
  local by_name = {}
  for index, column in ipairs(columns) do
    by_name[tostring(column.name):lower()] = index
  end

  for _, candidate in ipairs(LABEL_NAMES) do
    if by_name[candidate] then
      return by_name[candidate]
    end
  end

  -- Nothing conventional: the first text column that is not a key.
  for index, column in ipairs(columns) do
    local name = tostring(column.name):lower()
    if column.class == "text" and not name:match("_id$") and name ~= "id" then
      return index
    end
  end
  return nil
end

--- A one-line summary of a row: its key, then whatever names it.
---@param row table
---@param columns table[]
---@param primary string[]
---@return string
function M.summarise(row, columns, primary)
  local parts = {}

  for index, column in ipairs(columns) do
    if vim.tbl_contains(primary or {}, column.name) then
      local text = grid.display(row[index], column)
      table.insert(parts, "#" .. text)
    end
  end
  if #parts == 0 and row[1] ~= nil then
    table.insert(parts, "#" .. grid.display(row[1], columns[1]))
  end

  local label = M.label_column(columns)
  if label and row[label] ~= nil and row[label] ~= vim.NIL then
    local text = grid.display(row[label], columns[label])
    table.insert(parts, grid.truncate(text, 60))
  end

  return table.concat(parts, "  ")
end

--- Columns worth putting in a child's grid.
---
--- Everything is too wide to read and the key alone is too little. The primary
--- key, whatever names the row, and the first temporal column — which is
--- almost always the one that orders a list of children in the reader's head.
---@param columns table[]
---@param primary string[]
---@return integer[]
function M.child_columns(columns, primary)
  local chosen, seen = {}, {}
  local function take(index)
    if index and not seen[index] then
      seen[index] = true
      table.insert(chosen, index)
    end
  end

  for index, column in ipairs(columns) do
    if vim.tbl_contains(primary or {}, column.name) then
      take(index)
    end
  end
  take(M.label_column(columns))

  for index, column in ipairs(columns) do
    if column.class == "temporal" then
      take(index)
      break
    end
  end

  if #chosen == 0 then
    for index = 1, math.min(3, #columns) do
      take(index)
    end
  end

  table.sort(chosen)
  return chosen
end

-- ---------------------------------------------------------------------------
-- Gathering
-- ---------------------------------------------------------------------------

---@param value any
---@return string
local function literal(value)
  return "'" .. tostring(value):gsub("'", "''") .. "'"
end

--- Everything connected to one row.
---
--- Runs on the coroutine.
---@param opts { session_id: string, schema: string, table: string, pk: table<string, any> }
---@return table
function M.gather(opts)
  local filters = {}
  for column, value in pairs(opts.pk) do
    table.insert(filters, ("%s = %s"):format(column, literal(value)))
  end
  table.sort(filters)
  local filter = table.concat(filters, " and ")

  local root = session.preview(opts.session_id, {
    schema = opts.schema,
    table = opts.table,
    filter = filter,
    limit = 1,
  })
  if not root.rows or #root.rows == 0 then
    error(("no row in %s.%s where %s"):format(opts.schema, opts.table, filter), 0)
  end

  local gathered = {
    schema = opts.schema,
    table = opts.table,
    pk = opts.pk,
    filter = filter,
    columns = root.columns,
    row = root.rows[1],
    primary = session.primary_key(opts.session_id, opts.schema, opts.table),
    parents = {},
    children = {},
    skipped = {},
  }

  -- Parents ---------------------------------------------------------------
  local outgoing = {}
  local ok, keys = pcall(session.foreign_keys, opts.session_id, opts.schema, opts.table)
  if ok then
    outgoing = keys
  end

  --- Group by the table pointed at, so three keys into `user` cost one query.
  local by_table = {}
  for _, key in ipairs(outgoing) do
    local index
    for position, column in ipairs(root.columns) do
      if column.name == key.column then
        index = position
      end
    end
    local value = index and gathered.row[index]
    if value ~= nil and value ~= vim.NIL and tostring(value) ~= "" then
      local target = ("%s.%s"):format(key.ref_schema or opts.schema, key.ref_table)
      by_table[target] = by_table[target] or {
        schema = key.ref_schema or opts.schema,
        table = key.ref_table,
        column = key.ref_column,
        wanted = {},
        via = {},
      }
      table.insert(by_table[target].wanted, tostring(value))
      table.insert(by_table[target].via, { column = key.column, value = tostring(value) })
    end
  end

  local targets = vim.tbl_keys(by_table)
  table.sort(targets)
  for _, name in ipairs(targets) do
    local entry = by_table[name]
    local values = {}
    for _, value in ipairs(entry.wanted) do
      table.insert(values, literal(value))
    end

    local fetched = pcall(function()
      local result = session.preview(opts.session_id, {
        schema = entry.schema,
        table = entry.table,
        filter = ("%s in (%s)"):format(entry.column, table.concat(values, ", ")),
        limit = #values,
      })

      local primary = session.primary_key(opts.session_id, entry.schema, entry.table)
      local key_index
      for index, column in ipairs(result.columns) do
        if column.name == entry.column then
          key_index = index
        end
      end

      for _, via in ipairs(entry.via) do
        local matched
        for _, row in ipairs(result.rows) do
          if key_index and tostring(row[key_index]) == via.value then
            matched = row
          end
        end
        table.insert(gathered.parents, {
          schema = entry.schema,
          table = entry.table,
          column = entry.column,
          via = via.column,
          value = via.value,
          columns = result.columns,
          primary = primary,
          row = matched,
        })
      end
    end)

    if not fetched then
      table.insert(gathered.skipped, ("could not read %s"):format(name))
    end
  end

  table.sort(gathered.parents, function(a, b)
    return a.via < b.via
  end)

  -- Children --------------------------------------------------------------
  local incoming = {}
  local reversed, references =
    pcall(session.referencing_keys, opts.session_id, opts.schema, opts.table)
  if reversed then
    incoming = references
  end

  local pk_by_column = {}
  for index, column in ipairs(root.columns) do
    pk_by_column[column.name] = gathered.row[index]
  end

  local counted = {}
  for _, reference in ipairs(incoming) do
    local value = pk_by_column[reference.ref_column]
    if value ~= nil and value ~= vim.NIL then
      table.insert(counted, {
        schema = reference.schema or opts.schema,
        table = reference.table,
        column = reference.column,
        filter = ("%s = %s"):format(reference.column, literal(value)),
      })
    end
  end

  if #counted > 0 then
    -- One statement for every count. Asking table by table is what makes a
    -- record page feel slow on a hub row, and `user` here has 23 of them.
    local parts = {}
    for index, entry in ipairs(counted) do
      table.insert(
        parts,
        ("select %d as n, count(*) as c from %s.%s where %s"):format(
          index,
          entry.schema,
          entry.table,
          entry.filter
        )
      )
    end

    local ok_counts, result = pcall(
      session.query,
      opts.session_id,
      table.concat(parts, " union all "),
      #counted
    )
    if ok_counts then
      for _, row in ipairs(result.rows or {}) do
        local index = tonumber(row[1])
        local count = tonumber(row[2]) or 0
        if index and counted[index] then
          counted[index].count = count
        end
      end
    else
      -- A single union that the server will not take: fall back to counting
      -- one at a time rather than losing the whole section.
      for _, entry in ipairs(counted) do
        local fine, count = pcall(session.count, opts.session_id, {
          schema = entry.schema,
          table = entry.table,
          filter = entry.filter,
        })
        entry.count = fine and count or 0
      end
    end
  end

  for _, entry in ipairs(counted) do
    if (entry.count or 0) > 0 then
      local fine, preview = pcall(session.preview, opts.session_id, {
        schema = entry.schema,
        table = entry.table,
        filter = entry.filter,
        limit = M.CHILD_ROWS,
      })
      if fine then
        entry.columns = preview.columns
        entry.rows = preview.rows
        entry.primary = session.primary_key(opts.session_id, entry.schema, entry.table)
      end
      table.insert(gathered.children, entry)
    end
  end

  table.sort(gathered.children, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return a.table < b.table
  end)

  return gathered
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- Whether a column's value should be hidden until asked for.
---
--- Matched against a list the user can see and change. Nothing is inferred
--- from the data and nothing is hidden that the configuration does not name —
--- the point is only that a record page should not spray a password hash into
--- a buffer that might be on a shared screen.
---@param name string
---@return boolean
function M.masked(name)
  local settings = config.get().ui
  local lowered = tostring(name):lower()
  for _, fragment in ipairs(settings.mask_columns or {}) do
    if lowered:find(fragment, 1, true) then
      return true
    end
  end
  return false
end

--- Render a gathered record.
---@param gathered table
---@param opts? { unmasked?: boolean }
---@return string[] lines, table[] marks, table<integer, table> index
function M.render(gathered, opts)
  opts = opts or {}
  local lines, marks, index = {}, {}, {}

  --- Display text for a cell, hidden when the column is on the mask list.
  local function cell(value, column)
    if not opts.unmasked and M.masked(column.name) then
      local hidden = value == nil or value == vim.NIL
      return hidden and config.get().ui.null_display or config.get().ui.mask_with, hidden
    end
    return grid.display(value, column)
  end

  local function add(text, group, target)
    table.insert(lines, text)
    if group then
      table.insert(marks, { line = #lines - 1, group = group })
    end
    if target then
      index[#lines] = target
    end
  end

  add(
    ("%s.%s   %s"):format(
      gathered.schema,
      gathered.table,
      M.summarise(gathered.row, gathered.columns, gathered.primary)
    ),
    "DBClientHeader",
    { schema = gathered.schema, table = gathered.table, filter = gathered.filter }
  )
  add(("%d parent%s · %d related table%s"):format(
    #gathered.parents,
    #gathered.parents == 1 and "" or "s",
    #gathered.children,
    #gathered.children == 1 and "" or "s"
  ), "DBClientHelpText")
  add("")

  -- The row itself.
  local width = 0
  for _, column in ipairs(gathered.columns) do
    width = math.max(width, #tostring(column.name))
  end
  for position, column in ipairs(gathered.columns) do
    local text, is_null = cell(gathered.row[position], column)
    add(
      ("  %-" .. width .. "s  %s"):format(column.name, grid.truncate(text, 100)),
      is_null and "DBClientNull" or highlights.class_group(column.class)
    )
    -- The name is metadata whatever the value is.
    marks[#marks].col = 2
    marks[#marks].end_col = 2 + width
    marks[#marks].group = "DBClientColumn"
  end

  -- Parents ---------------------------------------------------------------
  if #gathered.parents > 0 then
    add("")
    for _, parent in ipairs(gathered.parents) do
      local summary = parent.row
          and M.summarise(parent.row, parent.columns, parent.primary)
        or ("#" .. parent.value .. "  (no such row)")

      add(
        ("  ▾ %s  ← %s   %s"):format(parent.table, parent.via, summary),
        parent.row and "DBClientTable" or "DBClientSeverityWarn",
        {
          schema = parent.schema,
          table = parent.table,
          filter = ("%s = %s"):format(parent.column, literal(parent.value)),
        }
      )

      if parent.row then
        local parent_width = 0
        for _, column in ipairs(parent.columns) do
          parent_width = math.max(parent_width, #tostring(column.name))
        end
        for position, column in ipairs(parent.columns) do
          local text, is_null = cell(parent.row[position], column)
          add(
            ("      %-" .. parent_width .. "s  %s"):format(
              column.name,
              grid.truncate(text, 90)
            ),
            is_null and "DBClientNull" or "DBClientHelpText"
          )
        end
      end
    end
  end

  -- Children --------------------------------------------------------------
  if #gathered.children > 0 then
    add("")
    for _, child in ipairs(gathered.children) do
      add(
        ("  ▾ %s  → %s   %d row%s"):format(
          child.table,
          child.column,
          child.count,
          child.count == 1 and "" or "s"
        ),
        "DBClientTable",
        { schema = child.schema, table = child.table, filter = child.filter }
      )

      if child.columns and child.rows then
        local chosen = M.child_columns(child.columns, child.primary)
        local columns, rows = {}, {}
        for _, position in ipairs(chosen) do
          table.insert(columns, child.columns[position])
        end
        for _, row in ipairs(child.rows) do
          local picked = {}
          for _, position in ipairs(chosen) do
            table.insert(picked, row[position])
          end
          table.insert(rows, picked)
        end

        local sizes = grid.widths(columns, rows)
        local header = grid.render_header(columns, sizes)
        add("      " .. header, "DBClientHeader")
        for _, row in ipairs(rows) do
          add("      " .. grid.render_row(row, columns, sizes), nil)
        end
        if child.count > #rows then
          add(("      … %d more"):format(child.count - #rows), "DBClientHelpText")
        end
      end
    end
  end

  for _, note in ipairs(gathered.skipped) do
    add("")
    add("  " .. note, "DBClientSeverityWarn")
  end

  return lines, marks, index
end

-- ---------------------------------------------------------------------------
-- The buffer
-- ---------------------------------------------------------------------------

--- Redraw a record buffer from what was gathered.
---@param bufnr integer
function M.paint(bufnr)
  local view = M.views[bufnr]
  if not view or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local lines, marks, index = M.render(view.gathered, { unmasked = view.unmasked })
  view.index = index
  buffer.set_lines(bufnr, lines)
  highlights.lines(bufnr, marks, M.ns)
end

--- Handlers for the `record` mapping group.
---@param bufnr integer
---@return table<string, function>
function M.handlers(bufnr)
  return {
    open = function()
      local view = M.views[bufnr]
      local target = view and view.index[vim.api.nvim_win_get_cursor(0)[1]]
      if not target then
        return
      end
      require("dbclient.ui.data").open({
        session_id = view.session_id,
        schema = target.schema,
        table = target.table,
        filter = target.filter,
      })
    end,

    unmask = function()
      local view = M.views[bufnr]
      if not view then
        return
      end
      view.unmasked = not view.unmasked
      M.paint(bufnr)
      notify(view.unmasked and "masked values shown" or "masked values hidden")
    end,

    refresh = function()
      local view = M.views[bufnr]
      if view then
        M.open(view.request)
      end
    end,

    close = function()
      vim.cmd("close")
    end,

    help = require("dbclient.ui.help").handler("record"),
  }
end

--- Fold level for a line, by indentation.
---
--- Exposed because `foldexpr` has to name something callable, and because it
--- is the only piece of this worth testing on its own.
---@param line string
---@return string
function M.fold_level(line)
  if line:match("^  [▾▸]") then
    return ">1"
  end
  if line:match("^      ") then
    return "1"
  end
  return "0"
end

function M.foldexpr()
  return M.fold_level(vim.fn.getline(vim.v.lnum))
end

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

--- Open the record around a row.
---@param opts { session_id: string, schema: string, table: string, pk: table<string, any> }
function M.open(opts)
  local client = require("dbclient.core.client")

  client.async(function()
    local started = vim.uv.hrtime()
    local gathered = M.gather(opts)
    gathered.elapsed_ms = (vim.uv.hrtime() - started) / 1e6

    local name = ("dbclient://record/%s.%s"):format(opts.schema, opts.table)
    local bufnr = buffer.scratch(name, { filetype = "dbclient-record" })
    M.views[bufnr] = {
      gathered = gathered,
      session_id = opts.session_id,
      request = opts,
      unmasked = false,
    }
    M.paint(bufnr)

    buffer.show(bufnr, "botright vsplit")
    vim.wo.wrap = false
    vim.wo.cursorline = true
    vim.wo.foldmethod = "expr"
    vim.wo.foldexpr = "v:lua.require'dbclient.neighbourhood'.foldexpr()"
    vim.wo.foldtext = ""
    vim.wo.foldlevel = 1

    require("dbclient.keymap").apply("record", bufnr, M.handlers(bufnr))

    notify(("%s.%s: %d parent(s), %d related table(s) in %.0f ms"):format(
      opts.schema,
      opts.table,
      #gathered.parents,
      #gathered.children,
      gathered.elapsed_ms
    ))
  end, function(err)
    require("dbclient.errors").handle(err, nil, { session_id = opts.session_id })
  end)
end

--- Open the record for the row under the cursor in a data buffer.
function M.from_cursor()
  local data = require("dbclient.ui.data")
  local cell = data.current_cell()
  if not cell then
    return notify("no row under the cursor", vim.log.levels.WARN)
  end

  local view = cell.view
  if #view.primary == 0 then
    return notify("this table has no primary key, so a row cannot be addressed", vim.log.levels.WARN)
  end

  local pk = {}
  for index, column in ipairs(view.columns) do
    if vim.tbl_contains(view.primary, column.name) then
      pk[column.name] = view.rows[cell.row_index][index]
    end
  end

  M.open({
    session_id = view.session_id,
    schema = view.schema,
    table = view.table,
    pk = pk,
  })
end

return M

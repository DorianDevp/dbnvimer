--- The editable data buffer.
---
--- This is a plain modifiable buffer holding a rendered grid. Editing is
--- ordinary Neovim editing — `ciw`, visual block, `:%s/`, macros, `dd`, `o`,
--- and `u` for undo — and `:w` turns whatever the buffer now says into the
--- `UPDATE`, `INSERT` and `DELETE` statements needed to get the database there.
---
--- Row identity survives arbitrary editing because each data line carries an
--- extmark. Extmarks move with their line, disappear when the line is deleted
--- and come back on undo, which is exactly the bookkeeping a diff needs.

local buffer = require("dbclient.ui.buffer")
local client = require("dbclient.core.client")
local config = require("dbclient.config")
local diff = require("dbclient.data.diff")
local grid = require("dbclient.ui.grid")
local help = require("dbclient.ui.help")
local highlights = require("dbclient.ui.highlights")
local keymap = require("dbclient.keymap")
local session = require("dbclient.session")
local trail = require("dbclient.trail")
local value_inspector = require("dbclient.ui.value")
local window = require("dbclient.ui.window")
local winbar = require("dbclient.ui.winbar")

local M = {
  --- bufnr -> view
  views = {},
}

local HEADER_LINES = 3
local ns_rows = vim.api.nvim_create_namespace("dbclient-data-rows")

--- Its own namespace so schema findings and server errors can coexist without
--- either clearing the other.
local constraint_ns = vim.api.nvim_create_namespace("dbclient-data-constraints")

--- The view attached to a buffer.
---@param bufnr integer|nil
---@return table|nil
function M.view(bufnr)
  return M.views[bufnr or vim.api.nvim_get_current_buf()]
end

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function header_text(view)
  local parts = { ("%s.%s"):format(view.schema, view.table) }

  local first = (view.offset or 0) + 1
  local last = (view.offset or 0) + #view.rows
  if view.total then
    table.insert(parts, ("rows %d-%d of %d"):format(first, last, view.total))
  else
    table.insert(parts, ("rows %d-%d"):format(first, last))
  end

  if view.truncated then
    table.insert(parts, "more available")
  end
  if view.filter and view.filter ~= "" then
    table.insert(parts, ("where %s"):format(view.filter))
  end
  if view.sort and #view.sort > 0 then
    local terms = {}
    for _, term in ipairs(view.sort) do
      table.insert(terms, ("%s %s"):format(term.column, term.dir))
    end
    table.insert(parts, "order by " .. table.concat(terms, ", "))
  end
  if next(view.hidden or {}) then
    table.insert(parts, ("%d hidden"):format(vim.tbl_count(view.hidden)))
  end
  if #view.primary == 0 then
    table.insert(parts, "no primary key: read-only")
  end

  return table.concat(parts, "  ·  ")
end

--- Draw the grid and place one extmark per row.
---@param view table
function M.render(view)
  local bufnr = view.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local sizes = grid.widths(view.columns, view.rows, view.hidden)
  local spans = grid.spans(view.columns, sizes, view.hidden)
  local header, underline = grid.render_header(view.columns, sizes, view.hidden)

  local lines = { header_text(view), header, underline }
  local nulls = {}
  local rendered_rows = {}

  for index, row in ipairs(view.rows) do
    local line, row_nulls = grid.render_row(row, view.columns, sizes, view.hidden)
    table.insert(lines, line)
    nulls[index] = row_nulls

    -- Remember the exact rendered text per column so the diff can tell an
    -- untouched cell from an edited one even when it was truncated.
    local per_column = {}
    for column_index, column in ipairs(view.columns) do
      if not (view.hidden and view.hidden[column_index]) then
        per_column[column_index] = vim.trim(
          grid.pad(
            (grid.display(row[column_index], column)),
            sizes[column_index] or 0,
            grid.alignment(column.class)
          )
        )
      end
    end
    rendered_rows[index] = per_column
  end

  view.sizes = sizes
  view.spans = spans

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false

  -- Snapshot and marks are rebuilt together so their ids always agree.
  vim.api.nvim_buf_clear_namespace(bufnr, ns_rows, 0, -1)
  view.snapshot = {}
  for index, row in ipairs(view.rows) do
    view.snapshot[index] = { values = row, rendered = rendered_rows[index] }
    vim.api.nvim_buf_set_extmark(bufnr, ns_rows, HEADER_LINES + index - 1, 0, {
      id = index,
      invalidate = true,
      right_gravity = false,
    })
  end

  highlights.grid(bufnr, {
    header_line = 1,
    first_row = HEADER_LINES,
    spans = spans,
    columns = view.columns,
    rows = #view.rows,
    nulls = nulls,
    stripes = config.get().ui.row_stripes,
  })
  highlights.lines(bufnr, { { line = 0, group = "DBClientHeader" } }, highlights.ns_virt)

  M.render_fk_hints(view)
  vim.b[bufnr].dbclient_header = header
  -- Bumped on every draw so callers (and tests) can tell a rendered buffer
  -- from one that has rows fetched but not yet drawn.
  view.generation = (view.generation or 0) + 1
end

--- Show `→ table.column` next to foreign key columns in the header.
---@param view table
function M.render_fk_hints(view)
  if not config.get().ui.virtual_fk or vim.tbl_isempty(view.fk or {}) then
    return
  end

  local chunks = {}
  for index, column in ipairs(view.columns) do
    local reference = view.fk[column.name]
    if reference and not (view.hidden and view.hidden[index]) then
      table.insert(chunks, ("%s→%s.%s"):format(column.name, reference.ref_table, reference.ref_column))
    end
  end

  if #chunks > 0 then
    pcall(vim.api.nvim_buf_set_extmark, view.bufnr, highlights.ns_virt, 1, 0, {
      virt_text = { { "  " .. table.concat(chunks, "  "), "DBClientFk" } },
      virt_text_pos = "eol",
    })
  end
end

-- ---------------------------------------------------------------------------
-- Cursor helpers
-- ---------------------------------------------------------------------------

--- Describe the cell under the cursor.
---@return table|nil
function M.current_cell()
  local view = M.view()
  if not view then
    return nil
  end

  local position = vim.api.nvim_win_get_cursor(0)
  local row_index = position[1] - HEADER_LINES
  if row_index < 1 or row_index > #view.rows then
    return nil
  end

  -- Spans are in display cells; the cursor reports bytes.
  local line = vim.api.nvim_get_current_line()
  local column_index = grid.column_at(grid.line_spans(line, view.spans), position[2]) or 1
  return {
    view = view,
    row_index = row_index,
    column_index = column_index,
    column = view.columns[column_index],
    row = view.rows[row_index],
    value = view.rows[row_index] and view.rows[row_index][column_index],
  }
end

local function move_to(view, row_index, column_index)
  row_index = math.max(1, math.min(row_index, #view.rows))
  local visible = diff.visible_columns(view.columns, view.hidden)
  if #visible == 0 then
    return
  end
  -- Clamp onto a visible column.
  if view.hidden and view.hidden[column_index] then
    column_index = visible[1]
  end
  column_index = math.max(1, math.min(column_index, #view.columns))
  local line_number = HEADER_LINES + row_index
  local text = vim.api.nvim_buf_get_lines(0, line_number - 1, line_number, false)[1] or ""
  local spans = grid.line_spans(text, view.spans)
  local span = spans[column_index] or spans[visible[1]]
  pcall(vim.api.nvim_win_set_cursor, 0, { line_number, span and span.start or 0 })
end

--- Column index adjacent to `from`, skipping hidden columns.
local function step_column(view, from, delta)
  local visible = diff.visible_columns(view.columns, view.hidden)
  for position, index in ipairs(visible) do
    if index == from then
      local target = visible[position + delta]
      return target or index
    end
  end
  return visible[1]
end

function M.next_cell(delta)
  local cell = M.current_cell()
  if cell then
    move_to(cell.view, cell.row_index, step_column(cell.view, cell.column_index, delta))
  end
end

function M.next_row(delta)
  local cell = M.current_cell()
  if cell then
    move_to(cell.view, cell.row_index + delta, cell.column_index)
  end
end

-- ---------------------------------------------------------------------------
-- Loading
-- ---------------------------------------------------------------------------

local function buffer_name(schema, table_name, session_name)
  return ("dbclient://%s/%s.%s"):format(session_name, schema, table_name)
end

--- Fetch rows and metadata for a view, then draw it.
--- Must run inside `client.async`.
---@param view table
local function load(view)
  local params = {
    schema = view.schema,
    table = view.table,
    limit = view.limit,
    offset = view.offset,
    filter = view.filter,
    order = view.sort,
  }

  local result = session.preview(view.session_id, params)
  view.columns = result.columns
  view.rows = result.rows
  view.truncated = result.truncated
  view.elapsed_ms = result.elapsed_ms

  view.primary = session.primary_key(view.session_id, view.schema, view.table)

  view.fk = {}
  local ok, keys = pcall(session.foreign_keys, view.session_id, view.schema, view.table)
  if ok then
    for _, key in ipairs(keys) do
      view.fk[key.column] = key
    end
  end

  -- The result set describes each column as the *query* produced it: an enum
  -- arrives as `enum`, a varchar as `varchar`, with no values and no length.
  -- The declared type — the one that says `enum('new','open','closed')` and
  -- `varchar(8)` — only comes from the catalogue, and it is what validation
  -- has to check against. Cached by the session, so this costs nothing after
  -- the first open.
  view.meta = {}
  local described, catalogue =
    pcall(session.columns, view.session_id, view.schema, view.table)
  if described then
    for _, column in ipairs(catalogue) do
      view.meta[column.name] = column
    end
  end

  -- Row counts are a separate round trip so a slow `count(*)` never delays the
  -- rows themselves.
  M.render(view)
  vim.schedule(function()
    client.async(function()
      local total = session.count(view.session_id, {
        schema = view.schema,
        table = view.table,
        filter = view.filter,
      })
      if vim.api.nvim_buf_is_valid(view.bufnr) and M.views[view.bufnr] == view then
        view.total = total
        if not vim.bo[view.bufnr].modified then
          local line = header_text(view)
          vim.bo[view.bufnr].modifiable = true
          vim.api.nvim_buf_set_lines(view.bufnr, 0, 1, false, { line })
          vim.bo[view.bufnr].modified = false
        end
      end
    end, function() end)
  end)
end

--- Open a table in a data buffer.
---@param opts { session_id?: string, schema: string, table: string, limit?: integer, offset?: integer, filter?: string, sort?: table[], split?: string, via?: string }
function M.open(opts)
  local target = session.get(opts.session_id)
  if not target then
    notify("no active connection", vim.log.levels.WARN)
    return
  end

  local name = buffer_name(opts.schema, opts.table, target.name)
  local bufnr = buffer.scratch(name, { modifiable = true, buftype = "acwrite" })
  local existing = M.views[bufnr]

  local view = existing
    or {
      bufnr = bufnr,
      session_id = target.id,
      schema = opts.schema,
      table = opts.table,
      rows = {},
      columns = {},
      primary = {},
      hidden = {},
      sort = {},
      snapshot = {},
      fk = {},
    }

  view.session_id = target.id
  view.limit = opts.limit or view.limit or config.get().ui.preview_limit
  view.offset = opts.offset or view.offset or 0
  if opts.filter ~= nil then
    view.filter = opts.filter ~= "" and opts.filter or nil
  end
  if opts.sort ~= nil then
    view.sort = opts.sort
  end

  M.views[bufnr] = view
  vim.bo[bufnr].filetype = "dbclient-data"

  -- Every place you land is a point on the trail, so `g[` can walk back
  -- through a chain of foreign key jumps rather than one step.
  trail.push({
    session_id = target.id,
    connection = target.name,
    schema = view.schema,
    table = view.table,
    filter = view.filter,
    sort = view.sort,
    limit = view.limit,
    offset = view.offset,
    via = opts.via,
  })

  buffer.show(bufnr, opts.split or "botright split")
  vim.wo.cursorline = true
  vim.wo.wrap = false
  winbar.bind(bufnr, target.id)

  if not existing then
    M.attach(view)
  end

  client.async(function()
    load(view)
    if #view.rows > 0 then
      move_to(view, 1, diff.visible_columns(view.columns, view.hidden)[1] or 1)
    end
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

--- Re-fetch the current page.
function M.reload()
  local view = M.view()
  if not view then
    return
  end
  if vim.bo[view.bufnr].modified then
    return notify("buffer has unsaved changes; :w or :e! first", vim.log.levels.WARN)
  end
  client.async(function()
    local position = vim.api.nvim_win_get_cursor(0)
    load(view)
    pcall(vim.api.nvim_win_set_cursor, 0, position)
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

-- ---------------------------------------------------------------------------
-- Writing
-- ---------------------------------------------------------------------------

--- Read the buffer back into `{ id, cells }` entries.
---
--- The extmark on each line gives the original row id; a line without one is a
--- new row. Invalidated marks belong to deleted lines and are skipped.
---@param view table
---@return table[] entries
function M.read_entries(view)
  local bufnr = view.bufnr
  local lines = vim.api.nvim_buf_get_lines(bufnr, HEADER_LINES, -1, false)

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_rows, 0, -1, { details = true })
  local id_by_line = {}
  for _, mark in ipairs(marks) do
    local id, line, _, details = mark[1], mark[2], mark[3], mark[4]
    if not (details and details.invalid) then
      -- If two marks land on one line (an edit merged rows), the first wins and
      -- the other counts as deleted.
      if id_by_line[line] == nil then
        id_by_line[line] = id
      end
    end
  end

  local entries = {}
  for offset, line in ipairs(lines) do
    if vim.trim(line) ~= "" then
      table.insert(entries, {
        id = id_by_line[HEADER_LINES + offset - 1],
        cells = grid.parse_row(line),
        -- Kept so a validation finding can be placed on the cell it came from
        -- rather than reported as a message about the buffer in general.
        line = HEADER_LINES + offset - 1,
      })
    end
  end
  return entries
end

--- Compute the pending change set without touching the database.
---@param view table
---@return table
function M.pending(view)
  return diff.compute({
    schema = view.schema,
    table = view.table,
    columns = view.columns,
    hidden = view.hidden,
    primary = view.primary,
    snapshot = view.snapshot,
    entries = M.read_entries(view),
  })
end

--- Ask the user to confirm a change set, showing both a summary and the exact
--- SQL the core would run.
---@param view table
---@param result table
---@param on_confirm fun()
local function confirm(view, result, on_confirm)
  client.async(function()
    local statements = {}
    local ok, response = pcall(
      client.call,
      "preview-changes",
      { changes = result.changes },
      view.session_id
    )
    if ok then
      statements = response.statements or {}
    end

    local lines = diff.describe(result, ("%s.%s"):format(view.schema, view.table))
    if #statements > 0 then
      table.insert(lines, "")
      table.insert(lines, "SQL:")
      for _, statement in ipairs(statements) do
        for _, line in ipairs(vim.split(statement, "\n")) do
          table.insert(lines, "  " .. line)
        end
      end
    end

    local target = session.get(view.session_id)
    if target and target.spec and target.spec.access == "sandbox" then
      table.insert(lines, "")
      table.insert(lines, "sandbox connection: this will be rolled back")
    end

    table.insert(lines, "")
    table.insert(lines, "<CR> apply    q cancel")

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].filetype = "sql"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false

    local winid = window.float(bufnr, {
      title = "apply changes",
      max_width = 0.9,
      max_height = 0.7,
      cursorline = false,
    })

    highlights.lines(bufnr, { { line = 0, group = "DBClientHeader" } })
    window.close_keys(bufnr, winid)
    vim.keymap.set("n", "<CR>", function()
      window.close(winid, bufnr)
      on_confirm()
    end, { buffer = bufnr, silent = true, nowait = true })
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

--- `:w` handler.
--- Check every pending edit against what the schema declares, and show the
--- findings on the cells they came from.
---
--- This is the same job `dbclient.errors` does, done early enough that the
--- server never has to refuse the write. The metadata is already in hand; the
--- round trip was the only thing making it feel like a question worth asking
--- the database.
---@param view table
---@return table[] findings
function M.validate(view)
  local ok, result = pcall(M.pending, view)
  if not ok then
    return {}
  end

  -- Validate against the declared types, falling back to the result set's
  -- description for anything the catalogue did not cover (a computed column,
  -- a view).
  local columns = {}
  for _, column in ipairs(view.columns) do
    table.insert(columns, view.meta and view.meta[column.name] or column)
  end

  local findings = require("dbclient.constraints").check_changes({
    changes = result.changes,
    columns = columns,
    bool_display = config.get().ui.bool_display,
  })

  local diagnostics = {}
  for _, finding in ipairs(findings) do
    local line = finding.line or HEADER_LINES
    local text = vim.api.nvim_buf_get_lines(view.bufnr, line, line + 1, false)[1] or ""
    local spans = grid.line_spans(text, view.spans)
    local span = finding.column_index and spans[finding.column_index]

    table.insert(diagnostics, {
      lnum = line,
      col = span and span.start or 0,
      end_lnum = line,
      end_col = span and math.min(span.finish, #text) or math.max(1, #text),
      severity = vim.diagnostic.severity.ERROR,
      source = "dbclient",
      message = finding.hint and (finding.message .. " — " .. finding.hint) or finding.message,
    })
  end

  vim.diagnostic.set(constraint_ns, view.bufnr, diagnostics, {})
  return findings
end

--- Re-check after an edit settles.
---
--- Debounced because it re-diffs the whole buffer, and because a diagnostic
--- that appears on every keystroke while a value is half-typed is noise.
---@param view table
function M.validate_soon(view)
  if view.validate_timer then
    view.validate_timer:stop()
    view.validate_timer:close()
  end
  view.validate_timer = vim.uv.new_timer()
  view.validate_timer:start(
    350,
    0,
    vim.schedule_wrap(function()
      if vim.api.nvim_buf_is_valid(view.bufnr) then
        pcall(M.validate, view)
      end
    end)
  )
end

function M.write()
  local view = M.view()
  if not view then
    return
  end

  if #view.primary == 0 then
    return notify("this table has no primary key; refusing to write", vim.log.levels.WARN)
  end

  local result = M.pending(view)

  if #result.errors > 0 and #result.changes == 0 then
    for _, err in ipairs(result.errors) do
      notify(err, vim.log.levels.ERROR)
    end
    return
  end

  if #result.changes == 0 then
    vim.bo[view.bufnr].modified = false
    return notify("no changes to write")
  end

  -- Refuse rather than let the server refuse: the answer is already known and
  -- a failed write inside a transaction is a worse place to find out.
  local findings = M.validate(view)
  if #findings > 0 then
    local first = findings[1]
    notify(
      ("%d edit(s) the schema will not accept — %s"):format(#findings, first.message),
      vim.log.levels.ERROR
    )
    if first.line then
      pcall(vim.api.nvim_win_set_cursor, 0, { first.line + 1, 0 })
    end
    return
  end

  confirm(view, result, function()
    client.async(function()
      local outcome = session.apply_changes(view.session_id, result.changes)
      notify(("applied %d change(s), %d row(s) affected"):format(
        outcome.applied,
        outcome.affected_rows
      ))
      local target = session.get(view.session_id)
      session.record(target, {
        sql = table.concat(outcome.statements, "\n"),
        ok = true,
        affected = outcome.affected_rows,
        rows = 0,
        elapsed_ms = 0,
      })
      -- Remember how to put this back; see `dbclient.undolog`.
      pcall(function()
        require("dbclient.undolog").record({
          connection = target and target.name or "?",
          changes = result.changes,
          statements = outcome.statements,
        })
      end)
      vim.bo[view.bufnr].modified = false
      load(view)
    end, function(err)
      notify(err, vim.log.levels.ERROR)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

function M.inspect_value()
  local cell = M.current_cell()
  if not cell then
    return notify("move onto a data cell first", vim.log.levels.WARN)
  end

  value_inspector.open({
    value = cell.value,
    column = cell.column,
    session = cell.view.session_id,
    title = ("%s.%s"):format(cell.view.table, cell.column.name),
    on_save = function(text)
      local line = HEADER_LINES + cell.row_index
      local current = vim.api.nvim_buf_get_lines(cell.view.bufnr, line - 1, line, false)[1]
      if not current then
        return
      end
      local cells = grid.parse_row(current)
      local visible = diff.visible_columns(cell.view.columns, cell.view.hidden)
      for position, column_index in ipairs(visible) do
        if column_index == cell.column_index then
          cells[position] = grid.escape(text)
        end
      end
      -- Re-render the row from the edited cells so widths stay aligned.
      local values = {}
      for position, column_index in ipairs(visible) do
        values[column_index] = grid.parse_value(cells[position], cell.view.columns[column_index])
      end
      local rebuilt = grid.render_row(values, cell.view.columns, cell.view.sizes, cell.view.hidden)
      vim.api.nvim_buf_set_lines(cell.view.bufnr, line - 1, line, false, { rebuilt })
      notify("staged; :w to apply")
    end,
  })
end

--- Replace the cell under the cursor with the NULL placeholder.
--- Registered as an operator so `.` repeats it.
function M.set_null_op()
  local cell = M.current_cell()
  if not cell then
    return
  end
  if cell.column and not cell.column.nullable and cell.column.nullable ~= nil then
    return notify(("%s is NOT NULL"):format(cell.column.name), vim.log.levels.WARN)
  end

  local line_number = HEADER_LINES + cell.row_index
  local line = vim.api.nvim_buf_get_lines(cell.view.bufnr, line_number - 1, line_number, false)[1]
  if not line then
    return
  end

  local cells = grid.parse_row(line)
  local visible = diff.visible_columns(cell.view.columns, cell.view.hidden)
  local values = {}
  for position, column_index in ipairs(visible) do
    if column_index == cell.column_index then
      values[column_index] = vim.NIL
    else
      values[column_index] = grid.parse_value(cells[position], cell.view.columns[column_index])
    end
  end

  local rebuilt = grid.render_row(values, cell.view.columns, cell.view.sizes, cell.view.hidden)
  vim.api.nvim_buf_set_lines(cell.view.bufnr, line_number - 1, line_number, false, { rebuilt })
  move_to(cell.view, cell.row_index, cell.column_index)
end

function M.set_null()
  vim.o.operatorfunc = "v:lua.require'dbclient.ui.data'.set_null_op"
  return "g@l"
end

--- Follow the foreign key on the cell under the cursor.
function M.follow_fk()
  local cell = M.current_cell()
  if not cell then
    return
  end

  local reference = cell.view.fk[cell.column.name]
  if not reference then
    return notify(("%s is not a foreign key"):format(cell.column.name), vim.log.levels.WARN)
  end
  if cell.value == nil or cell.value == vim.NIL then
    return notify("the cell is NULL", vim.log.levels.WARN)
  end

  -- Record the jump so <C-o> comes back here.
  vim.cmd("normal! m'")

  local literal = tostring(cell.value):gsub("'", "''")
  M.open({
    session_id = cell.view.session_id,
    schema = reference.ref_schema ~= "" and reference.ref_schema or cell.view.schema,
    table = reference.ref_table,
    filter = ("%s = '%s'"):format(reference.ref_column, literal),
    split = "botright split",
    via = ("%s.%s"):format(cell.view.table, cell.column.name),
  })
end

--- Open the rows of another table that reference this one.
---
--- The forward direction is `gd`; this is the same move backwards along the
--- graph, and it is just as common a question.
function M.follow_reverse()
  local cell = M.current_cell()
  if not cell then
    return
  end

  local view = cell.view
  if #view.primary == 0 then
    return notify("this table has no primary key", vim.log.levels.WARN)
  end

  client.async(function()
    local references = session.referencing_keys(view.session_id, view.schema, view.table)
    if #references == 0 then
      return notify("nothing references this table")
    end

    local pk_values = {}
    for index, column in ipairs(view.columns) do
      for _, name in ipairs(view.primary) do
        if column.name == name then
          pk_values[name] = view.rows[cell.row_index][index]
        end
      end
    end

    local choices = {}
    for _, reference in ipairs(references) do
      local value = pk_values[reference.ref_column]
      if value ~= nil and value ~= vim.NIL then
        table.insert(choices, {
          reference = reference,
          value = tostring(value),
          label = ("%s.%s  on %s"):format(
            reference.schema,
            reference.table,
            reference.column
          ),
        })
      end
    end

    if #choices == 0 then
      return notify("no usable key on this row", vim.log.levels.WARN)
    end

    local function go(choice)
      vim.cmd("normal! m'")
      M.open({
        session_id = view.session_id,
        schema = choice.reference.schema,
        table = choice.reference.table,
        filter = ("%s = '%s'"):format(choice.reference.column, choice.value:gsub("'", "''")),
        split = "botright split",
        via = ("← %s"):format(view.table),
      })
    end

    if #choices == 1 then
      return go(choices[1])
    end

    vim.ui.select(choices, {
      prompt = "referencing rows in",
      format_item = function(choice)
        return choice.label
      end,
    }, function(choice)
      if choice then
        go(choice)
      end
    end)
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

--- Populate the quickfix list with rows referencing the current one.
function M.find_references()
  local cell = M.current_cell()
  if not cell then
    return
  end

  local view = cell.view
  if #view.primary == 0 then
    return notify("this table has no primary key", vim.log.levels.WARN)
  end

  client.async(function()
    local references = session.referencing_keys(view.session_id, view.schema, view.table)
    if #references == 0 then
      return notify("nothing references this table")
    end

    local pk_values = {}
    for index, column in ipairs(view.columns) do
      for _, name in ipairs(view.primary) do
        if column.name == name then
          pk_values[name] = view.rows[cell.row_index][index]
        end
      end
    end

    local items = {}
    for _, reference in ipairs(references) do
      local target_value = pk_values[reference.ref_column]
      if target_value ~= nil and target_value ~= vim.NIL then
        local literal = tostring(target_value):gsub("'", "''")
        local filter = ("%s = '%s'"):format(reference.column, literal)
        local count = session.count(view.session_id, {
          schema = reference.schema,
          table = reference.table,
          filter = filter,
        })
        if count > 0 then
          table.insert(items, {
            text = ("%s.%s  %d row(s)  where %s"):format(
              reference.schema,
              reference.table,
              count,
              filter
            ),
            user_data = {
              dbclient = true,
              session_id = view.session_id,
              schema = reference.schema,
              table = reference.table,
              filter = filter,
            },
          })
        end
      end
    end

    if #items == 0 then
      return notify("no rows reference this one")
    end

    vim.fn.setqflist({}, " ", {
      title = ("DBClient references: %s.%s"):format(view.schema, view.table),
      items = items,
    })
    vim.cmd("copen")
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

function M.column_stats()
  local cell = M.current_cell()
  if not cell then
    return
  end
  require("dbclient.ui.stats").show({
    session_id = cell.view.session_id,
    schema = cell.view.schema,
    table = cell.view.table,
    column = cell.column.name,
  })
end

--- Sort by the column under the cursor, cycling asc → desc → unsorted.
function M.sort_column()
  local cell = M.current_cell()
  if not cell then
    return
  end

  local view = cell.view
  local name = cell.column.name
  local current = view.sort[1]
  local next_sort

  if not current or current.column ~= name then
    next_sort = { { column = name, dir = "asc" } }
  elseif current.dir == "asc" then
    next_sort = { { column = name, dir = "desc" } }
  else
    next_sort = {}
  end

  view.sort = next_sort
  view.offset = 0
  M.reload()
end

function M.filter()
  local view = M.view()
  if not view then
    return
  end
  vim.ui.input({ prompt = "where ", default = view.filter or "" }, function(input)
    if input == nil then
      return
    end
    view.filter = vim.trim(input) ~= "" and input or nil
    view.offset = 0
    M.reload()
  end)
end

function M.clear_filter()
  local view = M.view()
  if not view then
    return
  end
  view.filter = nil
  view.sort = {}
  view.offset = 0
  M.reload()
end

function M.page(delta)
  local view = M.view()
  if not view then
    return
  end
  local next_offset = (view.offset or 0) + delta * view.limit
  if next_offset < 0 then
    next_offset = 0
  end
  if view.total and next_offset >= view.total then
    return notify("already at the last page")
  end
  view.offset = next_offset
  M.reload()
end

function M.hide_column()
  local cell = M.current_cell()
  if not cell then
    return
  end
  if #diff.visible_columns(cell.view.columns, cell.view.hidden) <= 1 then
    return notify("at least one column has to stay visible", vim.log.levels.WARN)
  end
  cell.view.hidden[cell.column_index] = true
  M.render(cell.view)
end

function M.show_columns()
  local view = M.view()
  if not view then
    return
  end
  view.hidden = {}
  M.render(view)
end

--- Transposed single-row view, the equivalent of `\G` in a CLI client.
function M.transpose()
  local cell = M.current_cell()
  if not cell then
    return
  end

  local view = cell.view
  local row = view.rows[cell.row_index]
  local width = 0
  for _, column in ipairs(view.columns) do
    width = math.max(width, grid.width(column.name))
  end

  local lines = {}
  for index, column in ipairs(view.columns) do
    local text = (grid.display(row[index], column))
    table.insert(lines, ("%s  %s"):format(grid.pad(column.name, width, "left"), text))
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "dbclient-transpose"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  local winid = window.float(bufnr, {
    title = ("%s.%s row %d"):format(view.schema, view.table, cell.row_index),
    max_width = 0.8,
    max_height = 0.8,
  })
  window.close_keys(bufnr, winid)
end

--- Copy the current row into a new unsaved line, ready to become an INSERT.
function M.paste_row()
  local cell = M.current_cell()
  if not cell then
    return
  end
  local line_number = HEADER_LINES + cell.row_index
  local line = vim.api.nvim_buf_get_lines(cell.view.bufnr, line_number - 1, line_number, false)[1]
  if not line then
    return
  end
  vim.api.nvim_buf_set_lines(cell.view.bufnr, line_number, line_number, false, { line })
  vim.api.nvim_win_set_cursor(0, { line_number + 1, 0 })
  notify("duplicated as a new row; edit the key and :w")
end

function M.yank()
  require("dbclient.export").yank_menu(M.view(), M.current_cell())
end

function M.generate()
  local view = M.view()
  if not view then
    return
  end
  require("dbclient.codegen").generate({
    session_id = view.session_id,
    schema = view.schema,
    table = view.table,
  })
end

function M.import()
  local view = M.view()
  if not view then
    return
  end
  require("dbclient.import").prompt({
    session_id = view.session_id,
    schema = view.schema,
    table = view.table,
  })
end

function M.export()
  local view = M.view()
  if not view then
    return
  end
  require("dbclient.export.ui").open({
    session_id = view.session_id,
    schema = view.schema,
    table = view.table,
    values = vim.tbl_extend("force", require("dbclient.export.spec").defaults(), {
      -- Carry the view across, so what you exported is what you were looking at.
      filter = view.filter or "",
      order = (view.sort and view.sort[1])
          and ("%s %s"):format(view.sort[1].column, view.sort[1].dir)
        or "",
    }),
  })
end

function M.open_ddl()
  local view = M.view()
  if not view then
    return
  end
  require("dbclient.ui.ddl").open({
    session_id = view.session_id,
    kind = "table",
    schema = view.schema,
    name = view.table,
  })
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

--- Handlers passed to the shared mapping table.
function M.handlers()
  return {
    inspect_value = M.inspect_value,
    record = function()
      require("dbclient.neighbourhood").from_cursor()
    end,
    follow_fk = M.follow_fk,
    find_references = M.find_references,
    column_stats = M.column_stats,
    sort_column = M.sort_column,
    filter = M.filter,
    clear_filter = M.clear_filter,
    transpose = M.transpose,
    hide_column = M.hide_column,
    show_columns = M.show_columns,
    set_null = M.set_null,
    yank = M.yank,
    paste_row = M.paste_row,
    reload = M.reload,
    open_ddl = M.open_ddl,
    generate = M.generate,
    import = M.import,
    export = M.export,
    fixture = function()
      require("dbclient.fixture").from_cursor()
    end,
    follow_reverse = M.follow_reverse,
    trail_back = function()
      trail.back()
    end,
    trail_forward = function()
      trail.forward()
    end,
    trail_pick = trail.pick,
    next_cell = function()
      M.next_cell(1)
    end,
    prev_cell = function()
      M.next_cell(-1)
    end,
    next_row = function()
      M.next_row(1)
    end,
    prev_row = function()
      M.next_row(-1)
    end,
    next_page = function()
      M.page(1)
    end,
    prev_page = function()
      M.page(-1)
    end,
    help = help.handler("data"),
  }
end

--- Attach mappings, text objects and the write handler to a data buffer.
---@param view table
function M.attach(view)
  local bufnr = view.bufnr

  keymap.apply("data", bufnr, M.handlers())
  require("dbclient.textobj").attach(bufnr, function()
    return M.view(bufnr), HEADER_LINES
  end)

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function()
      M.write()
    end,
  })

  -- Check as you type. The schema already said what is legal, so a value the
  -- column will not hold should be marked where it was typed rather than
  -- reported after a round trip.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = bufnr,
    callback = function()
      local current = M.view(bufnr)
      if current then
        M.validate_soon(current)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      local current = M.views[bufnr]
      if current and current.validate_timer then
        pcall(function()
          current.validate_timer:stop()
          current.validate_timer:close()
        end)
      end
      M.views[bufnr] = nil
    end,
  })

  -- Keep the cursor out of the header, where editing would corrupt the grid.
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = bufnr,
    callback = function()
      local position = vim.api.nvim_win_get_cursor(0)
      if position[1] <= HEADER_LINES and #view.rows > 0 then
        pcall(vim.api.nvim_win_set_cursor, 0, { HEADER_LINES + 1, position[2] })
      end
    end,
  })
end

M.HEADER_LINES = HEADER_LINES

return M

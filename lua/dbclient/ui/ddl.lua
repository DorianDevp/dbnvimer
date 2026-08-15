--- DDL buffers and schema diffing.
---
--- `gD` opens an object's `create` statement as a real SQL buffer. Editing it
--- and writing produces a migration in a second SQL buffer, which the user
--- reads, edits and runs like any other query. Nothing is applied behind their
--- back, so the tool can help with changes it only partly understands.
---
--- The comparison view leans on Neovim's own `:diffthis`, which means `]c`,
--- `do` and `dp` work without DBClient implementing a diff at all.

local buffer = require("dbclient.ui.buffer")
local client = require("dbclient.core.client")
local help = require("dbclient.ui.help")
local keymap = require("dbclient.keymap")
local migrate = require("dbclient.ddl.migrate")
local session = require("dbclient.session")
local winbar = require("dbclient.ui.winbar")

local M = {
  --- bufnr -> descriptor
  buffers = {},
}

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

local function buffer_name(session_name, kind, schema, name)
  return ("dbclient://%s/%s/%s.%s.sql"):format(session_name, kind, schema, name)
end

--- Open the DDL for an object.
---@param opts { session_id?: string, kind: string, schema: string, name: string, split?: string }
function M.open(opts)
  local target = session.get(opts.session_id)
  if not target then
    return notify("no active connection", vim.log.levels.WARN)
  end

  client.async(function()
    local ddl = session.ddl(target.id, opts.kind, opts.schema, opts.name)
    local name = buffer_name(target.name, opts.kind, opts.schema, opts.name)
    local bufnr = buffer.scratch(name, { modifiable = true, buftype = "acwrite" })
    local first = M.buffers[bufnr] == nil

    M.buffers[bufnr] = {
      session_id = target.id,
      kind = opts.kind,
      schema = opts.schema,
      name = opts.name,
      original = ddl,
    }

    vim.bo[bufnr].filetype = "sql"
    buffer.set_lines(bufnr, vim.split(ddl, "\n"))
    buffer.show(bufnr, opts.split or "vsplit")
    winbar.bind(bufnr, target.id)

    if first then
      M.attach(bufnr)
    end
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

--- Re-fetch from the server, discarding local edits.
function M.reload()
  local bufnr = vim.api.nvim_get_current_buf()
  local descriptor = M.buffers[bufnr]
  if not descriptor then
    return
  end
  M.open({
    session_id = descriptor.session_id,
    kind = descriptor.kind,
    schema = descriptor.schema,
    name = descriptor.name,
  })
end

--- Open the server's version beside the buffer and turn on diff mode.
function M.diff()
  local bufnr = vim.api.nvim_get_current_buf()
  local descriptor = M.buffers[bufnr]
  if not descriptor then
    return
  end

  local target = session.get(descriptor.session_id)
  if not target then
    return notify("connection is gone", vim.log.levels.WARN)
  end

  client.async(function()
    local server = session.ddl(target.id, descriptor.kind, descriptor.schema, descriptor.name)
    local name = ("dbclient://%s/%s/%s.%s.server.sql"):format(
      target.name,
      descriptor.kind,
      descriptor.schema,
      descriptor.name
    )
    local server_buf = buffer.scratch(name, { modifiable = false })
    vim.bo[server_buf].filetype = "sql"
    buffer.set_lines(server_buf, vim.split(server, "\n"))

    vim.cmd("diffthis")
    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(0, server_buf)
    vim.cmd("diffthis")
    vim.cmd("wincmd p")
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

--- Turn the edited DDL into a migration query buffer.
function M.write()
  local bufnr = vim.api.nvim_get_current_buf()
  local descriptor = M.buffers[bufnr]
  if not descriptor then
    return
  end

  local target = session.get(descriptor.session_id)
  if not target then
    return notify("connection is gone", vim.log.levels.WARN)
  end

  local edited = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  if vim.trim(edited) == vim.trim(descriptor.original) then
    vim.bo[bufnr].modified = false
    return notify("no changes")
  end

  if descriptor.kind ~= "table" then
    -- Views, routines and triggers replace wholesale, so the edited text is
    -- already the migration.
    return M.open_migration(target, descriptor, { statements = { edited }, notes = {} })
  end

  local result = migrate.compute({
    before = descriptor.original,
    after = edited,
    adapter = target.spec.adapter,
    schema = descriptor.schema,
    table = descriptor.name,
  })

  M.open_migration(target, descriptor, result)
  vim.bo[bufnr].modified = false
end

--- Put the derived migration in a query buffer the user can edit and run.
---@param target table
---@param descriptor table
---@param result { statements: string[], notes: string[] }
function M.open_migration(target, descriptor, result)
  local lines = {
    ("-- @conn: %s"):format(target.name),
    ("-- migration for %s.%s"):format(descriptor.schema, descriptor.name),
    "-- Review, edit, then run it like any other query.",
    "",
  }

  for _, note in ipairs(result.notes) do
    for _, line in ipairs(vim.split(note, "\n")) do
      table.insert(lines, "-- ! " .. line)
    end
  end
  if #result.notes > 0 then
    table.insert(lines, "")
  end

  for _, statement in ipairs(result.statements) do
    table.insert(lines, statement)
  end

  if #result.statements == 0 then
    table.insert(lines, "-- nothing to run")
  end

  local name = ("dbclient://%s/migration/%s.%s.sql"):format(
    target.name,
    descriptor.schema,
    descriptor.name
  )
  local bufnr = buffer.scratch(name, { modifiable = true, buftype = "nofile" })
  vim.bo[bufnr].filetype = "sql"
  buffer.set_lines(bufnr, lines)
  buffer.show(bufnr, "botright split")
  winbar.bind(bufnr, target.id)

  local query = require("dbclient.ui.query")
  if not query.buffers[bufnr] then
    query.attach(bufnr)
  end
  query.buffers[bufnr] = { session_id = target.id }

  notify(("migration ready: %d statement(s)"):format(#result.statements))
end

function M.attach(bufnr)
  keymap.apply("ddl", bufnr, {
    reload = M.reload,
    diff = M.diff,
    close = function()
      buffer.hide(bufnr)
    end,
    help = help.handler("ddl"),
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function()
      M.write()
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      M.buffers[bufnr] = nil
    end,
  })
end

--- Compare two schemas, or the same schema across two connections, using
--- Neovim's diff mode.
---@param opts { left: { session_id: string, schema: string }, right: { session_id: string, schema: string } }
function M.diff_schemas(opts)
  client.async(function()
    local function collect(side)
      local target = session.require_session(side.session_id)
      local lines = { ("-- %s  %s"):format(target.name, side.schema), "" }
      for _, entry in ipairs(session.tables(target.id, side.schema)) do
        local ok, ddl = pcall(
          session.ddl,
          target.id,
          entry.kind == "VIEW" and "view" or "table",
          side.schema,
          entry.name
        )
        if ok then
          vim.list_extend(lines, vim.split(ddl, "\n"))
          table.insert(lines, "")
        end
      end
      return lines, target.name
    end

    local left_lines, left_name = collect(opts.left)
    local right_lines, right_name = collect(opts.right)

    local left_buf = buffer.scratch(
      ("dbclient://diff/%s.%s.sql"):format(left_name, opts.left.schema),
      { modifiable = false }
    )
    local right_buf = buffer.scratch(
      ("dbclient://diff/%s.%s.sql"):format(right_name, opts.right.schema),
      { modifiable = false }
    )

    vim.bo[left_buf].filetype = "sql"
    vim.bo[right_buf].filetype = "sql"
    buffer.set_lines(left_buf, left_lines)
    buffer.set_lines(right_buf, right_lines)

    vim.cmd("tabnew")
    vim.api.nvim_win_set_buf(0, left_buf)
    vim.cmd("diffthis")
    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(0, right_buf)
    vim.cmd("diffthis")
    vim.cmd("wincmd p")

    notify("schema diff ready: ]c and [c walk the differences")
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

return M

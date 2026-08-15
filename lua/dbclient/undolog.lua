--- A log of the writes DBClient performed, with the statement that undoes each.
---
--- This is not database undo and does not pretend to be: it only covers writes
--- DBClient itself made through the data buffer, where the previous values are
--- known. That is enough for the actual problem, which is "what did I just set
--- that to, and how do I put it back" at an hour when reading a binlog is not
--- appealing.
---
--- Nothing here is applied automatically. The compensating statements open in a
--- query buffer to be read and run like anything else.

local config = require("dbclient.config")

local M = {
  entries = nil,
}

local function path()
  return vim.fs.dirname(config.get().history.path) .. "/undo.jsonl"
end

local function ensure_dir()
  local directory = vim.fs.dirname(path())
  if vim.fn.isdirectory(directory) == 0 then
    vim.fn.mkdir(directory, "p")
  end
end

---@return table[]
function M.load()
  if M.entries then
    return M.entries
  end
  M.entries = {}

  if vim.fn.filereadable(path()) ~= 1 then
    return M.entries
  end
  for _, line in ipairs(vim.fn.readfile(path())) do
    if line ~= "" then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and type(entry) == "table" then
        table.insert(M.entries, entry)
      end
    end
  end
  return M.entries
end

--- Derive the change that would put a row back the way it was.
---
--- Returns nil when the inverse is not knowable: an insert whose generated key
--- we never saw, for instance.
---@param change table
---@return table|nil
function M.invert(change)
  if change.op == "update" then
    local set = {}
    for column, old in pairs(change.expect or {}) do
      set[column] = old
    end
    if vim.tbl_isempty(set) then
      return nil
    end
    return {
      op = "update",
      schema = change.schema,
      table = change.table,
      set = set,
      -- The row is identified by what the key became, not what it was.
      pk = vim.tbl_extend("force", change.pk or {}, M.key_after(change)),
    }
  end

  if change.op == "delete" then
    -- Only the key is known, so the row cannot be reconstructed in full.
    return nil
  end

  if change.op == "insert" then
    local pk = {}
    for column, value in pairs(change.values or {}) do
      pk[column] = value
    end
    if vim.tbl_isempty(pk) then
      return nil
    end
    return {
      op = "delete",
      schema = change.schema,
      table = change.table,
      pk = pk,
    }
  end

  return nil
end

--- The primary key after an update that changed part of the key.
---@param change table
---@return table
function M.key_after(change)
  local after = {}
  for column in pairs(change.pk or {}) do
    if change.set and change.set[column] ~= nil then
      after[column] = change.set[column]
    end
  end
  return after
end

--- Record a batch of applied changes.
---@param opts { connection: string, changes: table[], statements: string[] }
function M.record(opts)
  local inverses = {}
  local undoable = 0
  for _, change in ipairs(opts.changes) do
    local inverse = M.invert(change)
    table.insert(inverses, inverse or vim.NIL)
    if inverse then
      undoable = undoable + 1
    end
  end

  local entry = {
    at = os.time(),
    connection = opts.connection,
    target = ("%s.%s"):format(opts.changes[1].schema, opts.changes[1].table),
    count = #opts.changes,
    undoable = undoable,
    changes = opts.changes,
    inverses = inverses,
    statements = opts.statements,
  }

  local entries = M.load()
  table.insert(entries, entry)
  while #entries > 200 do
    table.remove(entries, 1)
  end

  ensure_dir()
  pcall(function()
    local handle = io.open(path(), "a")
    if handle then
      handle:write(vim.json.encode(entry) .. "\n")
      handle:close()
    end
  end)
end

---@param entry table
---@return string
function M.label(entry)
  return ("%s  %-14s %s  %d change(s), %d undoable"):format(
    os.date("%m-%d %H:%M:%S", entry.at or 0),
    entry.connection or "?",
    entry.target or "?",
    entry.count or 0,
    entry.undoable or 0
  )
end

--- Show the log and offer to build the compensating statements.
function M.open()
  local entries = M.load()
  if #entries == 0 then
    return vim.notify("DBClient: nothing has been written through DBClient yet")
  end

  local newest = {}
  for index = #entries, 1, -1 do
    table.insert(newest, entries[index])
  end

  vim.ui.select(newest, {
    prompt = "writes made by DBClient",
    format_item = M.label,
  }, function(choice)
    if not choice then
      return
    end
    M.show(choice)
  end)
end

--- Open one log entry: what ran, and what would undo it.
---@param entry table
function M.show(entry)
  local session = require("dbclient.session")
  local target = session.find_by_name(entry.connection)

  local lines = {
    ("-- @conn: %s"):format(entry.connection or ""),
    ("-- %s on %s"):format(os.date("%Y-%m-%d %H:%M:%S", entry.at or 0), entry.target or ""),
    "--",
    "-- what ran:",
  }
  for _, statement in ipairs(entry.statements or {}) do
    table.insert(lines, "--   " .. statement)
  end

  table.insert(lines, "")

  local inverses = {}
  for _, inverse in ipairs(entry.inverses or {}) do
    if inverse ~= vim.NIL and type(inverse) == "table" then
      table.insert(inverses, inverse)
    end
  end

  if #inverses == 0 then
    table.insert(lines, "-- Nothing here can be undone automatically.")
    table.insert(lines, "-- A deleted row's other columns were never read, so it")
    table.insert(lines, "-- cannot be reconstructed from this log.")
  else
    table.insert(lines, "-- To undo, review and run:")
    table.insert(lines, "")
  end

  local function present(statements)
    vim.list_extend(lines, statements)
    local buffer = require("dbclient.ui.buffer")
    local bufnr = buffer.scratch(
      ("dbclient://undo/%s.sql"):format(tostring(entry.at)),
      { modifiable = true }
    )
    vim.bo[bufnr].filetype = "sql"
    buffer.set_lines(bufnr, lines)
    buffer.show(bufnr, "botright split")

    if target then
      local query = require("dbclient.ui.query")
      if not query.buffers[bufnr] then
        query.attach(bufnr)
      end
      query.buffers[bufnr] = { session_id = target.id }
      require("dbclient.ui.winbar").bind(bufnr, target.id)
    end
  end

  if #inverses == 0 or not target then
    if #inverses > 0 then
      table.insert(lines, "-- (connect to " .. tostring(entry.connection) .. " to render the SQL)")
    end
    return present({})
  end

  -- Ask the core to render the inverse exactly the way it would run it.
  local client = require("dbclient.core.client")
  client.async(function()
    local statements = client.call(
      "preview-changes",
      { changes = inverses },
      target.id
    ).statements or {}
    present(statements)
  end, function(err)
    present({ "-- could not render the undo statements: " .. tostring(err) })
  end)
end

function M.clear()
  M.entries = {}
  ensure_dir()
  pcall(vim.fn.writefile, {}, path())
  vim.notify("DBClient: undo log cleared")
end

M.path = path

return M

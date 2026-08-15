--- The schema as a tree of files on disk.
---
--- Once every table, view and routine is a `.sql` file in the project, the
--- editor's own tools work on the schema: `:vimgrep /tax_rate/ db/schema/**`
--- answers "which routine touches this column", `:argdo` edits across it, and
--- the fuzzy finder browses it. None of that needed writing, which is the
--- argument for files over a bespoke search box.
---
--- The second thing it buys is history. A dumped tree committed alongside the
--- code makes `git diff` show what a migration actually did, and comparing the
--- live schema against the committed one catches the hotfix nobody wrote down.
---
--- Files are byte-stable on purpose: no timestamp, no connection name, no
--- generated-on header. A header would make every dump a diff, which would make
--- the diffs worthless.

local buffer = require("dbclient.ui.buffer")
local client = require("dbclient.core.client")
local config = require("dbclient.config")
local session = require("dbclient.session")

local M = {}

--- Where each kind of object lives under the schema directory.
local DIRECTORIES = {
  table = "tables",
  view = "views",
  routine = "routines",
}

--- Default location, relative to the working directory. `db/schema` is a common
--- enough convention that it needs no explanation in a code review.
M.DEFAULT_DIR = "db/schema"

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------

--- Make an object name safe as a filename without making it unrecognisable.
---
--- Anything a filesystem or a shell would object to becomes `%xx`, which is
--- reversible and leaves ordinary names untouched.
---@param name string
---@return string
function M.encode_name(name)
  return (name:gsub("[^%w%-_.]", function(char)
    return ("%%%02x"):format(char:byte())
  end))
end

---@param name string
---@return string
function M.decode_name(name)
  return (name:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- Path of one object's file.
---@param dir string
---@param schema string
---@param kind string
---@param name string
---@return string
function M.path_for(dir, schema, kind, name)
  return table.concat({
    dir,
    M.encode_name(schema),
    DIRECTORIES[kind] or kind,
    M.encode_name(name) .. ".sql",
  }, "/")
end

---@param dir string|nil
---@return string
function M.resolve_dir(dir)
  if dir and dir ~= "" then
    return vim.fn.fnamemodify(dir, ":p"):gsub("/$", "")
  end
  return vim.fn.fnamemodify(M.DEFAULT_DIR, ":p"):gsub("/$", "")
end

-- ---------------------------------------------------------------------------
-- Reading the live schema
-- ---------------------------------------------------------------------------

--- Every object in a schema, as `{ kind, name }`.
---
--- Runs on the coroutine, so call it from inside `client.async`.
---@param session_id string
---@param schema string
---@return table[]
function M.objects(session_id, schema)
  local objects = {}

  for _, entry in ipairs(session.tables(session_id, schema, true) or {}) do
    local kind = tostring(entry.kind or ""):lower()
    table.insert(objects, {
      kind = kind:find("view") and "view" or "table",
      name = entry.name,
    })
  end

  for _, entry in ipairs(session.routines(session_id, schema, true) or {}) do
    table.insert(objects, { kind = "routine", name = entry.name })
  end

  table.sort(objects, function(a, b)
    if a.kind ~= b.kind then
      return a.kind < b.kind
    end
    return a.name < b.name
  end)
  return objects
end

--- The DDL for one object, normalised for storage.
---
--- Trailing whitespace goes, and the text ends in exactly one newline, so two
--- dumps of an unchanged object are byte-identical.
---@param session_id string
---@param schema string
---@param object table
---@return string
function M.ddl_for(session_id, schema, object)
  local text = tostring(session.ddl(session_id, object.kind, schema, object.name) or "")
  text = text:gsub("\r\n", "\n"):gsub("[ \t]+\n", "\n"):gsub("%s+$", "")
  return text .. "\n"
end

-- ---------------------------------------------------------------------------
-- Files
-- ---------------------------------------------------------------------------

---@param path string
---@return string|nil
local function read_file(path)
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end
  local text = handle:read("*a")
  handle:close()
  return text
end

---@param path string
---@param text string
---@return boolean written  false when the file already held exactly this
local function write_file(path, text)
  if read_file(path) == text then
    return false
  end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local handle = assert(io.open(path, "wb"))
  handle:write(text)
  handle:close()
  return true
end

--- Every `.sql` file the dump owns under one schema directory.
---@param dir string
---@param schema string
---@return table<string, boolean>
local function existing_files(dir, schema)
  local found = {}
  for _, sub in pairs(DIRECTORIES) do
    local pattern = ("%s/%s/%s/*.sql"):format(dir, M.encode_name(schema), sub)
    for _, path in ipairs(vim.fn.glob(pattern, false, true)) do
      found[path] = true
    end
  end
  return found
end

-- ---------------------------------------------------------------------------
-- Dump
-- ---------------------------------------------------------------------------

--- Write a schema out as files.
---
--- Runs on the coroutine.
---@param opts { session_id: string, schema: string, dir?: string, prune?: boolean }
---@return { dir: string, written: string[], unchanged: integer, removed: string[], failed: table[] }
function M.dump(opts)
  local dir = M.resolve_dir(opts.dir)
  local schema = opts.schema
  local objects = M.objects(opts.session_id, schema)

  local stale = existing_files(dir, schema)
  local result = { dir = dir, written = {}, unchanged = 0, removed = {}, failed = {} }

  for _, object in ipairs(objects) do
    local path = M.path_for(dir, schema, object.kind, object.name)
    stale[path] = nil

    local ok, text = pcall(M.ddl_for, opts.session_id, schema, object)
    if not ok then
      -- One object that will not describe itself must not lose the other 285.
      table.insert(result.failed, { name = object.name, kind = object.kind, error = text })
    elseif write_file(path, text) then
      table.insert(result.written, path)
    else
      result.unchanged = result.unchanged + 1
    end
  end

  if opts.prune ~= false then
    -- Only files this dump owns are candidates, so a hand-written file
    -- elsewhere in the tree is never touched.
    for path in pairs(stale) do
      if vim.fn.delete(path) == 0 then
        table.insert(result.removed, path)
      end
    end
  end

  table.sort(result.written)
  table.sort(result.removed)
  return result
end

-- ---------------------------------------------------------------------------
-- Drift
-- ---------------------------------------------------------------------------

--- Compare the live schema against what is on disk.
---
--- Runs on the coroutine.
---@param opts { session_id: string, schema: string, dir?: string }
---@return { dir: string, findings: table[], checked: integer }
function M.drift(opts)
  local dir = M.resolve_dir(opts.dir)
  local schema = opts.schema
  local objects = M.objects(opts.session_id, schema)

  local unseen = existing_files(dir, schema)
  local findings = {}
  local checked = 0

  for _, object in ipairs(objects) do
    local path = M.path_for(dir, schema, object.kind, object.name)
    unseen[path] = nil

    local ok, live = pcall(M.ddl_for, opts.session_id, schema, object)
    if ok then
      checked = checked + 1
      local stored = read_file(path)
      if not stored then
        table.insert(findings, {
          status = "untracked",
          kind = object.kind,
          name = object.name,
          path = path,
          detail = "on the server, not in the repository",
        })
      elseif stored ~= live then
        table.insert(findings, {
          status = "changed",
          kind = object.kind,
          name = object.name,
          path = path,
          detail = "the server and the repository disagree",
        })
      end
    end
  end

  for path in pairs(unseen) do
    table.insert(findings, {
      status = "dropped",
      kind = "unknown",
      name = M.decode_name(vim.fn.fnamemodify(path, ":t:r")),
      path = path,
      detail = "in the repository, not on the server",
    })
  end

  table.sort(findings, function(a, b)
    if a.status ~= b.status then
      return a.status < b.status
    end
    return a.name < b.name
  end)

  return { dir = dir, findings = findings, checked = checked }
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

---@param opts { schema?: string, dir?: string, prune?: boolean }|nil
function M.dump_command(opts)
  opts = opts or {}
  local target = session.current()
  if not target then
    return notify("no active connection", vim.log.levels.WARN)
  end
  local schema = opts.schema or (target.info and target.info.database)
  if not schema then
    return notify("no schema; pass one", vim.log.levels.ERROR)
  end

  notify(("dumping %s…"):format(schema))
  client.async(function()
    local result = M.dump({
      session_id = target.id,
      schema = schema,
      dir = opts.dir,
      prune = opts.prune,
    })

    local parts = {
      ("%d written"):format(#result.written),
      ("%d unchanged"):format(result.unchanged),
    }
    if #result.removed > 0 then
      table.insert(parts, ("%d removed"):format(#result.removed))
    end
    if #result.failed > 0 then
      table.insert(parts, ("%d failed"):format(#result.failed))
    end
    notify(("%s → %s: %s"):format(schema, vim.fn.fnamemodify(result.dir, ":~:."), table.concat(parts, ", ")))

    if #result.failed > 0 then
      for _, failure in ipairs(result.failed) do
        notify(("%s %s: %s"):format(failure.kind, failure.name, failure.error), vim.log.levels.WARN)
      end
    end
  end, function(err)
    notify(tostring(err), vim.log.levels.ERROR)
  end)
end

--- Render a drift report.
---@param report table
---@param schema string
---@return string[] lines, table[] marks
function M.render_drift(report, schema)
  local relative = vim.fn.fnamemodify(report.dir, ":~:.")
  local lines = {
    ("%s  vs  %s"):format(schema, relative),
    "",
  }
  local marks = {
    { line = 0, group = "DBClientHeader" },
  }

  if #report.findings == 0 then
    table.insert(lines, ("no drift: %d objects match"):format(report.checked))
    table.insert(marks, { line = #lines - 1, group = "DBClientSeverityOk" })
    return lines, marks
  end

  local GROUPS = {
    changed = { title = "changed on the server", group = "DBClientSeverityWarn" },
    untracked = { title = "missing from the repository", group = "DBClientSeverityError" },
    dropped = { title = "gone from the server", group = "DBClientSeverityHint" },
  }

  for _, status in ipairs({ "changed", "untracked", "dropped" }) do
    local matching = vim.tbl_filter(function(finding)
      return finding.status == status
    end, report.findings)

    if #matching > 0 then
      local heading = GROUPS[status]
      table.insert(lines, ("%s (%d)"):format(heading.title, #matching))
      table.insert(marks, { line = #lines - 1, group = "DBClientHeader" })

      for _, finding in ipairs(matching) do
        table.insert(lines, ("  %-9s %s"):format(finding.kind, finding.name))
        table.insert(marks, { line = #lines - 1, group = heading.group })
      end
      table.insert(lines, "")
    end
  end

  table.insert(lines, ("%d objects checked"):format(report.checked))
  table.insert(marks, { line = #lines - 1, group = "DBClientHelpText" })
  return lines, marks
end

---@param opts { schema?: string, dir?: string }|nil
function M.drift_command(opts)
  opts = opts or {}
  local target = session.current()
  if not target then
    return notify("no active connection", vim.log.levels.WARN)
  end
  local schema = opts.schema or (target.info and target.info.database)
  if not schema then
    return notify("no schema; pass one", vim.log.levels.ERROR)
  end

  client.async(function()
    local report = M.drift({ session_id = target.id, schema = schema, dir = opts.dir })
    local lines, marks = M.render_drift(report, schema)

    local bufnr = buffer.scratch("dbclient://drift/" .. schema, { filetype = "dbclient-drift" })
    buffer.set_lines(bufnr, lines)
    require("dbclient.ui.highlights").lines(bufnr, marks)
    buffer.show(bufnr, "botright split")

    -- `<CR>` on a finding diffs the file against what the server has, which is
    -- the only useful next question.
    local index = {}
    local cursor = 3
    for _, status in ipairs({ "changed", "untracked", "dropped" }) do
      local matching = vim.tbl_filter(function(finding)
        return finding.status == status
      end, report.findings)
      if #matching > 0 then
        cursor = cursor + 1
        for _, finding in ipairs(matching) do
          index[cursor] = finding
          cursor = cursor + 1
        end
        cursor = cursor + 1
      end
    end

    vim.keymap.set("n", "<CR>", function()
      local finding = index[vim.api.nvim_win_get_cursor(0)[1]]
      if finding then
        M.diff_finding(target.id, schema, finding)
      end
    end, { buffer = bufnr, silent = true, desc = "DBClient: diff against the server" })
  end, function(err)
    notify(tostring(err), vim.log.levels.ERROR)
  end)
end

--- Open the repository's copy beside the server's, in diff mode.
---@param session_id string
---@param schema string
---@param finding table
function M.diff_finding(session_id, schema, finding)
  if finding.status == "dropped" then
    vim.cmd("edit " .. vim.fn.fnameescape(finding.path))
    return
  end

  client.async(function()
    local live = M.ddl_for(session_id, schema, { kind = finding.kind, name = finding.name })

    vim.cmd("tabnew")
    if finding.status == "changed" then
      vim.cmd("edit " .. vim.fn.fnameescape(finding.path))
      vim.cmd("diffthis")
      vim.cmd("vsplit")
    end

    local bufnr = buffer.scratch(
      ("dbclient://live/%s/%s"):format(schema, finding.name),
      { filetype = "sql" }
    )
    buffer.set_lines(bufnr, vim.split(live, "\n"))
    vim.api.nvim_win_set_buf(0, bufnr)
    if finding.status == "changed" then
      vim.cmd("diffthis")
    end
  end, function(err)
    notify(tostring(err), vim.log.levels.ERROR)
  end)
end

return M

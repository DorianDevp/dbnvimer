--- Regenerate the documentation that describes mappings.
---
--- `doc/dbclient.txt`, the README's keyboard section and the book's two
--- reference pages are all produced from `dbclient.keymap`, so a new mapping
--- cannot silently go undocumented.
---
---   nvim --headless -u NONE -c "luafile scripts/generate_docs.lua"
---
--- Run with `--check` to fail instead of writing, which is what CI does.

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local keymap = require("dbclient.keymap")

local check_only = vim.tbl_contains(vim.v.argv, "--check")

local START = "<!-- keys:start -->"
local STOP = "<!-- keys:stop -->"
local HELP_START = "*dbclient-keys*"
local HELP_STOP = "=============================================================================="

local function wrap(text, width)
  local lines = {}
  local current = ""
  for word in text:gmatch("%S+") do
    if current == "" then
      current = word
    elseif #current + #word + 1 <= width then
      current = current .. " " .. word
    else
      table.insert(lines, current)
      current = word
    end
  end
  if current ~= "" then
    table.insert(lines, current)
  end
  return lines
end

--- Markdown table of every mapping group.
local function markdown()
  local lines = {}
  for _, group in ipairs(keymap.order) do
    local spec = keymap.groups[group]
    if spec then
      table.insert(lines, "### " .. spec.title)
      table.insert(lines, "")
      if spec.description then
        for _, paragraph in ipairs(vim.split(vim.trim(spec.description), "\n\n")) do
          table.insert(lines, (paragraph:gsub("\n", " ")))
          table.insert(lines, "")
        end
      end
      table.insert(lines, "| key | action |")
      table.insert(lines, "| --- | --- |")
      for _, entry in ipairs(spec.keys) do
        local modes = ""
        if type(entry.mode) == "table" then
          modes = (" _(%s)_"):format(table.concat(entry.mode, ", "))
        elseif type(entry.mode) == "string" and entry.mode ~= "n" then
          modes = (" _(%s)_"):format(entry.mode)
        end
        table.insert(
          lines,
          ("| `%s` | %s%s |"):format(keymap.lhs(group, entry), entry.desc, modes)
        )
      end
      table.insert(lines, "")
    end
  end
  return lines
end

--- Vim help section for the mappings.
local function helptext()
  local lines = { "KEYS                                                    *dbclient-keys*", "" }

  for _, group in ipairs(keymap.order) do
    local spec = keymap.groups[group]
    if spec then
      table.insert(lines, spec.title:upper())
      if spec.description then
        table.insert(lines, "")
        for _, paragraph in ipairs(vim.split(vim.trim(spec.description), "\n\n")) do
          for _, line in ipairs(wrap((paragraph:gsub("\n", " ")), 76)) do
            table.insert(lines, line)
          end
          table.insert(lines, "")
        end
      else
        table.insert(lines, "")
      end

      for _, entry in ipairs(spec.keys) do
        local modes = ""
        if type(entry.mode) == "table" then
          modes = (" [%s]"):format(table.concat(entry.mode, ""))
        elseif type(entry.mode) == "string" and entry.mode ~= "n" then
          modes = (" [%s]"):format(entry.mode)
        end
        table.insert(lines, ("    %-16s %s%s"):format(keymap.lhs(group, entry), entry.desc, modes))
      end
      table.insert(lines, "")
    end
  end

  return lines
end

--- Replace the region between two markers.
local function splice(lines, start_marker, stop_marker, replacement)
  local out = {}
  local index = 1
  local start_index, stop_index

  for position, line in ipairs(lines) do
    if not start_index and line:find(start_marker, 1, true) then
      start_index = position
    elseif start_index and not stop_index and line:find(stop_marker, 1, true) then
      stop_index = position
    end
  end

  if not start_index or not stop_index then
    return nil, ("markers %s / %s not found"):format(start_marker, stop_marker)
  end

  while index <= start_index do
    table.insert(out, lines[index])
    index = index + 1
  end
  vim.list_extend(out, replacement)
  for position = stop_index, #lines do
    table.insert(out, lines[position])
  end
  return out
end

local changed = {}

local function update(path, transform)
  local existing = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
  local updated, err = transform(existing)
  if not updated then
    print(("%s: %s"):format(path, err))
    return false
  end

  if vim.deep_equal(existing, updated) then
    print(("%s is up to date"):format(path))
    return true
  end

  table.insert(changed, path)
  if check_only then
    print(("%s is OUT OF DATE"):format(path))
    return false
  end

  vim.fn.writefile(updated, path)
  print(("%s regenerated"):format(path))
  return true
end

--- The book's key reference: one table per group, on its own page.
local function book_keys()
  local lines = {
    "# Key reference",
    "",
    "Generated from the same table that registers the mappings, so it cannot",
    "disagree with what is actually bound. `g?` in any DBClient buffer shows",
    "that buffer's keys; `:DBClientHelp` shows every group at once.",
    "",
  }

  for _, group in ipairs(keymap.order) do
    local spec = keymap.groups[group]
    if spec then
      table.insert(lines, "## " .. spec.title)
      table.insert(lines, "")
      if spec.description then
        for _, paragraph in ipairs(vim.split(vim.trim(spec.description), "\n\n")) do
          table.insert(lines, (paragraph:gsub("\n", " ")))
          table.insert(lines, "")
        end
      end
      table.insert(lines, "| Key | Effect |")
      table.insert(lines, "|---|---|")
      for _, entry in ipairs(spec.keys or {}) do
        -- A literal pipe would end the table cell.
        local lhs = keymap.lhs(group, entry):gsub("|", "\\|")
        table.insert(lines, ("| `%s` | %s |"):format(lhs, entry.desc))
      end
      table.insert(lines, "")
    end
  end

  return lines
end

--- What each command is for.
---
--- Hand written, because a command's purpose is not derivable from the fact
--- that it exists — but checked against the commands actually registered, so
--- a new one cannot go undocumented and a removed one cannot linger.
local COMMAND_NOTES = {
  DBClient = "open the sidebar",
  DBClientToggle = "toggle the sidebar",
  DBClientClose = "close every connection",
  DBClientConnect = "open a connection, or pick one",
  DBClientDisconnect = "close a connection",
  DBClientConnections = "the connection manager",
  DBClientRestart = "restart the core daemon",
  DBClientSessions = "switch between open sessions",

  DBClientData = "open a table: `:DBClientData shop.customers`",
  DBClientQuery = "run the statement at the cursor",
  DBClientQueryBuffer = "open a query buffer",
  DBClientScratch = "quick query in a new tab",
  DBClientSearch = "search table and column names",
  DBClientHistory = "query history",
  DBClientLog = "this session's statement log",
  DBClientQueries = "saved queries",
  DBClientSaveQuery = "save the current query",
  DBClientNotebook = "turn this markdown buffer into a notebook",
  DBClientPipe = "pipe the result set through a shell command",

  DBClientBegin = "begin a transaction",
  DBClientCommit = "commit",
  DBClientRollback = "roll back",
  DBClientCancel = "cancel the running statement",

  DBClientRecord = "everything related to the row under the cursor",
  DBClientTrail = "pick a point on the navigation trail",
  DBClientBack = "back along the trail",
  DBClientForward = "forward along the trail",
  DBClientJoin = "build a join between two tables",
  DBClientFixture = "extract a row plus everything it needs",
  DBClientDiagram = "entity relationship diagram",

  DBClientExplain = "explain the statement (`!` for ANALYZE)",
  DBClientBlastRadius = "which rows the statement would change",
  DBClientActivity = "who is connected and what they are running",
  DBClientLocks = "the lock tree",
  DBClientStatements = "the workload ranking (`!` saves a snapshot)",
  DBClientWatch = "re-run a statement on a timer",
  DBClientProfile = "time a statement over several runs",
  DBClientHypoIndex = "would this index help",
  DBClientIndexes = "index usage for a schema",

  DBClientAudit = "audit the schema for problems",
  DBClientDDL = "the definition of an object",
  DBClientSchemaDiff = "compare a schema across two connections",
  DBClientSchemaDump = "write the schema out as files (`!` keeps stale ones)",
  DBClientSchemaDrift = "compare the server against the committed schema",
  DBClientReplace = "find and replace across every table",
  DBClientMigrationReview = "what a migration will lock, and for how long",
  DBClientGenerate = "generate code from a table",

  DBClientExport = "export a table or the last result",
  DBClientExportPreset = "export using a named preset",
  DBClientImport = "import a CSV into a table",
  DBClientSnapshot = "save the result set as a snapshot",
  DBClientCompare = "compare with a saved snapshot",
  DBClientCompareConnections = "run one statement on two connections and diff",
  DBClientChart = "chart the current result set",

  DBClientError = "explain the last error in full",
  DBClientErrors = "every error this session (`!` clears)",
  DBClientPalette = "the generated palette and its contrast ratios",
  DBClientHelp = "every mapping group in one buffer",
  DBClientUndoLog = "writes DBClient made, and how to undo them",
  DBClientBroadcast = "run a statement on every open connection",

  DBClientTail = "follow changes as they are committed",
  DBClientTailStop = "stop following",
  DBClientTailCheck = "explain what change streaming needs here",

  DBClientWorkspaceSave = "save the open buffers and connections",
  DBClientWorkspaceRestore = "restore them",
  DBClientWorkspaceShow = "show what is saved",
  DBClientWorkspaceClear = "forget it",
}

--- The book's command reference, checked against what is registered.
local function book_commands()
  -- The commands only exist once `setup()` has run.
  require("dbclient").setup({})

  local registered = {}
  for name in pairs(vim.api.nvim_get_commands({})) do
    if name:match("^DBClient") then
      table.insert(registered, name)
    end
  end
  table.sort(registered)

  local undocumented = {}
  for _, name in ipairs(registered) do
    if not COMMAND_NOTES[name] then
      table.insert(undocumented, name)
    end
  end
  if #undocumented > 0 then
    return nil, "no note for " .. table.concat(undocumented, ", ")
  end

  local known = {}
  for _, name in ipairs(registered) do
    known[name] = true
  end
  local stale = {}
  for name in pairs(COMMAND_NOTES) do
    if not known[name] then
      table.insert(stale, name)
    end
  end
  if #stale > 0 then
    table.sort(stale)
    return nil, "note for a command that no longer exists: " .. table.concat(stale, ", ")
  end

  local lines = {
    "# Commands",
    "",
    ("Every mapping has one, so nothing is reachable only by keystroke — and a "),
    ("few things have only a command. All %d of them:"):format(#registered),
    "",
    "| Command | Does |",
    "|---|---|",
  }
  for _, name in ipairs(registered) do
    table.insert(lines, ("| `:%s` | %s |"):format(name, COMMAND_NOTES[name]))
  end
  table.insert(lines, "")
  return lines
end

local ok = true

ok = update("README.md", function(lines)
  return splice(lines, START, STOP, vim.list_extend({ "" }, markdown()))
end) and ok

ok = update("docs/src/keys.md", function()
  return book_keys()
end) and ok

ok = update("docs/src/commands.md", function()
  return book_commands()
end) and ok

ok = update("doc/dbclient.txt", function(lines)
  local out = {}
  local index = 1
  local start_index
  for position, line in ipairs(lines) do
    if line:find(HELP_START, 1, true) then
      start_index = position
      break
    end
  end
  if not start_index then
    return nil, "*dbclient-keys* section not found"
  end

  -- Find the section separator that closes the keys section.
  local stop_index
  for position = start_index + 1, #lines do
    if lines[position]:find(HELP_STOP, 1, true) then
      stop_index = position
      break
    end
  end
  if not stop_index then
    return nil, "no section separator after *dbclient-keys*"
  end

  while index < start_index do
    table.insert(out, lines[index])
    index = index + 1
  end
  vim.list_extend(out, helptext())
  for position = stop_index, #lines do
    table.insert(out, lines[position])
  end
  return out
end) and ok

if check_only and #changed > 0 then
  print("\nDocumentation is stale. Run: nvim --headless -u NONE -c 'luafile scripts/generate_docs.lua'")
end

vim.cmd(ok and "cquit 0" or "cquit 1")

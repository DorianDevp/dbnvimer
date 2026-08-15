--- One table describing every mapping in the plugin.
---
--- This is the single source of truth for three things that otherwise drift
--- apart: the actual `vim.keymap.set` calls, the `g?` help popup, and the
--- documentation in `doc/dbclient.txt` and the README. Add a key here and all
--- three follow.
---
--- Entries use action names rather than functions so this module stays free of
--- dependencies on the UI modules; each UI module supplies a handler table when
--- it applies a group to a buffer.

local config = require("dbclient.config")

local M = {}

--- Mapping groups, in the order they should appear in generated docs.
---@type table<string, { title: string, description: string, keys: table[] }>
M.groups = {
  global = {
    title = "Global",
    description = "Available everywhere; prefixed with `g:dbclient_leader` (default `<leader>d`).",
    prefixed = true,
    keys = {
      { lhs = "d", action = "toggle_sidebar", desc = "toggle the object sidebar" },
      { lhs = "c", action = "pick_connection", desc = "pick a connection" },
      { lhs = "C", action = "manage_connections", desc = "manage connections" },
      { lhs = "q", action = "open_query", desc = "open the scratch query buffer" },
      { lhs = "Q", action = "execute_buffer", desc = "run the whole query buffer" },
      { lhs = "s", action = "search_objects", desc = "search tables and columns" },
      { lhs = "h", action = "history", desc = "query history" },
      { lhs = "l", action = "statement_log", desc = "statement log for this session" },
      { lhs = "a", action = "activity", desc = "server activity monitor" },
      { lhs = "L", action = "locks", desc = "lock / blocking tree" },
      { lhs = "k", action = "cancel", desc = "cancel the running statement" },
      { lhs = "b", action = "begin", desc = "begin a transaction" },
      { lhs = "m", action = "commit", desc = "commit the transaction" },
      { lhs = "r", action = "rollback", desc = "roll back the transaction" },
      { lhs = "x", action = "disconnect", desc = "close the active connection" },
      { lhs = "w", action = "watch", desc = "watch a statement on a timer" },
      { lhs = "p", action = "profile", desc = "time a statement over several runs" },
      { lhs = "B", action = "broadcast", desc = "run a statement on every connection" },
      { lhs = "n", action = "notebook", desc = "turn this markdown buffer into a notebook" },
      { lhs = "u", action = "undo_log", desc = "writes DBClient made, and how to undo them" },
      { lhs = "e", action = "diagram", desc = "entity relationship diagram for a schema" },
      { lhs = "i", action = "import", desc = "import a CSV into a table" },
      { lhs = "v", action = "compare", desc = "compare result sets or connections" },
      { lhs = "<CR>", action = "scratch", desc = "quick query: type SQL, get rows" },
      { lhs = "f", action = "saved_queries", desc = "saved queries" },
      { lhs = "S", action = "save_query", desc = "save the current query" },
      { lhs = "[", action = "trail_back", desc = "back along the navigation trail" },
      { lhs = "]", action = "trail_forward", desc = "forward along the navigation trail" },
      { lhs = "j", action = "join_builder", desc = "build a join between two tables" },
      { lhs = "A", action = "audit", desc = "audit the schema for problems" },
      { lhs = "g", action = "chart", desc = "chart the current result set" },
      { lhs = "R", action = "blast_radius", desc = "show what the statement would change" },
    },
  },

  sidebar = {
    title = "Sidebar",
    description = "Object tree: connections, schemas, tables, columns and routines.",
    keys = {
      { lhs = "<CR>", action = "open_node", desc = "open or toggle the node" },
      { lhs = "o", action = "open_node", desc = "open or toggle the node" },
      { lhs = "l", action = "expand", desc = "expand the node" },
      { lhs = "h", action = "collapse", desc = "collapse the node or go to its parent" },
      { lhs = "gd", action = "open_data", desc = "open table data" },
      { lhs = "gs", action = "inspect", desc = "inspect the schema or table" },
      { lhs = "gD", action = "open_ddl", desc = "open the DDL buffer" },
      { lhs = "gq", action = "open_query", desc = "open a query buffer" },
      { lhs = "gi", action = "show_indexes", desc = "list indexes" },
      { lhs = "gz", action = "table_sizes", desc = "table and index sizes" },
      { lhs = "ge", action = "diagram", desc = "entity relationship diagram" },
      { lhs = "gj", action = "join_builder", desc = "build a join from this table" },
      { lhs = "gA", action = "audit", desc = "audit this schema" },
      { lhs = "gG", action = "generate", desc = "generate code from this table" },
      { lhs = "gI", action = "import", desc = "import a CSV into this table" },
      { lhs = "gy", action = "yank_name", desc = "yank the qualified object name" },
      { lhs = "a", action = "add_connection", desc = "add a connection" },
      { lhs = "c", action = "edit_connection", desc = "edit the connection" },
      { lhs = "x", action = "delete_connection", desc = "delete the stored connection" },
      { lhs = "t", action = "test_connection", desc = "test the connection" },
      { lhs = "f", action = "filter", desc = "filter the tree" },
      { lhs = "F", action = "clear_filter", desc = "clear the filter" },
      { lhs = "]t", action = "next_table", desc = "jump to the next table" },
      { lhs = "[t", action = "prev_table", desc = "jump to the previous table" },
      { lhs = "r", action = "refresh", desc = "refresh the current node" },
      { lhs = "R", action = "refresh_all", desc = "drop the metadata cache and refresh" },
      { lhs = "q", action = "close", desc = "close the sidebar" },
      { lhs = "g?", action = "help", desc = "show this help" },
    },
  },

  data = {
    title = "Data buffer",
    description = [[
The data buffer is a normal modifiable buffer. Edit cells the way you edit any
text: `ciw`, visual block, `:%s/old/new/g`, macros, `dd` to delete a row, `o` to
add one. `u` undoes staged changes because it is Neovim's own undo. Writing the
buffer with `:w` turns the difference against the fetched snapshot into
`UPDATE`, `INSERT` and `DELETE` statements, shows them for confirmation and
applies them in one transaction.

Only navigation and inspection are mapped, so nothing shadows an editing key.]],
    keys = {
      { lhs = "K", action = "inspect_value", desc = "inspect the full cell value" },
      { lhs = "gd", action = "follow_fk", desc = "follow the foreign key under the cursor" },
      { lhs = "gU", action = "follow_reverse", desc = "open the rows that reference this one" },
      { lhs = "gu", action = "find_references", desc = "list referencing rows in the quickfix" },
      { lhs = "g[", action = "trail_back", desc = "back along the navigation trail" },
      { lhs = "g]", action = "trail_forward", desc = "forward along the navigation trail" },
      { lhs = "gb", action = "trail_pick", desc = "jump to any point on the trail" },
      { lhs = "gs", action = "column_stats", desc = "statistics for this column" },
      { lhs = "gS", action = "sort_column", desc = "sort by this column" },
      { lhs = "gf", action = "filter", desc = "filter rows with a WHERE expression" },
      { lhs = "gF", action = "clear_filter", desc = "clear the filter and sort" },
      { lhs = "gt", action = "transpose", desc = "transposed view of this row" },
      { lhs = "gh", action = "hide_column", desc = "hide this column" },
      { lhs = "gH", action = "show_columns", desc = "show all columns" },
      { lhs = "gn", action = "set_null", desc = "set this cell to SQL NULL", expr = true },
      { lhs = "gy", action = "yank", desc = "yank cell, row or selection as..." },
      { lhs = "gp", action = "paste_row", desc = "duplicate this row as a new INSERT" },
      { lhs = "gr", action = "reload", desc = "reload from the database" },
      { lhs = "gD", action = "open_ddl", desc = "open the DDL for this table" },
      { lhs = "gG", action = "generate", desc = "generate code from this table" },
      { lhs = "gI", action = "import", desc = "import a CSV into this table" },
      { lhs = "]c", action = "next_cell", desc = "next cell" },
      { lhs = "[c", action = "prev_cell", desc = "previous cell" },
      { lhs = "]r", action = "next_row", desc = "next row" },
      { lhs = "[r", action = "prev_row", desc = "previous row" },
      { lhs = "]p", action = "next_page", desc = "next page" },
      { lhs = "[p", action = "prev_page", desc = "previous page" },
      { lhs = "g?", action = "help", desc = "show this help" },
    },
  },

  scratch = {
    title = "Quick query",
    description = [[
A tab holding a SQL buffer above its results. Nothing is named or saved until
you ask: type, run, read, move on. `<CR>` in normal mode runs the statement
under the cursor, so a one-liner is three keystrokes from anywhere.]],
    keys = {
      { lhs = "<CR>", action = "execute", desc = "run the statement under the cursor" },
      { lhs = "<C-CR>", action = "execute", desc = "run it", mode = { "n", "i" } },
      { lhs = "<leader>dQ", action = "execute_buffer", desc = "run every statement" },
      { lhs = "gs", action = "save", desc = "save this query" },
      { lhs = "gf", action = "saved_queries", desc = "open a saved query" },
      { lhs = "gc", action = "pick_connection", desc = "run against another connection" },
      { lhs = "q", action = "close", desc = "close the tab" },
      { lhs = "g?", action = "help", desc = "show this help" },
    },
  },

  queries = {
    title = "Saved queries",
    description = [[
Saved queries are `.sql` files with a `-- @name:` header, kept per project and
globally. They are files, so they grep, diff and commit like anything else.]],
    keys = {
      { lhs = "<CR>", action = "open", desc = "open the query" },
      { lhs = "o", action = "open", desc = "open the query" },
      { lhs = "r", action = "run", desc = "run it without opening it" },
      { lhs = "n", action = "new", desc = "write a new query" },
      { lhs = "e", action = "rename", desc = "rename it" },
      { lhs = "x", action = "delete", desc = "delete it" },
      { lhs = "y", action = "yank", desc = "yank the SQL" },
      { lhs = "p", action = "promote", desc = "move between project and global" },
      { lhs = "gr", action = "refresh", desc = "rescan the query directories" },
      { lhs = "q", action = "close", desc = "close the browser" },
      { lhs = "g?", action = "help", desc = "show this help" },
    },
  },

  query = {
    title = "Query buffer",
    description = [[
A real `sql` buffer, so treesitter, completion and your own mappings apply.
Statements are split by the core, which understands string literals, comments,
dollar quoting and `DELIMITER`.]],
    keys = {
      { lhs = "<C-CR>", action = "execute", desc = "run the statement at the cursor", mode = { "n", "i" } },
      { lhs = "<leader>dq", action = "execute", desc = "run the statement or selection", mode = { "n", "v" } },
      { lhs = "<leader>dQ", action = "execute_buffer", desc = "run every statement in the buffer" },
      { lhs = "<leader>de", action = "explain", desc = "explain the statement" },
      { lhs = "<leader>dE", action = "explain_analyze", desc = "explain analyze the statement" },
      { lhs = "<leader>dR", action = "blast_radius", desc = "show which rows this would change" },
      { lhs = "K", action = "hover", desc = "describe the table or column under the cursor" },
      { lhs = "gd", action = "goto_definition", desc = "open the DDL for the table under the cursor" },
      { lhs = "gs", action = "save", desc = "save this query" },
      { lhs = "gf", action = "saved_queries", desc = "open a saved query" },
      { lhs = "g?", action = "help", desc = "show this help" },
    },
  },

  result = {
    title = "Result buffer",
    description = "Read-only grid. `:w name.csv` exports; the format follows the extension.",
    keys = {
      { lhs = "K", action = "inspect_value", desc = "inspect the full cell value" },
      { lhs = "gs", action = "column_stats", desc = "statistics for this column" },
      { lhs = "gt", action = "transpose", desc = "transposed view of this row" },
      { lhs = "gy", action = "yank", desc = "yank cell, row or selection as..." },
      { lhs = "ge", action = "export", desc = "export the result set" },
      { lhs = "gg", action = "chart", desc = "chart these rows" },
      { lhs = "gS", action = "snapshot", desc = "save this result set as a snapshot" },
      { lhs = "gV", action = "compare", desc = "compare with a saved snapshot" },
      { lhs = "g!", action = "pipe", desc = "pipe the rows through a shell command" },
      { lhs = "]c", action = "next_cell", desc = "next cell" },
      { lhs = "[c", action = "prev_cell", desc = "previous cell" },
      { lhs = "]r", action = "next_row", desc = "next row" },
      { lhs = "[r", action = "prev_row", desc = "previous row" },
      { lhs = "q", action = "close", desc = "close the result buffer" },
      { lhs = "g?", action = "help", desc = "show this help" },
    },
  },

  ddl = {
    title = "DDL buffer",
    description = [[
The object's `CREATE` statement as text. Edit it and `:w` to see the migration
DBClient would run; nothing reaches the server until you confirm.]],
    keys = {
      { lhs = "gr", action = "reload", desc = "reload the DDL from the server" },
      { lhs = "gD", action = "diff", desc = "diff against the server version" },
      { lhs = "q", action = "close", desc = "close the buffer" },
      { lhs = "g?", action = "help", desc = "show this help" },
    },
  },

  explain = {
    title = "Plan buffer",
    description = "Query plan as a foldable tree. The costliest nodes are highlighted.",
    keys = {
      { lhs = "<CR>", action = "toggle_fold", desc = "fold or unfold this node" },
      { lhs = "gj", action = "worst_node", desc = "jump to the most expensive node" },
      { lhs = "gr", action = "rerun", desc = "run the plan again" },
      { lhs = "ga", action = "analyze", desc = "switch to EXPLAIN ANALYZE" },
      { lhs = "q", action = "close", desc = "close the plan" },
      { lhs = "g?", action = "help", desc = "show this help" },
    },
  },

  activity = {
    title = "Activity monitor",
    description = "Live server sessions; refreshes on a timer.",
    keys = {
      { lhs = "x", action = "cancel_query", desc = "cancel the statement under the cursor" },
      { lhs = "X", action = "kill_session", desc = "terminate the session under the cursor" },
      { lhs = "gr", action = "refresh", desc = "refresh now" },
      { lhs = "gt", action = "toggle_auto", desc = "toggle auto refresh" },
      { lhs = "q", action = "close", desc = "close the monitor" },
      { lhs = "g?", action = "help", desc = "show this help" },
    },
  },

  connections = {
    title = "Connection manager",
    description = "Add, edit and test connections without leaving Neovim.",
    keys = {
      { lhs = "<CR>", action = "connect", desc = "connect" },
      { lhs = "a", action = "add", desc = "add a connection" },
      { lhs = "c", action = "edit", desc = "edit the connection" },
      { lhs = "x", action = "delete", desc = "delete the connection" },
      { lhs = "t", action = "test", desc = "test the connection" },
      { lhs = "y", action = "adopt", desc = "copy a detected connection into the store" },
      { lhs = "gr", action = "refresh", desc = "rescan the project" },
      { lhs = "q", action = "close", desc = "close the manager" },
      { lhs = "g?", action = "help", desc = "show this help" },
    },
  },

  textobj = {
    title = "Text objects",
    description = "Available in data and result buffers, in operator-pending and visual mode.",
    documentation_only = true,
    keys = {
      { lhs = "ic", desc = "inner cell" },
      { lhs = "ac", desc = "a cell, including its separator" },
      { lhs = "ir", desc = "inner row" },
      { lhs = "ar", desc = "a row, including the newline" },
      { lhs = "iC", desc = "inner column, every row of it" },
      { lhs = "aC", desc = "a column, including its separator" },
    },
  },
}

--- Order used when generating documentation.
M.order = {
  "global",
  "sidebar",
  "data",
  "scratch",
  "query",
  "queries",
  "result",
  "ddl",
  "explain",
  "activity",
  "connections",
  "textobj",
}

--- The configured global prefix, e.g. `<leader>d`.
---@return string
function M.prefix()
  return vim.g.dbclient_leader or "<leader>d"
end

--- Resolve an entry's left-hand side, expanding the global prefix.
---@param group string
---@param entry table
---@return string
function M.lhs(group, entry)
  if M.groups[group] and M.groups[group].prefixed then
    return M.prefix() .. entry.lhs
  end
  return entry.lhs
end

--- Apply a group's mappings to a buffer.
---@param group string
---@param bufnr integer|nil  nil applies globally
---@param handlers table<string, function>
---@param opts? { silent?: boolean }
function M.apply(group, bufnr, handlers, opts)
  if config.get().keys == false then
    return
  end

  local spec = M.groups[group]
  if not spec or spec.documentation_only then
    return
  end

  opts = opts or {}
  for _, entry in ipairs(spec.keys) do
    local handler = handlers[entry.action]
    if handler then
      local modes = entry.mode or "n"
      vim.keymap.set(modes, M.lhs(group, entry), handler, {
        buffer = bufnr,
        silent = opts.silent ~= false,
        expr = entry.expr,
        desc = "DBClient: " .. entry.desc,
        nowait = bufnr ~= nil and entry.lhs:len() == 1,
      })
    end
  end
end

--- Rendered help lines for a group, used by the `g?` popup.
---@param group string
---@return string[] lines, table[] highlights
function M.help_lines(group)
  local spec = M.groups[group]
  if not spec then
    return { "unknown mapping group: " .. tostring(group) }, {}
  end

  local lines = {}
  local highlights = {}

  local function add(text, hl)
    table.insert(lines, text)
    if hl then
      table.insert(highlights, { line = #lines - 1, group = hl })
    end
  end

  add(spec.title, "DBClientHelpTitle")
  add("")

  if spec.description then
    for _, line in ipairs(vim.split(vim.trim(spec.description), "\n")) do
      add(line, "DBClientHelpText")
    end
    add("")
  end

  local width = 0
  for _, entry in ipairs(spec.keys) do
    width = math.max(width, #M.lhs(group, entry))
  end

  for _, entry in ipairs(spec.keys) do
    local modes = entry.mode
    local suffix = ""
    if type(modes) == "table" then
      suffix = ("  [%s]"):format(table.concat(modes, ""))
    elseif type(modes) == "string" and modes ~= "n" then
      suffix = ("  [%s]"):format(modes)
    end
    add(("  %-" .. width .. "s  %s%s"):format(M.lhs(group, entry), entry.desc, suffix), "DBClientHelpKey")
  end

  if group ~= "global" then
    add("")
    add("Global mappings are listed under `" .. M.prefix() .. "`; see :help dbclient-keys.", "DBClientHelpText")
  end

  return lines, highlights
end

--- Every group as plain text, for `doc/dbclient.txt` and README generation.
---@return string[]
function M.documentation()
  local lines = {}
  for _, group in ipairs(M.order) do
    local spec = M.groups[group]
    if spec then
      table.insert(lines, spec.title)
      table.insert(lines, string.rep("-", #spec.title))
      if spec.description then
        table.insert(lines, "")
        for _, line in ipairs(vim.split(vim.trim(spec.description), "\n")) do
          table.insert(lines, line)
        end
      end
      table.insert(lines, "")
      for _, entry in ipairs(spec.keys) do
        local modes = ""
        if type(entry.mode) == "table" then
          modes = (" [%s]"):format(table.concat(entry.mode, ""))
        elseif type(entry.mode) == "string" and entry.mode ~= "n" then
          modes = (" [%s]"):format(entry.mode)
        end
        table.insert(lines, ("  %-14s %s%s"):format(M.lhs(group, entry), entry.desc, modes))
      end
      table.insert(lines, "")
    end
  end
  return lines
end

--- Sanity check used by the test suite: every action must have a handler.
---@param group string
---@param handlers table
---@return string[] missing
function M.missing_handlers(group, handlers)
  local spec = M.groups[group]
  if not spec or spec.documentation_only then
    return {}
  end
  local missing = {}
  for _, entry in ipairs(spec.keys) do
    if entry.action and not handlers[entry.action] then
      table.insert(missing, entry.action)
    end
  end
  return missing
end

return M

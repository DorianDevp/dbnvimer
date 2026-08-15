--- What a migration will do to a running database.
---
--- The question before every deployment is "will this take production down",
--- and it is normally answered from memory. It has a real answer: the lock a
--- statement takes and how long it holds it are properties of the statement,
--- the table's size and the *server version*, and the last one is what makes
--- remembering hopeless. `ALTER TABLE ... ADD COLUMN ... DEFAULT` rewrites the
--- whole table on MySQL 5.7 and is instant on 8.0. `ADD COLUMN` with a default
--- rewrites on PostgreSQL 10 and does not on 11. Getting that backwards is the
--- difference between a deployment nobody notices and forty seconds of blocked
--- writes.
---
--- So the rules are evaluated against the server actually connected, and every
--- finding says which version it applies to. Row counts come from the same
--- server, because "40 seconds" and "instant" are the same statement on
--- different tables.
---
--- Nothing here executes anything. It reads statements and metadata.

local client = require("dbclient.core.client")
local session = require("dbclient.session")

local M = {}

-- ---------------------------------------------------------------------------
-- Extracting statements
-- ---------------------------------------------------------------------------

--- Pull SQL out of a migration file.
---
--- A `.sql` file is its own answer. Everything else — Doctrine, Alembic,
--- golang-migrate wrappers, Rails — hides the SQL inside a string argument, and
--- the useful ones are conventionally passed to a function whose name says so.
--- Matching on the call rather than on the framework means a project this has
--- never seen still works.
---@param lines string[]
---@param path? string
---@return { sql: string, line: integer }[]
--- Methods whose statements run on the way forward.
---
--- A Doctrine migration's `down()` is a wall of `DROP TABLE`, and reporting
--- those as irreversible blocking operations is how a tool teaches people to
--- ignore it: 148 real migrations produced 71 "destructive" findings, and every
--- one was a rollback that will never run on a deployment.
local FORWARD_METHODS = {
  up = true,
  preup = true,
  postup = true,
  change = true, -- Rails
  upgrade = true, -- Alembic
}

--- Read a PHP string literal starting at `index` (which points at the quote).
---
--- Multi-line literals are the reason this is a scanner rather than a set of
--- per-line patterns: `$this->addSql("` followed by four lines of SQL is
--- ordinary, and matching line by line silently skips it.
---@param text string
---@param index integer
---@return string|nil value, integer next_index
local function read_string(text, index)
  local quote = text:sub(index, index)
  if quote ~= "'" and quote ~= '"' then
    return nil, index
  end

  local out = {}
  local cursor = index + 1
  while cursor <= #text do
    local char = text:sub(cursor, cursor)
    if char == "\\" then
      local escaped = text:sub(cursor + 1, cursor + 1)
      -- Only the escapes that matter for SQL text; anything else stays as
      -- written, because `\d` in a regex literal is not an escape sequence.
      local mapped = ({ ["'"] = "'", ['"'] = '"', ["\\"] = "\\", n = "\n", t = "\t" })[escaped]
      table.insert(out, mapped or ("\\" .. escaped))
      cursor = cursor + 2
    elseif char == quote then
      return table.concat(out), cursor + 1
    else
      table.insert(out, char)
      cursor = cursor + 1
    end
  end
  return nil, index
end

--- Read a heredoc or nowdoc starting at `<<<`.
---@param text string
---@param index integer
---@return string|nil value, integer next_index
local function read_heredoc(text, index)
  local marker, after = text:match("^<<<%s*'?\"?([%a_][%w_]*)'?\"?\r?\n()", index)
  if not marker then
    return nil, index
  end
  local finish, tail = text:find("\n%s*" .. marker, after - 1)
  if not finish then
    return nil, index
  end
  return text:sub(after, finish - 1), tail + 1
end

--- The argument of a call, as a string, following PHP's `.` concatenation.
---@param text string
---@param index integer  first character after the opening parenthesis
---@return string|nil
local function read_argument(text, index)
  local parts = {}
  local cursor = index

  while true do
    cursor = text:find("%S", cursor)
    if not cursor then
      break
    end

    local value, next_index
    if text:sub(cursor, cursor + 2) == "<<<" then
      value, next_index = read_heredoc(text, cursor)
    else
      value, next_index = read_string(text, cursor)
    end

    if not value then
      break
    end
    table.insert(parts, value)
    cursor = next_index

    -- `'select ' . $table . ' where ...'` cannot be resolved, so stop at the
    -- first thing that is not another literal rather than gluing fragments
    -- together into SQL nobody wrote.
    local dot = text:find("^%s*%.%s*", cursor)
    if not dot then
      break
    end
    cursor = select(2, text:find("^%s*%.%s*", cursor)) + 1
  end

  if #parts == 0 then
    return nil
  end
  return table.concat(parts)
end

--- Pull SQL out of a migration file.
---
--- A `.sql` file is its own answer. Everything else — Doctrine, Alembic,
--- golang-migrate wrappers, Rails — hides the SQL inside a string argument, and
--- the useful ones are conventionally passed to a function whose name says so.
--- Matching on the call rather than on the framework means a project this has
--- never seen still works.
---@param lines string[]
---@param path? string
---@param opts? { direction?: "up"|"down"|"both" }
---@return { sql: string, line: integer }[]
function M.extract(lines, path, opts)
  opts = opts or {}
  local direction = opts.direction or "up"
  local text = table.concat(lines, "\n")

  if path and path:lower():match("%.sql$") then
    return M.split_text(text, 1)
  end

  --- Line number of a byte offset.
  local function line_at(offset)
    return 1 + select(2, text:sub(1, offset):gsub("\n", ""))
  end

  -- Where each method begins, so a call can be attributed to one.
  local methods = {}
  for offset, name in text:gmatch("()function%s+([%a_][%w_]*)%s*%(") do
    table.insert(methods, { offset = offset, name = name:lower() })
  end
  local function method_at(offset)
    local current
    for _, method in ipairs(methods) do
      if method.offset > offset then
        break
      end
      current = method.name
    end
    return current
  end

  local statements = {}
  for offset, name in text:gmatch("()([%a_][%w_]*)%s*%(") do
    local lowered = name:lower()
    local interesting = lowered == "addsql"
      or lowered == "execute"
      or lowered == "executestatement"
      or lowered == "executequery"
      or lowered == "exec"

    if interesting then
      local method = method_at(offset)
      local wanted = direction == "both"
        or (direction == "up" and (method == nil or FORWARD_METHODS[method]))
        or (direction == "down" and method ~= nil and not FORWARD_METHODS[method])

      if wanted then
        local open = text:find("%(", offset + #name - 1)
        local sql = open and read_argument(text, open + 1)
        if sql and sql:match("%a") then
          table.insert(statements, { sql = vim.trim(sql), line = line_at(offset) })
        end
      end
    end
  end

  if #statements > 0 then
    table.sort(statements, function(a, b)
      return a.line < b.line
    end)
    return statements
  end

  -- Nothing recognisable: treat the file as SQL and let the splitter decide,
  -- keeping only pieces that classify as statements. Without that filter a PHP
  -- file with no migration in it comes back as one statement made of its own
  -- source.
  for _, candidate in ipairs(M.split_text(text, 1)) do
    if M.classify(candidate.sql).kind ~= "other" then
      table.insert(statements, candidate)
    end
  end
  return statements
end

--- Split raw SQL using the core's own splitter, so dialect quirks — dollar
--- quoting, `DELIMITER`, nested comments — are handled the same way here as
--- when the statement is executed.
---@param text string
---@param first_line integer
---@return { sql: string, line: integer }[]
function M.split_text(text, first_line)
  first_line = first_line or 1
  local ok, result = pcall(client.call, "split-sql", { sql = text })
  local pieces = ok and result and result.statements or nil

  local statements = {}
  if pieces then
    for _, piece in ipairs(pieces) do
      local sql = piece.text or ""
      if sql:match("%a") then
        -- The splitter reports a byte offset, so the line is exact rather than
        -- accumulated — which matters because the report drives the quickfix
        -- list and a drifting line number sends `]q` to the wrong statement.
        local before = text:sub(1, piece.start or 0)
        table.insert(statements, {
          sql = vim.trim(sql),
          line = first_line + select(2, before:gsub("\n", "")),
        })
      end
    end
    return statements
  end

  -- No daemon, or it refused. Splitting on a bare semicolon is wrong for
  -- dollar-quoted bodies and stored routines, but a rough answer beats none.
  local cursor = first_line
  for _, piece in ipairs(vim.split(text, ";\n")) do
    if piece:match("%a") then
      table.insert(statements, { sql = vim.trim(piece), line = cursor })
    end
    cursor = cursor + select(2, piece:gsub("\n", "")) + 1
  end
  return statements
end

-- ---------------------------------------------------------------------------
-- Version comparison
-- ---------------------------------------------------------------------------

--- Parse "8.0.35-MariaDB-1:10.6" style strings into comparable numbers.
---@param text string
---@return integer[] parts, boolean mariadb
function M.parse_version(text)
  text = tostring(text or "")
  local mariadb = text:lower():find("mariadb") ~= nil

  -- MariaDB reports "5.5.5-10.6.16-MariaDB" for protocol reasons; the real
  -- version is the second triple, and reading the first is how tools end up
  -- applying MySQL 5.5 rules to a modern server.
  local candidates = {}
  for major, minor, patch in text:gmatch("(%d+)%.(%d+)%.?(%d*)") do
    table.insert(candidates, { tonumber(major), tonumber(minor), tonumber(patch) or 0 })
  end

  if #candidates == 0 then
    return { 0, 0, 0 }, mariadb
  end
  if mariadb and #candidates > 1 then
    return candidates[2], true
  end
  return candidates[1], mariadb
end

--- True when `version` is at least `major.minor`.
---@param version integer[]
---@param major integer
---@param minor integer
---@return boolean
function M.at_least(version, major, minor)
  if version[1] ~= major then
    return version[1] > major
  end
  return version[2] >= minor
end

-- ---------------------------------------------------------------------------
-- Classifying a statement
-- ---------------------------------------------------------------------------

--- Strip comments and collapse whitespace, so patterns match what was meant.
---@param sql string
---@return string
local function normalise(sql)
  return (
    sql:gsub("/%*.-%*/", " ")
      :gsub("%-%-[^\n]*", " ")
      :gsub("%s+", " ")
      :gsub("^%s+", "")
      :gsub("%s+$", "")
      :lower()
  )
end

--- Unquote an identifier as written in DDL.
---
--- The schema qualifier goes first: stripping quotes from `"shop"."order_item"`
--- and *then* dropping everything before the last dot leaves the inner opening
--- quote behind, which is how a table ends up named `"order_item`.
---@param name string|nil
---@return string|nil
local function unquote(name)
  if not name then
    return nil
  end
  local last = name:match("[^.]+$") or name
  return (last:gsub("^[`\"%[]", ""):gsub("[`\"%]]$", ""))
end

--- What a statement is and what it touches.
---@param sql string
---@return { kind: string, table?: string, actions: string[] }
function M.classify(sql)
  local lower = normalise(sql)
  local result = { kind = "other", actions = {} }

  local altered = lower:match("^alter table%s+([^%s]+)%s")
  if altered then
    result.kind = "alter"
    result.table = unquote(altered)

    -- Parenthesised groups are masked before matching, because a type like
    -- `decimal(20,6)` puts a comma inside what is one clause and every "up to
    -- the next comma" pattern then stops in the wrong place.
    local body = lower:gsub("^alter table%s+[^%s]+%s+", ""):gsub("%b()", "()")
    for _, action in ipairs({
      { "add_column_default", "add%s+column%s+[^%s]+%s+[^,]-%sdefault%s" },
      { "add_column_default", "add%s+[^%s]+%s+[^,]-%sdefault%s" },
      { "add_column_not_null", "add%s+column%s+[^%s]+%s+[^,]-not null" },
      { "add_column_not_null", "add%s+[^%s]+%s+[^,]-not null" },
      { "add_column", "add%s+column%s" },
      { "drop_column", "drop%s+column%s" },
      { "change_type", "modify%s+column%s" },
      { "change_type", "alter%s+column%s+[^%s]+%s+type%s" },
      { "rename_column", "rename%s+column%s" },
      { "rename_column", "change%s+column%s" },
      { "add_foreign_key", "add%s+constraint%s+[^%s]+%s+foreign key" },
      { "add_foreign_key", "add%s+foreign key" },
      { "add_unique", "add%s+unique" },
      { "add_check", "add%s+constraint%s+[^%s]+%s+check" },
      { "add_index", "add%s+index" },
      { "add_index", "add%s+key%s" },
      { "set_not_null", "alter%s+column%s+[^%s]+%s+set not null" },
    }) do
      if body:find(action[2]) then
        table.insert(result.actions, action[1])
      end
    end

    if body:find("algorithm%s*=%s*inplace") or body:find("algorithm%s*=%s*instant") then
      table.insert(result.actions, "explicit_algorithm")
    end
    if body:find("lock%s*=%s*none") then
      table.insert(result.actions, "explicit_lock_none")
    end

    if #result.actions == 0 then
      table.insert(result.actions, "alter_other")
    end
    return result
  end

  local indexed = lower:match("^create%s+.-index%s+.-%son%s+([^%s(]+)")
  if indexed then
    result.kind = "create_index"
    result.table = unquote(indexed)
    if lower:find("concurrently") then
      table.insert(result.actions, "concurrent")
    end
    if lower:find("algorithm%s*=%s*inplace") or lower:find("lock%s*=%s*none") then
      table.insert(result.actions, "explicit_lock_none")
    end
    return result
  end

  local dropped = lower:match("^drop%s+index%s+([^%s;]+)")
  if dropped then
    result.kind = "drop_index"
    if lower:find("concurrently") then
      table.insert(result.actions, "concurrent")
    end
    return result
  end

  -- An ordered list, not a map: `pairs` order is not defined, and the optional
  -- `if exists` / `table` keywords mean the same statement matches two patterns
  -- — so the longer one has to be tried first, deterministically.
  for _, entry in ipairs({
    { "create_table", "^create%s+table%s+if%s+not%s+exists%s+([^%s(;]+)" },
    { "create_table", "^create%s+table%s+([^%s(;]+)" },
    { "drop_table", "^drop%s+table%s+if%s+exists%s+([^%s(;]+)" },
    { "drop_table", "^drop%s+table%s+([^%s(;]+)" },
    { "truncate", "^truncate%s+table%s+([^%s(;]+)" },
    { "truncate", "^truncate%s+([^%s(;]+)" },
    { "delete", "^delete%s+from%s+([^%s(;]+)" },
    { "insert", "^insert%s+into%s+([^%s(;]+)" },
    { "update", "^update%s+([^%s(;]+)" },
  }) do
    local captured = lower:match(entry[2])
    if captured then
      result.kind = entry[1]
      result.table = unquote(captured)
      return result
    end
  end

  return result
end

-- ---------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------

--- Severity, worst first, so a report sorts itself.
local SEVERITY_ORDER = { blocking = 1, caution = 2, note = 3 }

--- Every rule, as a function of the classified statement and the server.
---
--- A rule returns a finding or nothing. Each one states the version boundary it
--- turns on, because "this is fine" and "this locks the table" are the same
--- statement on two servers a year apart.
local RULES = {}

---@param name string
---@param fn fun(at: table, server: table): table|nil
local function rule(name, fn)
  table.insert(RULES, { name = name, check = fn })
end

--- MySQL and MariaDB ----------------------------------------------------------

rule("mysql_add_column_default", function(at, server)
  if server.family ~= "mysql" or at.kind ~= "alter" then
    return nil
  end
  if not vim.tbl_contains(at.actions, "add_column_default") then
    return nil
  end

  local instant = server.mariadb and M.at_least(server.version, 10, 3)
    or (not server.mariadb and M.at_least(server.version, 8, 0))

  if instant then
    return {
      severity = "note",
      summary = "adding a column with a default is instant here",
      detail = ("%s %s applies this without rewriting the table."):format(
        server.mariadb and "MariaDB" or "MySQL",
        server.version_text
      ),
    }
  end

  return {
    severity = "blocking",
    summary = "rewrites the whole table",
    detail = ("%s %s rewrites the table to add a column with a default, holding a "
      .. "metadata lock throughout. MySQL 8.0 and MariaDB 10.3 do this instantly; "
      .. "on this server, add the column without a default and backfill in batches."):format(
      server.mariadb and "MariaDB" or "MySQL",
      server.version_text
    ),
    locks = "writes blocked for the rewrite",
  }
end)

rule("mysql_add_column_not_null", function(at, server)
  if server.family ~= "mysql" or at.kind ~= "alter" then
    return nil
  end
  if not vim.tbl_contains(at.actions, "add_column_not_null") then
    return nil
  end
  if vim.tbl_contains(at.actions, "add_column_default") then
    return nil
  end
  return {
    severity = "caution",
    summary = "NOT NULL with no default",
    detail = "Existing rows have nothing to put here, so this fails outright on a "
      .. "non-empty table unless the server silently substitutes a zero value. Add "
      .. "the column nullable, backfill, then tighten it.",
  }
end)

rule("mysql_change_type", function(at, server)
  if server.family ~= "mysql" or at.kind ~= "alter" then
    return nil
  end
  if not vim.tbl_contains(at.actions, "change_type") then
    return nil
  end
  return {
    severity = "blocking",
    summary = "changing a column type rewrites the table",
    detail = "MySQL and MariaDB copy the table for almost every type change, "
      .. "regardless of version. On a large table use an online schema change tool, "
      .. "or add a new column and migrate across.",
    locks = "writes blocked for the rewrite",
  }
end)

rule("mysql_rename_column", function(at, server)
  if server.family ~= "mysql" or at.kind ~= "alter" then
    return nil
  end
  if not vim.tbl_contains(at.actions, "rename_column") then
    return nil
  end
  return {
    severity = "caution",
    summary = "renaming a column breaks running code",
    detail = "Both the old and the new deployment run at once during a rolling "
      .. "release, so one of them is always wrong. Add the new column, write to "
      .. "both, migrate readers, then drop the old one.",
  }
end)

rule("mysql_create_index", function(at, server)
  if server.family ~= "mysql" or at.kind ~= "create_index" then
    return nil
  end
  if vim.tbl_contains(at.actions, "explicit_lock_none") then
    return {
      severity = "note",
      summary = "index built without blocking writes",
      detail = "`LOCK=NONE` is stated, so the server will refuse rather than block "
        .. "if it cannot manage it. That is the right way round.",
    }
  end
  return {
    severity = "caution",
    summary = "building the index may block writes",
    detail = ("%s builds most indexes in place, but falls back to a copy — and to "
      .. "blocking writes — when it cannot. Say `ALGORITHM=INPLACE, LOCK=NONE` so "
      .. "it fails loudly instead of quietly locking."):format(
      server.mariadb and "MariaDB" or "MySQL"
    ),
  }
end)

--- PostgreSQL -----------------------------------------------------------------

rule("postgres_add_column_default", function(at, server)
  if server.family ~= "postgres" or at.kind ~= "alter" then
    return nil
  end
  if not vim.tbl_contains(at.actions, "add_column_default") then
    return nil
  end

  if M.at_least(server.version, 11, 0) then
    return {
      severity = "note",
      summary = "adding a column with a default is cheap here",
      detail = ("PostgreSQL %s stores the default in the catalogue instead of "
        .. "rewriting the table. The ACCESS EXCLUSIVE lock is still taken, but "
        .. "only for a moment."):format(server.version_text),
    }
  end

  return {
    severity = "blocking",
    summary = "rewrites the whole table",
    detail = ("PostgreSQL %s rewrites the table to add a column with a default, "
      .. "under ACCESS EXCLUSIVE — no reads, no writes, for the duration. "
      .. "Version 11 removed this. Until then: add the column nullable, backfill, "
      .. "then set the default."):format(server.version_text),
    locks = "ACCESS EXCLUSIVE for the rewrite",
  }
end)

rule("postgres_set_not_null", function(at, server)
  if server.family ~= "postgres" or at.kind ~= "alter" then
    return nil
  end
  if
    not vim.tbl_contains(at.actions, "set_not_null")
    and not vim.tbl_contains(at.actions, "add_column_not_null")
  then
    return nil
  end
  if M.at_least(server.version, 12, 0) then
    return {
      severity = "caution",
      summary = "scans the table under ACCESS EXCLUSIVE",
      detail = ("PostgreSQL %s can skip the scan if an equivalent CHECK constraint "
        .. "is already validated. Add `CHECK (col IS NOT NULL) NOT VALID`, validate "
        .. "it, then set NOT NULL — the last step is then instant."):format(
        server.version_text
      ),
      locks = "ACCESS EXCLUSIVE for a full scan",
    }
  end
  return {
    severity = "blocking",
    summary = "scans the table under ACCESS EXCLUSIVE",
    detail = "Every row is checked while reads and writes are blocked.",
    locks = "ACCESS EXCLUSIVE for a full scan",
  }
end)

rule("postgres_create_index", function(at, server)
  if server.family ~= "postgres" or at.kind ~= "create_index" then
    return nil
  end
  if vim.tbl_contains(at.actions, "concurrent") then
    return {
      severity = "note",
      summary = "built concurrently",
      detail = "Writes keep working. Note that CONCURRENTLY cannot run inside a "
        .. "transaction, so this statement has to be outside the migration's, and "
        .. "it can leave an invalid index behind if it fails.",
    }
  end
  return {
    severity = "blocking",
    summary = "blocks writes for the whole build",
    detail = "Use `CREATE INDEX CONCURRENTLY`. It takes longer and cannot run "
      .. "inside a transaction, but it does not stop the application.",
    locks = "SHARE — writes blocked",
  }
end)

rule("postgres_drop_index", function(at, server)
  if server.family ~= "postgres" or at.kind ~= "drop_index" then
    return nil
  end
  if vim.tbl_contains(at.actions, "concurrent") then
    return nil
  end
  return {
    severity = "caution",
    summary = "takes ACCESS EXCLUSIVE on the table",
    detail = "`DROP INDEX CONCURRENTLY` does not.",
    locks = "ACCESS EXCLUSIVE, briefly",
  }
end)

rule("postgres_change_type", function(at, server)
  if server.family ~= "postgres" or at.kind ~= "alter" then
    return nil
  end
  if not vim.tbl_contains(at.actions, "change_type") then
    return nil
  end
  return {
    severity = "blocking",
    summary = "changing a column type rewrites the table",
    detail = "The table and every index on it are rebuilt under ACCESS EXCLUSIVE. "
      .. "Widening within a family — varchar(n) to varchar, int to bigint on 11+ for "
      .. "some cases — can be free; anything else is a rewrite.",
    locks = "ACCESS EXCLUSIVE for the rewrite",
  }
end)

--- Both -----------------------------------------------------------------------

rule("add_foreign_key", function(at, _)
  if at.kind ~= "alter" or not vim.tbl_contains(at.actions, "add_foreign_key") then
    return nil
  end
  return {
    severity = "caution",
    summary = "validates every existing row",
    detail = "Both tables are scanned and both are locked while it happens. On "
      .. "PostgreSQL, split it: `ADD CONSTRAINT ... NOT VALID` takes a brief lock, "
      .. "and `VALIDATE CONSTRAINT` scans without blocking writes.",
    locks = "both tables locked for the scan",
  }
end)

rule("add_unique", function(at, _)
  if at.kind ~= "alter" or not vim.tbl_contains(at.actions, "add_unique") then
    return nil
  end
  return {
    severity = "caution",
    summary = "builds a unique index over the whole table",
    detail = "It also fails if the data is not already unique, which on production "
      .. "data is worth checking first rather than discovering during the deployment.",
  }
end)

rule("drop_column", function(at, _)
  if at.kind ~= "alter" or not vim.tbl_contains(at.actions, "drop_column") then
    return nil
  end
  return {
    severity = "caution",
    summary = "dropping a column breaks running code",
    detail = "During a rolling deployment the old code is still selecting it. Drop "
      .. "the column in the release *after* the one that stopped using it.",
  }
end)

rule("destructive", function(at, _)
  if at.kind ~= "drop_table" and at.kind ~= "truncate" then
    return nil
  end
  return {
    severity = "blocking",
    summary = at.kind == "truncate" and "empties the table" or "drops the table",
    detail = "Irreversible, and nothing in a migration runner will ask twice.",
  }
end)

rule("unbounded_dml", function(at, _)
  if at.kind ~= "update" and at.kind ~= "delete" then
    return nil
  end
  return {
    severity = "caution",
    summary = "rewrites rows in one statement",
    detail = "Every touched row is locked until the migration commits, and the "
      .. "whole thing is one transaction. On a large table, batch it.",
  }
end)

-- ---------------------------------------------------------------------------
-- Analysis
-- ---------------------------------------------------------------------------

--- Describe the server well enough for the rules to reason about it.
---@param info table|nil
---@return { family: string, version: integer[], version_text: string, mariadb: boolean }
function M.server_profile(info)
  info = info or {}
  local adapter = tostring(info.adapter or ""):lower()
  local family = "other"
  if adapter:find("maria") or adapter:find("mysql") then
    family = "mysql"
  elseif adapter:find("postgres") or adapter == "pg" then
    family = "postgres"
  elseif adapter:find("sqlite") then
    family = "sqlite"
  end

  -- Which of the two it is comes from the version string and nothing else. The
  -- adapter is named `mariadb` for both servers, so trusting it would label
  -- every MySQL 8 installation as MariaDB and apply the 10.3 boundary instead
  -- of the 8.0 one — the exact mistake this module exists to prevent.
  local version, mariadb = M.parse_version(info.server_version)
  return {
    family = family,
    version = version,
    version_text = ("%d.%d"):format(version[1], version[2]),
    mariadb = mariadb,
  }
end

--- Analyse a list of statements.
---
--- `row_counts` maps table name to an estimate; a missing entry just means the
--- finding says nothing about duration, which is better than guessing.
---@param opts { statements: table[], server: table, row_counts?: table<string, integer> }
---@return table[] findings
function M.analyse(opts)
  local findings = {}

  -- Tables this migration creates. Everything done to them afterwards is free,
  -- because they are empty — and frameworks emit exactly that shape: a
  -- `CREATE TABLE` followed by an `ALTER TABLE ... ADD CONSTRAINT` for each of
  -- its foreign keys. Reporting those was 102 of the 185 findings on a real
  -- 148-migration project, all of them noise, and a report that is mostly noise
  -- is one nobody reads.
  local fresh = {}

  for index, statement in ipairs(opts.statements) do
    local at = M.classify(statement.sql)

    if at.kind == "create_table" and at.table then
      fresh[at.table] = true
    end

    local empty = at.table
      and (fresh[at.table] or (opts.row_counts and opts.row_counts[at.table] == 0))

    for _, entry in ipairs(empty and {} or RULES) do
      local ok, finding = pcall(entry.check, at, opts.server)
      if ok and finding then
        finding.rule = entry.name
        finding.index = index
        finding.line = statement.line
        finding.sql = statement.sql
        finding.table = at.table
        finding.rows = at.table and opts.row_counts and opts.row_counts[at.table] or nil
        table.insert(findings, finding)
      end
    end
  end

  table.sort(findings, function(a, b)
    local left = SEVERITY_ORDER[a.severity] or 9
    local right = SEVERITY_ORDER[b.severity] or 9
    if left ~= right then
      return left < right
    end
    return a.index < b.index
  end)

  return findings
end

--- Tables a set of statements touches, in the order first seen.
---@param statements table[]
---@return string[]
function M.tables_touched(statements)
  local seen, order = {}, {}
  for _, statement in ipairs(statements) do
    local at = M.classify(statement.sql)
    if at.table and not seen[at.table] then
      seen[at.table] = true
      table.insert(order, at.table)
    end
  end
  return order
end

-- ---------------------------------------------------------------------------
-- Report
-- ---------------------------------------------------------------------------

local ICON = { blocking = "!!", caution = " !", note = "  " }
local GROUP = {
  blocking = "DBClientSeverityError",
  caution = "DBClientSeverityWarn",
  note = "DBClientSeverityHint",
}

--- Wrap `text` to `width`, indented by `indent` spaces.
---@param text string
---@param width integer
---@param indent string
---@return string[]
local function wrap(text, width, indent)
  local lines, current = {}, indent
  for word in text:gmatch("%S+") do
    if #current + #word + 1 > width and current ~= indent then
      table.insert(lines, current)
      current = indent .. word
    else
      current = current == indent and (indent .. word) or (current .. " " .. word)
    end
  end
  if current ~= indent then
    table.insert(lines, current)
  end
  return lines
end

--- Render a report.
---@param opts { findings: table[], statements: table[], server: table, path?: string, width?: integer }
---@return string[] lines, table[] marks
function M.render(opts)
  local width = opts.width or 78
  local server = opts.server
  local lines = {
    ("%s   %d statement%s   %s %s"):format(
      opts.path and vim.fn.fnamemodify(opts.path, ":t") or "migration",
      #opts.statements,
      #opts.statements == 1 and "" or "s",
      server.mariadb and "MariaDB" or (server.family == "postgres" and "PostgreSQL" or "MySQL"),
      server.version_text
    ),
    "",
  }
  local marks = { { line = 0, group = "DBClientHeader" } }

  if #opts.findings == 0 then
    table.insert(lines, "nothing to flag.")
    table.insert(marks, { line = #lines - 1, group = "DBClientSeverityOk" })
    return lines, marks
  end

  local counts = { blocking = 0, caution = 0, note = 0 }
  for _, finding in ipairs(opts.findings) do
    counts[finding.severity] = (counts[finding.severity] or 0) + 1
  end
  table.insert(
    lines,
    ("%d blocking   %d caution   %d note"):format(counts.blocking, counts.caution, counts.note)
  )
  table.insert(marks, { line = #lines - 1, group = "DBClientHelpText" })
  table.insert(lines, "")

  for _, finding in ipairs(opts.findings) do
    local heading = ("%s  %d. %s"):format(ICON[finding.severity], finding.index, finding.summary)
    if finding.table then
      heading = heading .. ("   on %s"):format(finding.table)
      if finding.rows then
        heading = heading .. ("  (%s rows)"):format(
          tostring(finding.rows):reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^%s+", "")
        )
      end
    end
    table.insert(lines, heading)
    table.insert(marks, { line = #lines - 1, group = GROUP[finding.severity] })

    local sql = finding.sql:gsub("%s+", " ")
    if #sql > width - 6 then
      sql = sql:sub(1, width - 7) .. "…"
    end
    table.insert(lines, "      " .. sql)
    table.insert(marks, { line = #lines - 1, group = "DBClientHelpText" })

    if finding.locks then
      table.insert(lines, "      lock: " .. finding.locks)
      table.insert(marks, { line = #lines - 1, group = GROUP[finding.severity] })
    end

    for _, line in ipairs(wrap(finding.detail, width, "      ")) do
      table.insert(lines, line)
    end
    table.insert(lines, "")
  end

  return lines, marks
end

-- ---------------------------------------------------------------------------
-- Command
-- ---------------------------------------------------------------------------

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

--- Analyse a migration file, or the current buffer.
---@param opts { path?: string, bufnr?: integer }|nil
function M.review(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local path = opts.path or vim.api.nvim_buf_get_name(bufnr)

  local lines
  if opts.path and opts.path ~= vim.api.nvim_buf_get_name(bufnr) then
    lines = vim.fn.readfile(opts.path)
  else
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  local statements = M.extract(lines, path)
  if #statements == 0 then
    return notify("no statements found in this file", vim.log.levels.WARN)
  end

  local target = session.current()
  if not target then
    return notify("connect first — the rules depend on the server version", vim.log.levels.WARN)
  end

  client.async(function()
    local server = M.server_profile(target.info)

    -- Row counts turn "rewrites the table" into "rewrites 1.2 million rows",
    -- which is the difference between a note and a decision. Estimates only:
    -- an exact count would itself scan the table.
    local row_counts = {}
    local schema = target.info and target.info.database
    if schema then
      local ok, tables = pcall(session.tables, target.id, schema)
      if ok then
        for _, entry in ipairs(tables or {}) do
          local estimate = tonumber(entry.estimated_rows)
          if estimate and estimate >= 0 then
            row_counts[tostring(entry.name):lower()] = estimate
          end
        end
      end
    end

    local findings = M.analyse({
      statements = statements,
      server = server,
      row_counts = row_counts,
    })

    local report_lines, marks = M.render({
      findings = findings,
      statements = statements,
      server = server,
      path = path,
    })

    local buffer = require("dbclient.ui.buffer")
    local report = buffer.scratch("dbclient://migration-review", {
      filetype = "dbclient-migration",
    })
    buffer.set_lines(report, report_lines)
    require("dbclient.ui.highlights").lines(report, marks)
    buffer.show(report, "botright split")

    if #findings > 0 and path ~= "" then
      -- Also into the quickfix list, so `]q` walks the statements in the file
      -- they came from.
      local items = {}
      for _, finding in ipairs(findings) do
        table.insert(items, {
          filename = path,
          lnum = finding.line or 1,
          text = ("%s: %s"):format(finding.severity, finding.summary),
          type = finding.severity == "blocking" and "E" or "W",
        })
      end
      vim.fn.setqflist({}, " ", { title = "migration review", items = items })
    end
  end, function(err)
    notify(tostring(err), vim.log.levels.ERROR)
  end)
end

M.RULES = RULES

return M

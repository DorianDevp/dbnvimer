--- What happens after something goes wrong.
---
--- The bar to clear is not other database clients — it is the compiler you used
--- an hour ago. A compiler puts the cursor on the token, names what it expected,
--- suggests the identifier you probably meant, and leaves the message where you
--- can go back to it. Database clients hand over the driver's string in a modal
--- dialog and consider the matter closed, which is why `ERROR 1452 (23000):
--- Cannot add or update a child row: a foreign key constraint fails` is a
--- sentence people have learned to skim rather than read.
---
--- Everything here follows from taking that seriously:
---
---   **A position, always, when one can be had.** PostgreSQL reports one.
---   MySQL and SQLite report a fragment instead, and the core recovers the
---   offset from it. Statement three of a script maps back to the line in the
---   file it came from, not to line one of the statement.
---
---   **The server's own words, plus what they mean.** The message is kept, and
---   an explanation is added underneath saying what the database was objecting
---   to and what to do next. Neither replaces the other.
---
---   **The identifier you probably meant.** The client already knows every
---   table and column; `there is no column "statuz"` should not be the end of
---   the conversation.
---
---   **Errors persist.** They land in a buffer, in the diagnostics list and in
---   a history you can walk back through. Nothing important disappears because
---   a notification timed out.

local buffer = require("dbclient.ui.buffer")
local highlights = require("dbclient.ui.highlights")

local M = {
  --- Most recent first.
  ---@type table[]
  history = {},
  limit = 100,
}

M.ns = vim.api.nvim_create_namespace("dbclient-errors")

-- ---------------------------------------------------------------------------
-- Explanations
-- ---------------------------------------------------------------------------

--- What each kind means, and what to do about it.
---
--- Written for someone who knows SQL and does not know this particular
--- database's vocabulary. `%s` placeholders are filled from the structured
--- fields; a missing field falls back to the generic sentence, because a
--- half-substituted explanation is worse than a plain one.
local EXPLANATIONS = {
  syntax = {
    summary = "the server could not parse this",
    body = "Parsing stopped at the marked position, so the mistake is at or just "
      .. "before it — a missing comma, an unclosed quote or bracket, or a keyword "
      .. "the server does not have.",
  },
  undefined_table = {
    summary = "no such table",
    body = "Check the spelling and the schema. `<leader>ds` searches every table "
      .. "and column on this connection.",
  },
  undefined_column = {
    summary = "no such column",
    body = "Check the spelling, and check that the table you meant is actually in "
      .. "the FROM clause — a column that exists on a different table reads the "
      .. "same way to the server as one that exists nowhere.",
  },
  undefined_function = {
    summary = "no such function",
    body = "Either the name is wrong or the argument types are: most servers "
      .. "resolve functions by signature, so the right name with the wrong "
      .. "argument type reports as missing.",
  },
  undefined_database = {
    summary = "no such database",
    body = "The connection names a database the server does not have.",
  },
  duplicate_object = {
    summary = "that already exists",
    body = "Use `IF NOT EXISTS`, or drop the existing one first.",
  },
  not_null = {
    summary = "a required value is missing",
    body = "The column is declared NOT NULL, so the row has to carry a value. "
      .. "Either supply one or give the column a default.",
  },
  foreign_key = {
    summary = "the relationship does not hold",
    body = "The value has to exist on the other side of the key before this row "
      .. "can point at it. Insert the referenced row first, or correct the value.",
  },
  unique = {
    summary = "that value is already used",
    body = "A unique constraint or index covers this column, and another row "
      .. "already holds the value. `<CR>` opens that row.",
  },
  check = {
    summary = "a check constraint rejected the value",
    body = "The constraint's expression is part of the table definition; "
      .. "`<leader>gD` on the table shows it.",
  },
  data_type = {
    summary = "the value does not fit the column's type",
    body = "The server would not convert what was given into what the column "
      .. "holds. Dates and numbers written as text are the usual cause.",
  },
  string_too_long = {
    summary = "the value is longer than the column allows",
    body = "Either shorten the value or widen the column. Widening a varchar is "
      .. "cheap on modern servers and a full table rewrite on old ones — "
      .. "`<leader>dM` on the migration says which.",
  },
  numeric_range = {
    summary = "the number is outside the column's range",
    body = "An `int` stops at about 2.1 billion; `bigint` is the usual answer.",
  },
  division_by_zero = {
    summary = "divided by zero",
    body = "`nullif(divisor, 0)` turns the error into a NULL, which is usually "
      .. "what was wanted.",
  },
  collation = {
    summary = "two columns in this comparison use different collations",
    body = "The server will not compare them without being told which to use. "
      .. "Add `COLLATE` to the comparison, or make the two columns agree — the "
      .. "schema audit lists tables whose collations differ.",
  },
  column_count = {
    summary = "the number of values does not match the number of columns",
    body = "Name the columns explicitly in the INSERT; positional inserts break "
      .. "quietly every time the table gains one.",
  },
  no_default = {
    summary = "the column has no default and was not given a value",
    body = "Supply a value, or give the column a default in the schema.",
  },
  permission = {
    summary = "this user is not allowed to do that",
    body = "The connection succeeded, so the credentials are right and the grants "
      .. "are not. `:DBClientConnections` shows which user this connection uses.",
  },
  authentication = {
    summary = "the server rejected these credentials",
    body = "The user, the password or the host the user is allowed to connect "
      .. "from. MySQL grants are per host, so the same user can be accepted "
      .. "locally and refused over TCP.",
  },
  deadlock = {
    summary = "two transactions blocked each other and the server broke the tie",
    body = "This one was chosen as the victim and rolled back. Retrying usually "
      .. "works. `<leader>dL` shows what is currently blocking what.",
  },
  lock_timeout = {
    summary = "gave up waiting for a lock",
    body = "Something else is holding the rows. `<leader>dL` shows who — an "
      .. "uncommitted transaction in another session is the usual answer.",
  },
  statement_timeout = {
    summary = "the statement ran longer than the timeout allows",
    body = "Nothing was changed. `<leader>de` explains the plan; the timeout "
      .. "itself is `core.statement_timeout_ms`.",
  },
  cancelled = {
    summary = "cancelled",
    body = "Nothing was changed by the part that had not finished.",
  },
  transaction_aborted = {
    summary = "the transaction is already broken",
    body = "PostgreSQL refuses every statement after an error until the "
      .. "transaction ends. `<leader>dr` rolls back so you can carry on.",
  },
  read_only = {
    summary = "the server is refusing writes",
    body = "A replica, or a session started read-only. This is the server's "
      .. "refusal, not DBClient's.",
  },
  access_refused = {
    summary = "DBClient refused this, the server never saw it",
    body = "The connection is configured `access = \"read\"`. `:DBClientConnections` "
      .. "changes it; `sandbox` runs writes and always rolls them back.",
  },
  connection_lost = {
    summary = "the connection is gone",
    body = "`:DBClientConnect` reopens it. If it keeps happening, the server's "
      .. "idle timeout or something between you and it is closing the socket.",
  },
  too_many_connections = {
    summary = "the server has no connection slots left",
    body = "`<leader>da` shows what is currently connected.",
  },
  unknown = {
    summary = "the server rejected this",
    body = nil,
  },
}

--- A one-line summary for a kind.
---@param kind string|nil
---@return string
function M.summary(kind)
  local entry = EXPLANATIONS[kind or "unknown"] or EXPLANATIONS.unknown
  return entry.summary
end

-- ---------------------------------------------------------------------------
-- Normalising
-- ---------------------------------------------------------------------------

--- Turn a raw error into the shape everything else here expects.
---
--- Accepts what the core sends, what an older core sends (a bare string), and
--- what DBClient raises itself, so no caller has to know which it has.
---@param message string
---@param detail table|nil
---@return table
function M.normalise(message, detail)
  detail = type(detail) == "table" and detail or {}
  local kind = detail.kind or "unknown"

  return {
    kind = kind,
    message = detail.message or tostring(message),
    -- The chain around the message says what was being attempted, which the
    -- driver never knows and the user always wants.
    context = detail.context,
    sqlstate = detail.sqlstate,
    code = detail.code,
    position = detail.position,
    near = detail.near,
    line = detail.line,
    detail = detail.detail,
    hint = detail.hint,
    constraint = detail.constraint,
    schema = detail.schema,
    table = detail.table,
    column = detail.column,
    datatype = detail.datatype,
    referenced_table = detail.referenced_table,
    referenced_column = detail.referenced_column,
    value = detail.value,
    row = detail.row,
    statement_index = detail.statement_index,
    statement_offset = detail.statement_offset,
    statement = detail.statement,
    statement_fault = detail.statement_fault,
    transient = detail.transient,
    adapter = detail.adapter,
    at = os.time(),
  }
end

-- ---------------------------------------------------------------------------
-- Locating
-- ---------------------------------------------------------------------------

--- Where the error is, in the buffer the user is looking at.
---
--- Three coordinate systems meet here and getting any of them wrong puts the
--- caret somewhere plausible and false, which is worse than no caret at all:
---
---   * `statement_offset` is a **byte** offset of the statement within the text
---     that was sent, from the SQL splitter;
---   * `position` is a 1-based **character** offset within that statement, from
---     the server;
---   * Neovim wants a 0-based line and a 0-based **byte** column.
---
---@param err table  a normalised error
---@param source string  the text that was sent to the server
---@param first_line integer  1-based buffer line the source begins on
---@return { line: integer, col: integer, end_col: integer }|nil
function M.locate(err, source, first_line)
  if not err.position or not source then
    return nil
  end
  first_line = first_line or 1

  local statement_offset = err.statement_offset or 0
  local statement = err.statement or source:sub(statement_offset + 1)

  -- Character offset within the statement to a byte offset within it.
  local byte_in_statement = 0
  local characters = vim.fn.strchars(statement)
  local wanted = math.min(err.position - 1, characters)
  if wanted > 0 then
    byte_in_statement = #vim.fn.strcharpart(statement, 0, wanted)
  end

  local absolute = statement_offset + byte_in_statement
  local prefix = source:sub(1, absolute)

  local newlines = select(2, prefix:gsub("\n", ""))
  local line_start = (prefix:find("\n[^\n]*$")) or 0
  local column = #prefix - line_start

  -- How much to underline: the token, and only the token. MySQL's `near`
  -- quotes everything from the error to the end of the statement, so trusting
  -- its length underlines half the query and says nothing about where to look.
  local remainder = source:sub(absolute + 1)
  local token = M.token(err.near)
  local length
  if token and remainder:sub(1, #token) == token then
    length = #token
  else
    length = #(remainder:match("^[%w_]+") or "")
  end
  -- A quoted fragment can run past the end of the line; the mark must not.
  local to_newline = remainder:find("\n")
  if to_newline then
    length = math.min(length, to_newline - 1)
  end

  return {
    line = first_line + newlines - 1,
    col = column,
    end_col = column + math.max(length, 1),
  }
end

-- ---------------------------------------------------------------------------
-- Did you mean
-- ---------------------------------------------------------------------------

--- The first token of a quoted fragment.
---
--- Servers differ in how much they quote: PostgreSQL names one identifier,
--- MySQL echoes the rest of the statement. What is wanted in both cases is the
--- thing the parser choked on, which is the first token either way.
---@param near string|nil
---@return string|nil
function M.token(near)
  if not near or near == "" then
    return nil
  end
  local first = near:match("^[%w_$.]+")
  if first and first ~= "" then
    return first
  end
  -- A fragment starting with punctuation: mark the single character, since the
  -- run of symbols after it is rarely one token.
  return near:sub(1, 1)
end

--- Edit distance, counting a transposition as one edit.
---
--- Plain Levenshtein charges two for swapping a pair of adjacent letters, which
--- is the single most common way to mistype an identifier: `nmae` is two edits
--- from `name` and so falls outside any threshold tight enough to be useful on
--- a four-letter word. Damerau's variant charges one, which is what a person
--- would say the difference is.
---
--- Capped, so a hopeless pair costs nothing to reject — a schema with four
--- hundred columns is compared against every one of them.
---@param a string
---@param b string
---@param cap integer
---@return integer
function M.distance(a, b, cap)
  a, b = a:lower(), b:lower()
  if a == b then
    return 0
  end
  if math.abs(#a - #b) > cap then
    return cap + 1
  end

  -- Two previous rows: the transposition case reaches back two of each.
  local before_previous
  local previous = {}
  for index = 0, #b do
    previous[index] = index
  end

  for i = 1, #a do
    local current = { [0] = i }
    local best = i
    for j = 1, #b do
      local cost = (a:sub(i, i) == b:sub(j, j)) and 0 or 1
      local value = math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)

      if
        i > 1
        and j > 1
        and a:sub(i, i) == b:sub(j - 1, j - 1)
        and a:sub(i - 1, i - 1) == b:sub(j, j)
      then
        value = math.min(value, before_previous[j - 2] + 1)
      end

      current[j] = value
      best = math.min(best, value)
    end
    if best > cap then
      return cap + 1
    end
    before_previous, previous = previous, current
  end

  return previous[#b]
end

--- The closest candidates to `name`.
---
--- The threshold scales with length: one wrong letter in a three-letter name is
--- a different word, one wrong letter in `created_at` is a typo.
---@param name string
---@param candidates string[]
---@param limit? integer
---@return string[]
function M.suggest(name, candidates, limit)
  local cap = math.max(1, math.min(4, math.floor(#name / 3)))
  local scored = {}

  for _, candidate in ipairs(candidates) do
    if candidate ~= name then
      local distance = M.distance(name, candidate, cap)
      if distance <= cap then
        table.insert(scored, { name = candidate, distance = distance })
      elseif #name >= 4 and candidate:lower():find(name:lower(), 1, true) then
        -- A prefix or infix match is a good suggestion even when the edit
        -- distance is large: `user` against `user_account`.
        table.insert(scored, { name = candidate, distance = cap })
      end
    end
  end

  table.sort(scored, function(a, b)
    if a.distance ~= b.distance then
      return a.distance < b.distance
    end
    return a.name < b.name
  end)

  local names = {}
  for index, entry in ipairs(scored) do
    if index > (limit or 3) then
      break
    end
    table.insert(names, entry.name)
  end
  return names
end

--- Names worth suggesting for this error, from what the session already knows.
---
--- Metadata only, from the cache: an error handler that goes back to the server
--- turns a fast failure into a slow one.
---@param err table
---@param session_id string|nil
---@return string[]
function M.candidates(err, session_id)
  if not session_id then
    return {}
  end

  local ok, session = pcall(require, "dbclient.session")
  if not ok then
    return {}
  end
  local target = session.get and session.get(session_id)
  if not target then
    return {}
  end

  local cache = target.cache or {}
  local schema = err.schema or (target.info and target.info.database)
  local names = {}

  if err.kind == "undefined_table" then
    for _, entry in pairs(cache.tables or {}) do
      for _, item in ipairs(entry or {}) do
        table.insert(names, item.name)
      end
    end
  elseif err.kind == "undefined_column" then
    for key, entry in pairs(cache.columns or {}) do
      -- Prefer the table the error named; fall back to every cached column,
      -- because a column error rarely says which table it looked in.
      if not err.table or key:find(err.table, 1, true) then
        for _, item in ipairs(entry or {}) do
          table.insert(names, item.name)
        end
      end
    end
  end

  local _ = schema
  local seen, unique = {}, {}
  for _, name in ipairs(names) do
    if name and not seen[name] then
      seen[name] = true
      table.insert(unique, name)
    end
  end
  return unique
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- The line the error sits on, with a caret under it.
---
--- psql has done this for twenty years and no graphical client has copied it,
--- which is strange, because it is the single most useful thing in the output.
---@param err table
---@param source string|nil
---@return string[] lines, integer|nil caret_index
function M.caret(err, source)
  if not err.position then
    return {}, nil
  end
  local statement = err.statement or source
  if not statement or statement == "" then
    return {}, nil
  end

  -- Which line of the statement, and where in it.
  local characters = vim.fn.strchars(statement)
  local wanted = math.min(err.position - 1, characters)
  local prefix = vim.fn.strcharpart(statement, 0, wanted)

  local line_number = 1 + select(2, prefix:gsub("\n", ""))
  local line_prefix = prefix:match("[^\n]*$") or ""
  local lines = vim.split(statement, "\n", { plain = true })
  local text = lines[line_number]
  if not text then
    return {}, nil
  end

  -- Display cells, not bytes: the caret has to land under the character even
  -- when the line holds `Łódź` or a tab.
  local column = vim.fn.strdisplaywidth(line_prefix:gsub("\t", "        "))
  local shown = text:gsub("\t", "        ")

  local label = ("%d"):format(line_number)
  local gutter = ("  %s │ "):format(label)
  -- Display width, not byte length: the rule glyph is three bytes and one cell,
  -- and padding the caret line by bytes would push it two cells right.
  local pointer = (" "):rep(vim.fn.strdisplaywidth(gutter)) .. (" "):rep(column) .. "^"

  -- How wide to underline. PostgreSQL reports a position and never a
  -- fragment, so the token is taken from the statement itself; a bare `^` with
  -- nothing under it is noticeably harder to read on a long line.
  local token = M.token(err.near)
  if not token then
    local remainder = text:sub(#line_prefix + 1)
    token = remainder:match("^[%w_$.]+")
  end
  local width = token and math.max(1, vim.fn.strdisplaywidth(token)) or 1
  if width > 1 then
    pointer = pointer .. ("~"):rep(width - 1)
  end

  return { gutter .. shown, pointer }, 2
end

--- Everything worth saying about one error.
---@param err table
---@param opts? { session_id?: string, source?: string, width?: integer }
---@return string[] lines, table[] marks
function M.render(err, opts)
  opts = opts or {}
  local width = opts.width or 76
  local lines, marks = {}, {}

  local function add(text, group)
    table.insert(lines, text)
    if group then
      table.insert(marks, { line = #lines - 1, group = group })
    end
  end

  local function wrap(text, indent, group)
    local current = indent
    for word in text:gmatch("%S+") do
      if #current + #word + 1 > width and current ~= indent then
        add(current, group)
        current = indent .. word
      else
        current = current == indent and (indent .. word) or (current .. " " .. word)
      end
    end
    if current ~= indent then
      add(current, group)
    end
  end

  -- Headline: the server's own words, and where.
  local where = ""
  if err.statement_index then
    where = (" · statement %d"):format(err.statement_index)
  end
  add(("%s%s"):format(err.message, where), "DBClientSeverityError")

  local badge = {}
  if err.code then
    table.insert(badge, err.code)
  end
  if err.sqlstate and err.sqlstate ~= err.code then
    table.insert(badge, "SQLSTATE " .. err.sqlstate)
  end
  if err.adapter and err.adapter ~= "" then
    table.insert(badge, err.adapter)
  end
  if #badge > 0 then
    add("  " .. table.concat(badge, "   "), "DBClientHelpText")
  end

  -- The offending line with a caret under it.
  local caret_lines = M.caret(err, opts.source)
  if #caret_lines > 0 then
    add("")
    for index, text in ipairs(caret_lines) do
      add(text, index == 2 and "DBClientSeverityError" or nil)
    end
  end

  -- What it means.
  local explanation = EXPLANATIONS[err.kind] or EXPLANATIONS.unknown
  add("")
  add(explanation.summary, "DBClientHeader")
  if explanation.body then
    wrap(explanation.body, "", "DBClientHelpText")
  end

  -- The specifics the server handed over, which are the part nobody surfaces.
  local facts = {}
  local function fact(label, value)
    if value ~= nil and value ~= "" then
      table.insert(facts, { label, tostring(value) })
    end
  end
  fact("table", err.schema and err.table and (err.schema .. "." .. err.table) or err.table)
  fact("column", err.column)
  fact("constraint", err.constraint)
  fact("references", err.referenced_table
      and err.referenced_column
      and (err.referenced_table .. "." .. err.referenced_column)
    or err.referenced_table)
  fact("value", err.value)
  fact("row", err.row)
  fact("type", err.datatype)

  if #facts > 0 then
    add("")
    local label_width = 0
    for _, entry in ipairs(facts) do
      label_width = math.max(label_width, #entry[1])
    end
    for _, entry in ipairs(facts) do
      add(("  %-" .. label_width .. "s  %s"):format(entry[1], entry[2]), "DBClientHelpText")
      marks[#marks].end_col = 2 + label_width
      marks[#marks].group = "DBClientHelpText"
    end
  end

  -- Did you mean.
  local wrong = err.column or err.table or err.near
  if wrong and (err.kind == "undefined_column" or err.kind == "undefined_table") then
    local suggestions = M.suggest(wrong, M.candidates(err, opts.session_id))
    if #suggestions > 0 then
      add("")
      add(("did you mean %s?"):format(table.concat(
        vim.tbl_map(function(name)
          return "`" .. name .. "`"
        end, suggestions),
        " or "
      )), "DBClientSeverityWarn")
    end
  end

  -- What the server itself added. PostgreSQL's DETAIL and HINT are often the
  -- most useful lines in the whole response and are routinely discarded.
  if err.detail then
    add("")
    wrap(err.detail, "", "DBClientHelpText")
  end
  if err.hint then
    add("")
    wrap("hint: " .. err.hint, "", "DBClientSeverityHint")
  end

  if err.transient then
    add("")
    add("this one is worth simply retrying", "DBClientSeverityHint")
  end

  -- Looked up through `M` rather than the local, which is declared below this
  -- function and so is not in its closure.
  local remedy = M.remedy(err)
  if remedy then
    add("")
    add(("  %s  %s"):format(remedy.key, remedy.label), "DBClientHelpKey")
    marks[#marks].end_col = 3
    table.insert(marks, {
      line = #lines - 1,
      col = 3,
      end_col = 3 + #remedy.label + 2,
      group = "DBClientHelpText",
    })
  end

  if err.context and err.context ~= err.message then
    add("")
    wrap("while: " .. err.context, "", "DBClientHelpText")
  end

  return lines, marks
end

-- ---------------------------------------------------------------------------
-- History
-- ---------------------------------------------------------------------------

--- Remember an error so it can be looked at again.
---@param message string
---@param detail table|nil
---@return table
function M.record(message, detail)
  local err = M.normalise(message, detail)
  table.insert(M.history, 1, err)
  while #M.history > M.limit do
    table.remove(M.history)
  end
  return err
end

function M.clear()
  M.history = {}
end

--- The most recent error, if any.
---@return table|nil
function M.last()
  return M.history[1]
end

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------

--- Put the error on the line it belongs to, as a real diagnostic.
---
--- Real, meaning `]d` steps to it, the sign column shows it, virtual text
--- explains it and whatever the user has configured for diagnostics applies.
--- The alternative — a notification — is gone in four seconds and cannot be
--- navigated to.
---@param bufnr integer
---@param err table
---@param opts { source: string, first_line?: integer }
---@return boolean placed
function M.diagnose(bufnr, err, opts)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local at = M.locate(err, opts.source, opts.first_line)
  if not at then
    -- No position: put it on the first line of the statement rather than
    -- nowhere, so the buffer still shows that something failed.
    at = { line = (opts.first_line or 1) - 1, col = 0, end_col = 1 }
  end

  local count = vim.api.nvim_buf_line_count(bufnr)
  at.line = math.max(0, math.min(at.line, count - 1))
  local text = vim.api.nvim_buf_get_lines(bufnr, at.line, at.line + 1, false)[1] or ""
  at.col = math.max(0, math.min(at.col, #text))
  at.end_col = math.max(at.col + 1, math.min(at.end_col, #text))

  local message = err.message
  local suggestion
  local wrong = err.column or err.table or err.near
  if wrong and (err.kind == "undefined_column" or err.kind == "undefined_table") then
    local names = M.suggest(wrong, M.candidates(err, opts.session_id), 2)
    if #names > 0 then
      suggestion = ("did you mean %s?"):format(table.concat(names, " or "))
      message = message .. " — " .. suggestion
    end
  end

  vim.diagnostic.set(M.ns, bufnr, {
    {
      lnum = at.line,
      col = at.col,
      end_lnum = at.line,
      end_col = at.end_col,
      severity = vim.diagnostic.severity.ERROR,
      source = "dbclient",
      code = err.code,
      message = message,
    },
  })
  return true
end

--- Remove any error diagnostics from a buffer.
---@param bufnr integer
function M.clear_diagnostics(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.diagnostic.reset(M.ns, bufnr)
  end
end

-- ---------------------------------------------------------------------------
-- What to do next
-- ---------------------------------------------------------------------------

--- Actions the panel offers for kinds that have an obvious next move.
---
--- Reporting "the transaction is aborted" and leaving the user to remember the
--- incantation is the difference between a diagnosis and a fix. These are the
--- three cases where the answer is unambiguous enough to offer a key for.
local REMEDIES = {
  transaction_aborted = {
    key = "r",
    label = "roll back and carry on",
    run = function(err)
      local session = require("dbclient.session")
      local target = err.session_id and session.get(err.session_id) or session.current()
      if not target then
        return
      end
      require("dbclient.core.client").async(function()
        session.rollback(target.id)
        require("dbclient.ui.winbar").refresh()
        vim.notify("DBClient: rolled back", vim.log.levels.INFO)
      end, function(inner)
        vim.notify("DBClient: " .. tostring(inner), vim.log.levels.ERROR)
      end)
    end,
  },
  lock_timeout = {
    key = "L",
    label = "show what is holding the lock",
    run = function(err)
      require("dbclient.ui.activity").open({ mode = "locks", session_id = err.session_id })
    end,
  },
  deadlock = {
    key = "L",
    label = "show what is currently blocking what",
    run = function(err)
      require("dbclient.ui.activity").open({ mode = "locks", session_id = err.session_id })
    end,
  },
  too_many_connections = {
    key = "L",
    label = "show what is connected",
    run = function(err)
      require("dbclient.ui.activity").open({ mode = "activity", session_id = err.session_id })
    end,
  },
}

--- The offered action for an error, if there is one.
---@param err table
---@return table|nil
function M.remedy(err)
  return REMEDIES[err.kind]
end

-- ---------------------------------------------------------------------------
-- The panel
-- ---------------------------------------------------------------------------

M.winid = nil
M.bufnr = nil

--- Show one error in full.
---
--- Opens without taking focus: the cursor stays where the mistake is, which is
--- where the next keystroke wants to be. `<leader>d!` focuses it, `q` closes.
---@param err table
---@param opts? { session_id?: string, source?: string, focus?: boolean }
function M.show(err, opts)
  opts = opts or {}
  local lines, marks = M.render(err, opts)

  local bufnr = buffer.scratch("dbclient://error", { filetype = "dbclient-error" })
  M.bufnr = bufnr
  buffer.set_lines(bufnr, lines)
  highlights.lines(bufnr, marks, M.ns)

  local previous = vim.api.nvim_get_current_win()
  local existing = buffer.windows(bufnr)
  if #existing > 0 then
    M.winid = existing[1]
  else
    vim.cmd(("botright %dsplit"):format(math.min(#lines + 1, 16)))
    M.winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M.winid, bufnr)
    vim.wo[M.winid].winfixheight = true
    vim.wo[M.winid].number = false
    vim.wo[M.winid].relativenumber = false
    vim.wo[M.winid].signcolumn = "no"
  end

  local function close()
    if M.winid and vim.api.nvim_win_is_valid(M.winid) then
      pcall(vim.api.nvim_win_close, M.winid, true)
    end
  end
  vim.keymap.set("n", "q", close, {
    buffer = bufnr,
    silent = true,
    nowait = true,
    desc = "DBClient: close the error",
  })

  local remedy = M.remedy(err)
  if remedy then
    vim.keymap.set("n", remedy.key, function()
      close()
      remedy.run(err)
    end, {
      buffer = bufnr,
      silent = true,
      nowait = true,
      desc = "DBClient: " .. remedy.label,
    })
  end

  if not opts.focus and vim.api.nvim_win_is_valid(previous) then
    vim.api.nvim_set_current_win(previous)
  end
end

--- Show the most recent error, focused.
function M.show_last()
  local err = M.last()
  if not err then
    return vim.notify("DBClient: no errors this session", vim.log.levels.INFO)
  end
  M.show(err, { focus = true, session_id = err.session_id, source = err.statement })
end

--- Every error this session, newest first.
function M.browse()
  if #M.history == 0 then
    return vim.notify("DBClient: no errors this session", vim.log.levels.INFO)
  end

  local items = {}
  for index, err in ipairs(M.history) do
    table.insert(items, {
      index = index,
      label = ("%s  %-22s %s"):format(
        os.date("%H:%M:%S", err.at),
        M.summary(err.kind),
        (err.message:gsub("%s+", " ")):sub(1, 60)
      ),
    })
  end

  vim.ui.select(items, {
    prompt = "errors",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      M.show(M.history[choice.index], { focus = true })
    end
  end)
end

-- ---------------------------------------------------------------------------
-- The one entry point callers use
-- ---------------------------------------------------------------------------

--- Handle a failure: record it, place it, say it once.
---
--- Every `on_error` handler in the plugin funnels through here, so the
--- treatment is the same wherever the failure came from.
---@param message string
---@param detail table|nil
---@param opts? { bufnr?: integer, source?: string, first_line?: integer, session_id?: string, silent?: boolean, panel?: boolean }
---@return table err
function M.handle(message, detail, opts)
  opts = opts or {}
  local err = M.history[1]
  -- `client.async` already recorded it when the core supplied structure; only
  -- record again when this came from somewhere else, so the history does not
  -- double up.
  if not err or err.message ~= (detail and detail.message or message) then
    err = M.record(message, detail)
  end
  err.session_id = opts.session_id or err.session_id
  -- The core only knows the statement it was handed; where that statement sat
  -- in the user's buffer is something only the caller can say.
  err.statement_offset = err.statement_offset or opts.statement_offset

  if opts.bufnr and opts.source then
    M.diagnose(opts.bufnr, err, {
      source = opts.source,
      first_line = opts.first_line,
      session_id = err.session_id,
    })
  end

  if not opts.silent then
    -- One line, and where to get the rest. A wall of text in the message area
    -- is what every client does and what nobody reads; the detail lives in a
    -- buffer that is still there in five minutes.
    local headline = err.message:gsub("%s+", " ")
    if #headline > 100 then
      headline = headline:sub(1, 97) .. "…"
    end
    if M.has_more(err) then
      headline = headline .. "   (" .. M.detail_key() .. " for detail)"
    end
    vim.notify("DBClient: " .. headline, vim.log.levels.ERROR)
  end

  -- The panel is opt-in. A split that appears every time a metadata fetch
  -- fails would train people to close it without reading it.
  if opts.panel then
    M.show(err, {
      session_id = err.session_id,
      source = opts.source or err.statement,
      focus = false,
    })
  end

  return err
end

--- Whether the panel would say more than the notification already did.
---@param err table
---@return boolean
function M.has_more(err)
  return err.position ~= nil
    or err.detail ~= nil
    or err.hint ~= nil
    or err.constraint ~= nil
    or err.referenced_table ~= nil
    or (EXPLANATIONS[err.kind] or {}).body ~= nil
end

--- How the user gets to the detail, in their own keymap.
---@return string
function M.detail_key()
  local ok, keymap = pcall(require, "dbclient.keymap")
  if ok and keymap.prefix then
    return keymap.prefix():gsub("<leader>", vim.g.mapleader == " " and "<space>" or "\\") .. "!"
  end
  return "<leader>d!"
end

return M

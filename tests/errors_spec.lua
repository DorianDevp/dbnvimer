--- The presentation half of error handling. The parsing half is in Rust.
---
--- The thing under test is mostly arithmetic: three coordinate systems meet in
--- `locate`, and getting any of them wrong puts the caret somewhere plausible
--- and false — which is worse than no caret, because a wrong pointer is
--- believed.

local t = require("tests.init")
local errors = require("dbclient.errors")

--- What the core sends for a MySQL syntax error in `select * FORM users`.
local function syntax_detail(overrides)
  return vim.tbl_extend("force", {
    kind = "syntax",
    message = "syntax error",
    code = "1064",
    sqlstate = "42000",
    near = "FORM",
    position = 10,
    statement = "select * FORM users",
    statement_fault = true,
    adapter = "mariadb",
  }, overrides or {})
end

t.describe("normalising", {
  ["accepts a bare string from an older core"] = function()
    local err = errors.normalise("something went wrong")
    t.eq(err.kind, "unknown")
    t.eq(err.message, "something went wrong")
    t.eq(err.position, nil)
  end,

  ["prefers the server's own message over the wrapped one"] = function()
    local err = errors.normalise("failed to execute query: syntax error", syntax_detail())
    t.eq(err.message, "syntax error")
    t.eq(err.kind, "syntax")
    t.eq(err.code, "1064")
  end,

  ["keeps the surrounding context, which says what was attempted"] = function()
    local err = errors.normalise("x", syntax_detail({ context = "failed to apply update" }))
    t.eq(err.context, "failed to apply update")
  end,
})

t.describe("locating the error in the buffer", {
  ["a single statement on the first line"] = function()
    local source = "select * FORM users"
    local at = errors.locate(errors.normalise("x", syntax_detail()), source, 1)
    t.eq(at.line, 0, "0-based buffer line")
    t.eq(at.col, 9, "0-based byte column, on the F")
    t.eq(source:sub(at.col + 1, at.end_col), "FORM")
  end,

  ["a statement that does not start on line one"] = function()
    local source = "-- a comment\n\nselect * FORM users"
    local at = errors.locate(
      errors.normalise("x", syntax_detail({ statement_offset = 14 })),
      source,
      1
    )
    t.eq(at.line, 2)
    t.eq(at.col, 9)
  end,

  ["a statement whose own text spans lines"] = function()
    local statement = "select id\nfrom users\nwhere statuz = 1"
    -- Character 27 of the statement is the `s` of `statuz`.
    local position = statement:find("statuz")
    local at = errors.locate(
      errors.normalise("x", {
        kind = "undefined_column",
        message = "there is no column `statuz`",
        near = "statuz",
        position = position,
        statement = statement,
      }),
      statement,
      1
    )
    t.eq(at.line, 2, "third line of the statement")
    t.eq(at.col, 6)
    local line = vim.split(statement, "\n")[at.line + 1]
    t.eq(line:sub(at.col + 1, at.end_col), "statuz")
  end,

  ["a statement inside a file, offset and multi-line together"] = function()
    local source = table.concat({
      "-- header",
      "select 1;",
      "",
      "select id",
      "from users",
      "where statuz = 1;",
    }, "\n")
    local statement = "select id\nfrom users\nwhere statuz = 1"
    local at = errors.locate(
      errors.normalise("x", {
        kind = "undefined_column",
        near = "statuz",
        position = statement:find("statuz"),
        statement = statement,
        statement_offset = source:find("select id", 1, true) - 1,
      }),
      source,
      1
    )
    -- Line 6 of the file, 0-based 5.
    t.eq(at.line, 5)
    t.eq(at.col, 6)
    local line = vim.split(source, "\n")[at.line + 1]
    t.eq(line:sub(at.col + 1, at.end_col), "statuz")
  end,

  ["offsets by the buffer line the source begins on"] = function()
    local at = errors.locate(errors.normalise("x", syntax_detail()), "select * FORM users", 12)
    t.eq(at.line, 11, "line 12, 0-based")
  end,

  ["counts characters for the position and bytes for the column"] = function()
    -- The position the server reports counts characters; Neovim's column
    -- counts bytes. Every accented character before the error moves them apart.
    local statement = "select 'Łódź' FORM t"
    local position = vim.fn.strchars(vim.split(statement, "FORM")[1]) + 1
    local at = errors.locate(
      errors.normalise("x", {
        kind = "syntax",
        near = "FORM",
        position = position,
        statement = statement,
      }),
      statement,
      1
    )
    t.eq(statement:sub(at.col + 1, at.col + 4), "FORM", "landed on FORM, not near it")
  end,

  ["underlines the quoted fragment, not the rest of the line"] = function()
    local source = "select * FORM users where x = 1"
    local at = errors.locate(errors.normalise("x", syntax_detail()), source, 1)
    t.eq(at.end_col - at.col, 4, "just FORM")
  end,

  ["underlines the word at the position when nothing was quoted"] = function()
    local source = "select * from userz"
    local at = errors.locate(
      errors.normalise("x", {
        kind = "undefined_table",
        position = 15,
        statement = source,
      }),
      source,
      1
    )
    t.eq(source:sub(at.col + 1, at.end_col), "userz")
  end,

  ["declines when there is no position"] = function()
    t.eq(errors.locate(errors.normalise("boom"), "select 1", 1), nil)
  end,
})

t.describe("the caret", {
  ["points under the offending token"] = function()
    local lines = errors.caret(errors.normalise("x", syntax_detail()))
    t.eq(#lines, 2)
    t.matches(lines[1], "select %* FORM users$")
    -- Both measured in display cells: the gutter's rule glyph is three bytes
    -- and one cell, so comparing byte indices here would silently pass on a
    -- caret that is two cells off.
    local caret = vim.fn.strdisplaywidth(lines[2]:sub(1, lines[2]:find("%^") - 1))
    local statement_start =
      vim.fn.strdisplaywidth(lines[1]:sub(1, lines[1]:find("select", 1, true) - 1))
    t.eq(caret - statement_start, 9, "nine cells in, on the F")
    t.matches(lines[2], "%^~~~", "and underlines the whole fragment")
  end,

  ["picks the right line of a multi-line statement"] = function()
    local statement = "select id\nfrom users\nwhere statuz = 1"
    local lines = errors.caret(errors.normalise("x", {
      kind = "undefined_column",
      near = "statuz",
      position = statement:find("statuz"),
      statement = statement,
    }))
    t.matches(lines[1], "where statuz = 1$")
    t.matches(lines[1], "^  3 ", "and labels it with its line number")
  end,

  ["places the caret by display width, not by byte"] = function()
    local statement = "select 'Łódź' FORM t"
    local position = vim.fn.strchars(vim.split(statement, "FORM")[1]) + 1
    local lines = errors.caret(errors.normalise("x", {
      kind = "syntax",
      near = "FORM",
      position = position,
      statement = statement,
    }))
    -- Counting bytes would push the caret two cells right of the F.
    local caret = lines[2]:find("%^")
    local target = vim.fn.strdisplaywidth(lines[1]:sub(1, lines[1]:find("FORM") - 1)) + 1
    t.eq(caret, target, "the caret sits under the F")
  end,

  ["says nothing when there is no position"] = function()
    t.eq(errors.caret(errors.normalise("boom")), {})
  end,
})

t.describe("did you mean", {
  ["measures edit distance"] = function()
    t.eq(errors.distance("status", "status", 3), 0)
    t.eq(errors.distance("statuz", "status", 3), 1)
    t.ok(errors.distance("status", "completely_different", 3) > 3)
  end,

  ["counts a transposition as one edit"] = function()
    -- Plain Levenshtein charges two for this, which puts the commonest typo of
    -- all outside any threshold tight enough to be useful on a short name.
    t.eq(errors.distance("nmae", "name", 2), 1)
    t.eq(errors.distance("sttaus", "status", 2), 1)
    t.eq(errors.distance("craeted_at", "created_at", 2), 1)
  end,

  ["suggests a transposed name"] = function()
    t.eq(errors.suggest("nmae", { "name", "id", "city" })[1], "name")
  end,

  ["gives up early on a hopeless pair"] = function()
    -- The cap exists so a schema with 400 columns does not cost a full matrix
    -- for each one.
    t.ok(errors.distance("a", "aaaaaaaaaaaaaaaaaaaa", 2) > 2)
  end,

  ["suggests the near miss"] = function()
    local names = errors.suggest("statuz", { "status", "state", "created_at", "id" })
    t.eq(names[1], "status")
  end,

  ["scales the threshold with the length of the name"] = function()
    -- One letter out of three is a different word; one out of ten is a typo.
    t.eq(errors.suggest("abc", { "xyz" }), {})
    t.eq(errors.suggest("created_att", { "created_at" })[1], "created_at")
  end,

  ["suggests a name that contains the one that was typed"] = function()
    local names = errors.suggest("user", { "user_account", "inquiry", "address" })
    t.eq(names[1], "user_account")
  end,

  ["never suggests the name that was already tried"] = function()
    t.eq(errors.suggest("status", { "status" }), {})
  end,

  ["returns nothing rather than nonsense"] = function()
    t.eq(errors.suggest("statuz", { "completely", "unrelated", "names" }), {})
  end,
})

t.describe("rendering", {
  ["leads with the server's message and the codes"] = function()
    local lines = errors.render(errors.normalise("x", syntax_detail()))
    local text = table.concat(lines, "\n")
    t.matches(lines[1], "^syntax error")
    t.matches(text, "1064")
    t.matches(text, "SQLSTATE 42000")
    t.matches(text, "mariadb")
  end,

  ["shows the caret and then explains"] = function()
    local text = table.concat(errors.render(errors.normalise("x", syntax_detail())), "\n")
    t.matches(text, "select %* FORM users")
    t.matches(text, "%^~~~")
    t.matches(text, "the server could not parse this")
  end,

  ["lists the facts the server handed over"] = function()
    local text = table.concat(
      errors.render(errors.normalise("x", {
        kind = "foreign_key",
        message = "a referenced row does not exist",
        schema = "shop",
        table = "inquiry",
        column = "user_id",
        constraint = "fk_inquiry_user",
        referenced_table = "user",
        referenced_column = "id",
        value = "9999",
      })),
      "\n"
    )
    -- All of this is in the message MySQL sends and none of it is ever shown.
    t.matches(text, "shop%.inquiry")
    t.matches(text, "user_id")
    t.matches(text, "fk_inquiry_user")
    t.matches(text, "user%.id")
    t.matches(text, "9999")
    t.matches(text, "the relationship does not hold")
  end,

  ["keeps PostgreSQL's DETAIL and HINT"] = function()
    local text = table.concat(
      errors.render(errors.normalise("x", {
        kind = "undefined_column",
        message = 'column "statuz" does not exist',
        detail = "Key (user_id)=(9999) is not present in table \"user\".",
        hint = 'Perhaps you meant to reference the column "inquiry.status".',
      })),
      "\n"
    )
    -- Two of the most useful lines PostgreSQL produces, routinely discarded.
    t.matches(text, "is not present in table")
    t.matches(text, "hint: Perhaps you meant")
  end,

  ["marks a transient failure as worth retrying"] = function()
    local text = table.concat(
      errors.render(errors.normalise("x", {
        kind = "deadlock",
        message = "Deadlock found when trying to get lock",
        transient = true,
      })),
      "\n"
    )
    t.matches(text, "worth simply retrying")
    t.matches(text, "broke the tie")
  end,

  ["explains a refusal that never reached the server"] = function()
    local text = table.concat(
      errors.render(errors.normalise("x", {
        kind = "access_refused",
        message = "this connection is read-only, so `delete` was not run",
      })),
      "\n"
    )
    t.matches(text, "the server never saw it")
    t.matches(text, "DBClientConnections")
  end,

  ["has an explanation for every kind the core can produce"] = function()
    -- A kind with no entry falls back to a generic sentence, which is exactly
    -- the outcome this whole module exists to avoid.
    local kinds = {
      "syntax",
      "undefined_table",
      "undefined_column",
      "undefined_function",
      "undefined_database",
      "duplicate_object",
      "not_null",
      "foreign_key",
      "unique",
      "check",
      "data_type",
      "string_too_long",
      "numeric_range",
      "division_by_zero",
      "collation",
      "column_count",
      "no_default",
      "permission",
      "authentication",
      "deadlock",
      "lock_timeout",
      "statement_timeout",
      "cancelled",
      "transaction_aborted",
      "read_only",
      "connection_lost",
      "too_many_connections",
      "access_refused",
      "unknown",
    }
    for _, kind in ipairs(kinds) do
      local summary = errors.summary(kind)
      t.ok(summary ~= nil and summary ~= "", kind .. " has a summary")
      if kind ~= "unknown" then
        t.ok(
          summary ~= errors.summary("unknown"),
          kind .. " has its own summary rather than the fallback"
        )
      end
    end
  end,

  ["names which statement of a script failed"] = function()
    local lines = errors.render(errors.normalise("x", syntax_detail({ statement_index = 7 })))
    t.matches(lines[1], "statement 7")
  end,
})

t.describe("history", {
  ["keeps the newest first"] = function()
    errors.clear()
    errors.record("first", { kind = "syntax", message = "first" })
    errors.record("second", { kind = "unique", message = "second" })
    t.eq(errors.last().message, "second")
    t.eq(#errors.history, 2)
  end,

  ["is bounded"] = function()
    errors.clear()
    local limit = errors.limit
    for index = 1, limit + 10 do
      errors.record("e" .. index, { kind = "unknown", message = "e" .. index })
    end
    t.eq(#errors.history, limit)
    t.eq(errors.last().message, "e" .. (limit + 10))
    errors.clear()
  end,

  ["reports nothing when nothing has failed"] = function()
    errors.clear()
    t.eq(errors.last(), nil)
  end,
})

t.describe("diagnostics", {
  ["land on the token, not on the cursor line"] = function()
    errors.clear()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "-- a comment",
      "select * FORM users",
    })

    local err = errors.normalise("x", syntax_detail({ statement_offset = 13 }))
    local source = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    t.ok(errors.diagnose(bufnr, err, { source = source, first_line = 1 }))

    local placed = vim.diagnostic.get(bufnr, { namespace = errors.ns })
    t.eq(#placed, 1)
    t.eq(placed[1].lnum, 1, "second line")
    t.eq(placed[1].col, 9, "on the F")
    t.eq(placed[1].end_col, 13)
    t.eq(placed[1].severity, vim.diagnostic.severity.ERROR)

    errors.clear_diagnostics(bufnr)
    t.eq(#vim.diagnostic.get(bufnr, { namespace = errors.ns }), 0)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end,

  ["fall back to the first line rather than nowhere"] = function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "delete from users" })
    errors.diagnose(bufnr, errors.normalise("refused", { kind = "access_refused" }), {
      source = "delete from users",
      first_line = 1,
    })
    local placed = vim.diagnostic.get(bufnr, { namespace = errors.ns })
    t.eq(#placed, 1, "an error with no position is still visible in the buffer")
    t.eq(placed[1].lnum, 0)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end,

  ["clamp to the buffer rather than throwing"] = function()
    -- The buffer can change between running a statement and the reply landing.
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x" })
    local err = errors.normalise("x", syntax_detail({ statement_offset = 9999 }))
    t.ok(errors.diagnose(bufnr, err, { source = "x", first_line = 1 }))
    local placed = vim.diagnostic.get(bufnr, { namespace = errors.ns })
    t.eq(placed[1].lnum, 0)
    t.ok(placed[1].col <= 1)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end,
})

t.describe("what to do next", {
  ["offers a rollback when the transaction is broken"] = function()
    local remedy = errors.remedy(errors.normalise("x", { kind = "transaction_aborted" }))
    t.ok(remedy ~= nil, "an aborted transaction has one obvious fix")
    t.eq(remedy.key, "r")
    t.matches(remedy.label, "roll back")
  end,

  ["offers the lock view when something is blocking"] = function()
    for _, kind in ipairs({ "lock_timeout", "deadlock" }) do
      local remedy = errors.remedy(errors.normalise("x", { kind = kind }))
      t.ok(remedy ~= nil, kind .. " points at the lock view")
      t.eq(remedy.key, "L")
    end
  end,

  ["offers nothing when there is nothing unambiguous to offer"] = function()
    -- A syntax error has no one right fix, and a key that guesses is worse
    -- than no key.
    t.eq(errors.remedy(errors.normalise("x", { kind = "syntax" })), nil)
    t.eq(errors.remedy(errors.normalise("x", { kind = "foreign_key" })), nil)
  end,

  ["puts the offer in the panel"] = function()
    local text = table.concat(
      errors.render(errors.normalise("x", {
        kind = "transaction_aborted",
        message = "current transaction is aborted",
      })),
      "\n"
    )
    t.matches(text, "r  roll back and carry on")
  end,
})

local diagnose = require("dbclient.diagnose")

t.describe("diagnosing a connection", {
  ["accepts an address without resolving it"] = function()
    local step = diagnose.check_host("127.0.0.1")
    t.ok(step.ok)
    t.matches(step.detail, "is an address")
  end,

  ["reports a name that does not resolve"] = function()
    local step = diagnose.check_host("no-such-host.invalid")
    t.falsy(step.ok)
    t.matches(step.detail, "does not resolve")
    t.ok(step.remedy ~= nil, "and says what to look at")
  end,

  ["reports a missing host as a configuration problem"] = function()
    local step = diagnose.check_host("")
    t.falsy(step.ok)
    t.matches(step.remedy, "set `host`")
  end,

  ["tells a closed port from a listening one"] = function()
    -- Port 1 is reserved and nothing sane listens there.
    local step = diagnose.check_port("127.0.0.1", 1, 1000)
    t.falsy(step.ok)
    t.matches(step.detail, "127%.0%.0%.1:1")
  end,

  ["names the credential layer when the socket was fine"] = function()
    local steps = diagnose.layers_from_error(
      errors.normalise("x", { kind = "authentication" }),
      { user = "serwis" }
    )
    t.eq(#steps, 1)
    t.eq(steps[1].layer, "credentials")
    t.matches(steps[1].detail, "serwis")
    -- The thing that actually catches people out.
    t.matches(steps[1].remedy, "per host")
  end,

  ["separates a good login from a missing database"] = function()
    local steps = diagnose.layers_from_error(
      errors.normalise("x", { kind = "undefined_database" }),
      { database = "serwis" }
    )
    t.eq(#steps, 2)
    t.ok(steps[1].ok, "the login worked")
    t.falsy(steps[2].ok)
    t.eq(steps[2].layer, "database")
  end,

  ["checks a file rather than a socket for SQLite"] = function()
    local steps = diagnose.run({ spec = { adapter = "sqlite", path = "/nope/missing.db" } })
    t.eq(#steps, 1)
    t.eq(steps[1].layer, "file")
    t.falsy(steps[1].ok)

    local existing = vim.fn.tempname()
    vim.fn.writefile({ "" }, existing)
    local ok_steps = diagnose.run({ spec = { adapter = "sqlite", path = existing } })
    t.ok(ok_steps[1].ok)
    vim.fn.delete(existing)
  end,

  ["stops at the first layer that failed"] = function()
    -- Once the name does not resolve there is nothing true to say about the
    -- port, and saying it anyway would be a guess.
    local steps = diagnose.run({
      spec = { adapter = "mariadb", host = "no-such-host.invalid", port = 3306 },
    })
    t.eq(#steps, 1)
    t.eq(steps[1].layer, "host")
  end,

  ["renders each layer with its verdict"] = function()
    local lines = diagnose.render({
      { layer = "host", ok = true, detail = "db resolves to 10.0.0.2" },
      { layer = "port", ok = false, detail = "10.0.0.2:3306 — ECONNREFUSED", remedy = "nothing is listening there" },
    }, {}, "prod")
    local text = table.concat(lines, "\n")
    t.matches(text, "could not connect to `prod`")
    t.matches(text, "ok  host")
    t.matches(text, "✗   port")
    t.matches(text, "nothing is listening there")
  end,
})

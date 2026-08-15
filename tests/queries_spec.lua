local t = require("tests.init")
local config = require("dbclient.config")
local queries = require("dbclient.queries")

local workdir = vim.fn.tempname()
vim.fn.mkdir(workdir .. "/global", "p")
vim.fn.mkdir(workdir .. "/project/.dbclient/queries", "p")

config.setup({
  connections = {},
  history = { path = workdir .. "/global/history.jsonl" },
})

t.describe("saved query files", {
  ["parses a header block"] = function()
    local meta, body = queries.parse({
      "-- @name: overdue invoices",
      "-- @conn: staging",
      "-- @desc: unpaid past due",
      "-- @tags: billing, support",
      "",
      "select * from invoices",
      "where paid_at is null;",
    })

    t.eq(meta.name, "overdue invoices")
    t.eq(meta.conn, "staging")
    t.eq(meta.desc, "unpaid past due")
    t.eq(meta.tags, { "billing", "support" })
    t.eq(body, { "select * from invoices", "where paid_at is null;" })
  end,

  ["treats a file with no header as all body"] = function()
    local meta, body = queries.parse({ "select 1;" })
    t.eq(meta, {})
    t.eq(body, { "select 1;" })
  end,

  ["does not mistake a comment in the SQL for a header"] = function()
    local _, body = queries.parse({
      "-- @name: x",
      "",
      "-- a normal comment",
      "select 1;",
    })
    t.eq(body, { "-- a normal comment", "select 1;" })
  end,

  ["renders back to the same shape"] = function()
    local entry = {
      name = "overdue invoices",
      connection = "staging",
      description = "unpaid past due",
      tags = { "billing" },
      sql = "select 1;",
    }
    local lines = queries.render(entry)
    local meta, body = queries.parse(lines)

    t.eq(meta.name, entry.name)
    t.eq(meta.conn, entry.connection)
    t.eq(meta.tags, entry.tags)
    t.eq(table.concat(body, "\n"), entry.sql)
  end,

  ["makes a readable file name"] = function()
    t.eq(queries.slug("Overdue Invoices!"), "overdue-invoices")
    t.eq(queries.slug("  "), "query")
    t.eq(queries.slug("już zapłacone"), "ju-zap-acone")
  end,
})

t.describe("saved query storage", {
  ["writes, lists and finds a query"] = function()
    local path, err = queries.save({
      name = "test query",
      sql = "select 42;",
      connection = "demo",
      description = "the answer",
      scope = "global",
    })
    t.ok(path, tostring(err))
    t.eq(vim.fn.filereadable(path), 1)

    local found = queries.find("test query")
    t.ok(found, "the query should be listed")
    t.eq(found.sql, "select 42;")
    t.eq(found.connection, "demo")
    t.eq(found.scope, "global")
  end,

  ["refuses a query with no name or no SQL"] = function()
    local path, err = queries.save({ name = "", sql = "select 1;" })
    t.eq(path, nil)
    t.matches(err, "name")

    path, err = queries.save({ name = "x", sql = "   " })
    t.eq(path, nil)
    t.matches(err, "SQL")
  end,

  ["renames without leaving the old file behind"] = function()
    queries.save({ name = "before", sql = "select 1;", scope = "global" })
    local entry = queries.find("before")
    local path = queries.rename(entry, "after")

    t.ok(path)
    t.eq(queries.find("before"), nil)
    t.ok(queries.find("after"))
    t.eq(vim.fn.filereadable(entry.path), 0, "the old file is gone")
  end,

  ["deletes"] = function()
    queries.save({ name = "doomed", sql = "select 1;", scope = "global" })
    local entry = queries.find("doomed")
    t.ok(queries.delete(entry.path))
    t.eq(queries.find("doomed"), nil)
  end,

  ["lists project queries before global ones"] = function()
    local cwd = vim.uv.cwd()
    vim.cmd("cd " .. workdir .. "/project")

    queries.save({ name = "project one", sql = "select 1;", scope = "project" })
    queries.save({ name = "global one", sql = "select 2;", scope = "global" })

    local entries = queries.list()
    local scopes = vim.tbl_map(function(entry)
      return entry.scope
    end, entries)
    t.eq(scopes[1], "project", "project scope comes first")

    vim.cmd("cd " .. cwd)
  end,
})

t.describe("saved query scope changes", {
  ["promotes a global query to the project and back"] = function()
    local cwd = vim.uv.cwd()
    vim.cmd("cd " .. workdir .. "/project")

    queries.save({ name = "movable", sql = "select 1;", scope = "global" })
    local entry = queries.find("movable")
    t.eq(entry.scope, "global")

    local path = queries.promote(entry)
    t.ok(path)
    t.eq(vim.fn.filereadable(entry.path), 0, "the source file must not be left behind")

    local moved = queries.find("movable")
    t.eq(moved.scope, "project")

    -- And back again.
    queries.promote(moved)
    t.eq(queries.find("movable").scope, "global")

    vim.cmd("cd " .. cwd)
  end,
})

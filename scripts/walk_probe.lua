--- Walk the paths a user actually takes and print what they see.
---
---   nvim --headless -u NONE -c "luafile scripts/walk_probe.lua"
---
--- Documentation written from reading the source describes what the author
--- believes happens. This prints the buffers, so it describes what happens.
--- Every step reports the window layout as well, because "where did that open"
--- is half of what a reader needs.
---
--- Uses a throwaway SQLite database. Read only where it can be.

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.columns = 108
vim.o.lines = 40

local workdir = vim.fn.tempname()
vim.fn.mkdir(workdir, "p")
local db = workdir .. "/shop.db"

vim.system({ "sqlite3", db }, {
  stdin = [[
create table customers (
  id integer primary key,
  name text not null,
  email text unique,
  created_at text
);
create table order_status (id integer primary key, name text not null);
create table orders (
  id integer primary key,
  reference text not null,
  customer_id integer not null references customers(id),
  status_id integer not null references order_status(id),
  created_at text,
  note text
);
insert into customers values
  (7, 'Alice Chen', 'alice@example.com', '2026-01-04'),
  (8, 'Bo Nakamura', 'bo@example.com', '2026-01-09');
insert into order_status values (1,'awaiting payment'),(2,'picking'),(3,'dispatched');
insert into orders values
  (1042, 'SO-2026-1042', 7, 1, '2026-03-01 09:14:00', NULL),
  (1043, 'SO-2026-1043', 8, 3, '2026-03-01 11:02:31', 'urgent'),
  (1044, 'SO-2026-1044', 7, 2, '2026-03-02 08:40:12', NULL);
]],
  text = true,
}):wait()

-- ---------------------------------------------------------------------------

local step_number = 0

local function rule(title)
  step_number = step_number + 1
  print("")
  print(("══ %d. %s "):format(step_number, title) .. string.rep("═", math.max(0, 84 - #title)))
end

--- Which windows exist, how big, and which one has the cursor.
---
--- Floats are marked, because "it opened a window" and "it opened a float you
--- dismiss with `q`" are different things to a reader.
local function layout()
  local splits, floats = {}, {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local bufnr = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(bufnr)
    name = name ~= "" and vim.fn.fnamemodify(name, ":t") or "[no name]"
    local entry = ("%s %dx%d%s"):format(
      name,
      vim.api.nvim_win_get_width(win),
      vim.api.nvim_win_get_height(win),
      win == vim.api.nvim_get_current_win() and " ←" or ""
    )
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      table.insert(floats, entry)
    else
      table.insert(splits, entry)
    end
  end
  print("   windows: " .. table.concat(splits, " │ "))
  if #floats > 0 then
    print("   floats:  " .. table.concat(floats, " │ "))
  end
end

--- Print a buffer exactly as it is.
local function show(bufnr, limit)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    print("   (no buffer)")
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines == 0 or (#lines == 1 and lines[1] == "") then
    print("   (empty)")
    return
  end
  for index, line in ipairs(lines) do
    if index > (limit or 30) then
      print(("   … %d more line(s)"):format(#lines - limit))
      break
    end
    print("   " .. line)
  end
end

local function sidebar_buffer()
  return require("dbclient.ui.sidebar").bufnr
end

local function wait_until(predicate, timeout)
  return vim.wait(timeout or 15000, predicate, 25)
end

-- ---------------------------------------------------------------------------
-- Cold start: nothing configured at all
-- ---------------------------------------------------------------------------

require("dbclient").setup({
  core = { command = vim.fn.getcwd() .. "/rust/dbclient-core/target/release/dbclient-core" },
  detect = { enabled = false },
  store = { enabled = false },
  history = { enabled = false, path = workdir .. "/history.jsonl" },
  export = { dir = workdir .. "/exports" },
  connections = {},
})

rule("`:DBClient` with nothing configured")
require("dbclient.ui.sidebar").open()
vim.wait(400, function()
  return false
end, 50)
layout()
show(sidebar_buffer())

-- ---------------------------------------------------------------------------
-- With a connection configured but not open
-- ---------------------------------------------------------------------------

require("dbclient.config").setup({
  core = { command = vim.fn.getcwd() .. "/rust/dbclient-core/target/release/dbclient-core" },
  detect = { enabled = false },
  store = { enabled = false },
  history = { enabled = false, path = workdir .. "/history.jsonl" },
  export = { dir = workdir .. "/exports" },
  connections = {
    shop = { adapter = "sqlite", path = db },
    reporting = { adapter = "sqlite", path = db, access = "read", color = "red" },
  },
})
require("dbclient.connections").rescan()

rule("the same sidebar once connections exist")
require("dbclient.ui.sidebar").render()
vim.wait(400, function()
  return false
end, 50)
show(sidebar_buffer())

-- ---------------------------------------------------------------------------
-- Connecting
-- ---------------------------------------------------------------------------

local session = require("dbclient.session")
local sidebar = require("dbclient.ui.sidebar")

--- Press `<CR>` on the first node of a kind, the way a user would.
local function press_cr_on(kind, name)
  for index, node in ipairs(sidebar.nodes or {}) do
    if node.kind == kind and (not name or node.name == name or node.table == name) then
      vim.api.nvim_set_current_win(sidebar.winid)
      vim.api.nvim_win_set_cursor(sidebar.winid, { index, 0 })
      sidebar.open_node()
      return true
    end
  end
  return false
end

rule("`<CR>` on a connection")
press_cr_on("connection", "shop")
local target
wait_until(function()
  target = session.find_by_name("shop")
  return target ~= nil
end)
vim.wait(900, function()
  return false
end, 50)
show(sidebar_buffer())

rule("`<CR>` on the schema it revealed")
press_cr_on("schema")
vim.wait(900, function()
  return false
end, 50)
show(sidebar_buffer())

rule("`l` on a table node — `<CR>` would open its data instead")
for index, node in ipairs(sidebar.nodes or {}) do
  if node.kind == "table" and node.table == "customers" then
    vim.api.nvim_set_current_win(sidebar.winid)
    vim.api.nvim_win_set_cursor(sidebar.winid, { index, 0 })
    sidebar.expand()
    break
  end
end
vim.wait(900, function()
  return false
end, 50)
show(sidebar_buffer(), 26)

-- ---------------------------------------------------------------------------
-- Opening a table
-- ---------------------------------------------------------------------------

rule("`<CR>` on a table")
local data = require("dbclient.ui.data")
data.open({ session_id = target.id, schema = "main", table = "orders", filter = "" })
local view
wait_until(function()
  for _, candidate in pairs(data.views) do
    if candidate.table == "orders" and (candidate.generation or 0) > 0 then
      view = candidate
      return true
    end
  end
  return false
end)
vim.wait(400, function()
  return false
end, 50)
layout()
show(view and view.bufnr)

rule("the winbar while that is open")
print("   " .. tostring(require("dbclient.ui.winbar").render(view.bufnr)))

-- ---------------------------------------------------------------------------
-- The things a reader will press next
-- ---------------------------------------------------------------------------

rule("`gt` — transpose this row")
vim.api.nvim_set_current_buf(view.bufnr)
vim.api.nvim_win_set_cursor(0, { data.HEADER_LINES + 1, 0 })
data.transpose()
vim.wait(600, function()
  return false
end, 50)
layout()
show(vim.api.nvim_get_current_buf(), 20)
vim.api.nvim_feedkeys("q", "x", false)

rule("`g?` — the help for this buffer")
vim.api.nvim_set_current_buf(view.bufnr)
require("dbclient.ui.help").show("data")
vim.wait(300, function()
  return false
end, 50)
show(vim.api.nvim_get_current_buf(), 14)
vim.cmd("silent! close")

rule("`gK` — the whole record")
vim.api.nvim_set_current_buf(view.bufnr)
vim.api.nvim_win_set_cursor(0, { data.HEADER_LINES + 1, 0 })
require("dbclient.neighbourhood").from_cursor()
wait_until(function()
  return next(require("dbclient.neighbourhood").views) ~= nil
end)
vim.wait(600, function()
  return false
end, 50)
layout()
for bufnr in pairs(require("dbclient.neighbourhood").views) do
  show(bufnr, 22)
end

rule("a query buffer, and a result")
local query = require("dbclient.ui.query")
query.open({ session_id = target.id })
local qbuf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(qbuf, 0, -1, false, {
  "select s.name, count(*) as n",
  "from orders o join order_status s on s.id = o.status_id",
  "group by s.name;",
})
layout()
local results = require("dbclient.ui.results")
local done = false
require("dbclient.core.client").async(function()
  local out = session.query(target.id, table.concat(vim.api.nvim_buf_get_lines(qbuf, 0, -1, false), "\n"))
  results.show(out, { session_id = target.id, session_name = "shop", sql = "select …" })
  done = true
end, function(err)
  print("   ERROR " .. tostring(err))
  done = true
end)
wait_until(function()
  return done
end)
vim.wait(400, function()
  return false
end, 50)
layout()
show(results.bufnr or vim.api.nvim_get_current_buf(), 14)

rule("a statement that fails")
local failed = false
require("dbclient.core.client").async(function()
  session.query(target.id, "select * FORM orders")
end, function(err, detail)
  local errors = require("dbclient.errors")
  local normalised = errors.normalise(err, detail)
  for _, line in ipairs((errors.render(normalised, { source = "select * FORM orders", width = 80 }))) do
    print("   " .. line)
  end
  failed = true
end)
wait_until(function()
  return failed
end)

print("")
print(string.rep("═", 90))
session.disconnect_all()
require("dbclient.core.client").stop()
vim.cmd("cquit 0")

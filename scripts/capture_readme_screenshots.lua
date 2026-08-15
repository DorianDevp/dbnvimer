--- Render README screenshots from a real DBClient session.
---
---   DBCLIENT_SHOT_DSN="host=127.0.0.1 port=53306 user=root password=dbclient database=shop" \
---     nvim --headless -u NONE -c "luafile scripts/capture_readme_screenshots.lua"
---
--- Drives the actual UI, captures the rendered buffers, and writes an SVG per
--- screenshot plus a PNG when `rsvg-convert` is available. The SVGs are kept
--- beside the PNGs so a change in appearance shows up as a readable diff.

local root = vim.fn.getcwd()
local out_dir = root .. "/docs/screenshots"
vim.fn.mkdir(out_dir, "p")
vim.opt.runtimepath:prepend(root)

vim.o.columns = 150
vim.o.lines = 44

local core = root .. "/rust/dbclient-core/target/release/dbclient-core"
if vim.fn.executable(core) ~= 1 then
  print("dbclient-core is not built")
  vim.cmd("cquit 1")
end

-- ---------------------------------------------------------------------------
-- SVG rendering
-- ---------------------------------------------------------------------------

local COLORS = {
  bg = "#16181d",
  panel = "#1b1e24",
  border = "#2c313a",
  text = "#c5cad3",
  muted = "#6b7280",
  title = "#e5c07b",
  header = "#61afef",
  separator = "#4b5263",
  number = "#d19a66",
  temporal = "#c678dd",
  json = "#98c379",
  null = "#5c6370",
  key = "#e06c75",
  green = "#98c379",
  red = "#e06c75",
  add = "#98c379",
  change = "#61afef",
  remove = "#e06c75",
}

local CHAR_WIDTH = 8.4
local LINE_HEIGHT = 19
local PADDING = 16

local function escape(text)
  return tostring(text)
    :gsub("&", "&amp;")
    :gsub("<", "&lt;")
    :gsub(">", "&gt;")
    :gsub('"', "&quot;")
end

--- Write one SVG made of coloured lines.
---@param name string
---@param title string
---@param lines { text: string, color?: string }[]
local function write_svg(name, title, lines)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line.text))
  end
  width = math.max(width, #title + 8)

  local pixel_width = math.floor(width * CHAR_WIDTH + PADDING * 2)
  local pixel_height = math.floor(#lines * LINE_HEIGHT + PADDING * 2 + 34)

  local parts = {
    ([[<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="JetBrains Mono, DejaVu Sans Mono, monospace" font-size="13">]])
      :format(pixel_width, pixel_height, pixel_width, pixel_height),
    ([[<rect width="%d" height="%d" rx="8" fill="%s"/>]]):format(pixel_width, pixel_height, COLORS.bg),
    ([[<rect x="0" y="0" width="%d" height="30" rx="8" fill="%s"/>]]):format(pixel_width, COLORS.panel),
    ([[<rect x="0" y="22" width="%d" height="8" fill="%s"/>]]):format(pixel_width, COLORS.panel),
    ([[<circle cx="18" cy="15" r="5" fill="#e06c75"/><circle cx="36" cy="15" r="5" fill="#e5c07b"/><circle cx="54" cy="15" r="5" fill="#98c379"/>]]),
    ([[<text x="74" y="20" fill="%s">%s</text>]]):format(COLORS.muted, escape(title)),
    ([[<line x1="0" y1="30" x2="%d" y2="30" stroke="%s" stroke-width="1"/>]]):format(pixel_width, COLORS.border),
  }

  for index, line in ipairs(lines) do
    local y = 30 + PADDING + index * LINE_HEIGHT - 4
    local text = line.text:gsub("\t", "  ")
    if text ~= "" then
      table.insert(
        parts,
        ([[<text x="%d" y="%d" fill="%s" xml:space="preserve">%s</text>]]):format(
          PADDING,
          y,
          line.color or COLORS.text,
          escape(text)
        )
      )
    end
  end

  table.insert(parts, "</svg>")

  local svg_path = ("%s/%s.svg"):format(out_dir, name)
  vim.fn.writefile(vim.split(table.concat(parts, "\n"), "\n"), svg_path)

  if vim.fn.executable("rsvg-convert") == 1 then
    vim.system({
      "rsvg-convert",
      "-o",
      ("%s/%s.png"):format(out_dir, name),
      svg_path,
    }):wait()
  end

  print(("wrote %s (%d lines)"):format(name, #lines))
end

--- Colour a grid line the way the highlight groups would.
local function grid_color(text, index)
  if index == 1 then
    return COLORS.title
  end
  if index == 2 then
    return COLORS.header
  end
  if text:match("^%-+%+") or text:match("^%-%-%-") then
    return COLORS.separator
  end
  return COLORS.text
end

local function collect(bufnr, colorer, limit)
  local lines = {}
  for index, text in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, limit or 40, false)) do
    table.insert(lines, { text = text, color = colorer and colorer(text, index) or nil })
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------------

local dsn = vim.env.DBCLIENT_SHOT_DSN
local spec

if dsn then
  spec = { adapter = "mariadb" }
  for key, value in dsn:gmatch("([%w_]+)=(%S+)") do
    if key == "host" then
      spec.host = value
    elseif key == "port" then
      spec.port = tonumber(value)
    elseif key == "user" then
      spec.user = value
    elseif key == "password" then
      spec.password = value
    elseif key == "database" then
      spec.database = value
    end
  end
else
  -- Fall back to a throwaway SQLite file so screenshots can be produced
  -- without a server running.
  local workdir = vim.fn.tempname()
  vim.fn.mkdir(workdir, "p")
  local db = workdir .. "/shop.db"
  vim.system({ "sqlite3", db }, {
    stdin = [[
create table customers (
  id integer primary key,
  name text not null,
  city text,
  balance real,
  signed_up text,
  note text
);
insert into customers values
  (1, 'Łódź Handel Sp. z o.o.', 'PL', 12450.75, '2025-11-02', NULL),
  (2, 'Gdańsk Logistics', 'PL', 980.00, '2026-01-14', 'net 30'),
  (3, 'Kraków Trading', 'PL', -215.50, '2026-02-01', 'has | a pipe'),
  (4, 'Bremen Import GmbH', 'DE', 45000.00, '2024-08-19', 'two
lines'),
  (5, 'NULL', 'CZ', 0.0, '2026-03-07', 'literal null string');
create table orders (
  id integer primary key,
  customer_id integer references customers(id),
  total real,
  placed_at text
);
insert into orders values
  (1001, 1, 990.50, '2026-01-04'),
  (1002, 1, 210.00, '2026-02-11'),
  (1003, 3, 55.25, '2026-03-02'),
  (1004, 4, 1200.00, '2026-03-09');
]],
    text = true,
  }):wait()
  spec = { adapter = "sqlite", path = db }
end

spec.color = "green"

require("dbclient").setup({
  core = { command = core },
  detect = { enabled = false },
  store = { enabled = false },
  history = { enabled = false },
  connections = {
    shop = spec,
    shop_prod = vim.tbl_extend("force", spec, { color = "red", access = "read" }),
  },
})

local client = require("dbclient.core.client")
local session = require("dbclient.session")
local sidebar = require("dbclient.ui.sidebar")
local data = require("dbclient.ui.data")

local function wait(predicate, label)
  if not vim.wait(15000, predicate, 25) then
    print("timed out waiting for " .. label)
    vim.cmd("cquit 1")
  end
end

vim.cmd("DBClient")
vim.cmd("DBClientConnect shop")
wait(function()
  return session.find_by_name("shop") ~= nil
end, "connection")

local target = session.find_by_name("shop")

--- Seed the demo schema on a server target so the shot is reproducible.
if spec.adapter ~= "sqlite" then
  local seeded = false
  client.async(function()
    for _, statement in ipairs({
      "drop table if exists orders",
      "drop table if exists customers",
      [[create table customers (
          id int primary key,
          name varchar(64) not null,
          city varchar(8),
          balance decimal(12,2),
          signed_up date,
          note varchar(64)
        )]],
      [[insert into customers values
          (1, 'Łódź Handel Sp. z o.o.', 'PL', 12450.75, '2025-11-02', NULL),
          (2, 'Gdańsk Logistics', 'PL', 980.00, '2026-01-14', 'net 30'),
          (3, 'Kraków Trading', 'PL', -215.50, '2026-02-01', 'has | a pipe'),
          (4, 'Bremen Import GmbH', 'DE', 45000.00, '2024-08-19', 'two\nlines'),
          (5, 'NULL', 'CZ', 0.00, '2026-03-07', 'literal null string')]],
      [[create table orders (
          id int primary key,
          customer_id int,
          total decimal(12,2),
          placed_at date,
          constraint fk_customer foreign key (customer_id) references customers(id)
        )]],
      [[insert into orders values
          (1001, 1, 990.50, '2026-01-04'),
          (1002, 1, 210.00, '2026-02-11'),
          (1003, 3, 55.25, '2026-03-02'),
          (1004, 4, 1200.00, '2026-03-09')]],
    }) do
      session.query(target.id, statement)
    end
    session.invalidate(target.id)
    seeded = true
  end, function(err)
    print("seed failed: " .. tostring(err))
    vim.cmd("cquit 1")
  end)
  wait(function()
    return seeded
  end, "seed")
end
local schema = target.info.database and target.info.database:match("([^/]+)$") or "main"
if spec.adapter == "sqlite" then
  schema = "main"
end

sidebar.expanded["connection:shop"] = true
sidebar.expanded["connection:shop:schema:" .. schema] = true
sidebar.expanded["connection:shop:schema:" .. schema .. ":table:customers"] = true
sidebar.render()
wait(function()
  return #vim.api.nvim_buf_get_lines(sidebar.bufnr, 0, -1, false) > 5
end, "sidebar")

-- 1. The workspace: sidebar beside a data buffer.
vim.cmd("DBClientData " .. schema .. ".customers")
local view
wait(function()
  for _, candidate in pairs(data.views) do
    if candidate.table == "customers" and (candidate.generation or 0) > 0 then
      view = candidate
      return true
    end
  end
end, "data buffer")

do
  local tree = vim.api.nvim_buf_get_lines(sidebar.bufnr, 0, 20, false)
  local grid = vim.api.nvim_buf_get_lines(view.bufnr, 0, 20, false)
  local width = 0
  for _, line in ipairs(tree) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = width + 3

  local lines = {}
  for index = 1, math.max(#tree, #grid) do
    local left = tree[index] or ""
    local pad = string.rep(" ", math.max(1, width - vim.fn.strdisplaywidth(left)))
    local right = grid[index] or ""
    local color = COLORS.text
    if index == 1 then
      color = COLORS.title
    elseif index == 2 then
      color = COLORS.header
    elseif right:match("^%-+%+") then
      color = COLORS.separator
    end
    table.insert(lines, { text = left .. pad .. "│ " .. right, color = color })
  end
  write_svg("workspace", "DBClient.nvim — sidebar and an editable data buffer", lines)
end

-- 2. The data buffer with staged edits and the change preview.
do
  local line_number = data.HEADER_LINES + 3
  local line = vim.api.nvim_buf_get_lines(view.bufnr, line_number - 1, line_number, false)[1]
  vim.api.nvim_buf_set_lines(view.bufnr, line_number - 1, line_number, false, {
    (line:gsub("Kraków Trading", "Kraków Trading SA", 1)),
  })
  -- Delete a row the way `dd` would.
  local delete_at = data.HEADER_LINES + 5
  vim.api.nvim_buf_set_lines(view.bufnr, delete_at - 1, delete_at, false, {})

  local pending = data.pending(view)
  local lines = collect(view.bufnr, grid_color, 20)
  table.insert(lines, { text = "", color = COLORS.text })
  table.insert(lines, { text = ":w", color = COLORS.muted })
  table.insert(lines, { text = "", color = COLORS.text })

  for _, text in ipairs(require("dbclient.data.diff").describe(pending, schema .. ".customers")) do
    local color = COLORS.text
    if text:match("^%s*update") then
      color = COLORS.change
    elseif text:match("^%s*delete") then
      color = COLORS.remove
    elseif text:match("^%s*insert") then
      color = COLORS.add
    elseif text:match("→") then
      color = COLORS.muted
    end
    table.insert(lines, { text = text, color = color })
  end

  write_svg("data-buffer", "Editing a table as text; :w writes the difference", lines)

  -- Put the buffer back so later shots are clean.
  client.async(function()
    data.render(view)
  end)
  vim.wait(500, function()
    return false
  end, 25)
end

-- 3. Query buffer with results.
do
  local query = require("dbclient.ui.query")
  local sql = {
    "-- @conn: shop",
    "select c.city,",
    "       count(o.id)   as orders,",
    "       sum(o.total)  as revenue",
    "from customers c",
    "left join orders o on o.customer_id = c.id",
    "group by c.city",
    "order by revenue desc;",
  }

  vim.cmd("enew")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "sql"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, sql)
  query.buffers[bufnr] = { session_id = target.id }
  query.attach(bufnr)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  query.execute()

  wait(function()
    local results = vim.fn.bufnr("dbclient://results")
    return results > 0 and #vim.api.nvim_buf_get_lines(results, 0, -1, false) > 3
  end, "results")

  local lines = {}
  for _, text in ipairs(sql) do
    table.insert(lines, { text = text, color = text:match("^%-%-") and COLORS.muted or COLORS.text })
  end
  table.insert(lines, { text = "", color = COLORS.text })
  table.insert(lines, { text = "<C-CR>", color = COLORS.muted })
  table.insert(lines, { text = "", color = COLORS.text })
  vim.list_extend(lines, collect(vim.fn.bufnr("dbclient://results"), grid_color, 12))

  write_svg("query-buffer", "A query buffer and its result grid", lines)
end

-- 4. The g? help for a data buffer.
do
  local lines = {}
  for _, text in ipairs(require("dbclient.keymap").help_lines("data")) do
    local color = COLORS.text
    if text == "Data buffer" then
      color = COLORS.title
    elseif text:match("^%s%s%S") then
      color = COLORS.header
    elseif text:match("^%S") then
      color = COLORS.muted
    end
    table.insert(lines, { text = text, color = color })
  end
  write_svg("help", "g? — the mappings for the buffer you are in", lines)
end

-- 5. The connection manager.
do
  vim.cmd("DBClientConnections")
  local manager = vim.fn.bufnr("dbclient://connections")
  local lines = {}
  for index, text in ipairs(vim.api.nvim_buf_get_lines(manager, 0, 20, false)) do
    local color = COLORS.text
    if index == 1 then
      color = COLORS.title
    elseif text:match("^●") then
      color = COLORS.green
    elseif text:match("read") then
      color = COLORS.red
    elseif text:match("^a add") then
      color = COLORS.muted
    end
    table.insert(lines, { text = text, color = color })
  end
  write_svg("connections", "Connections managed from inside the client", lines)
end

session.disconnect_all()
client.stop()
print("screenshots written to docs/screenshots")
vim.cmd("cquit 0")

local root = vim.fn.getcwd()
local out_dir = root .. "/docs/screenshots"

vim.fn.mkdir(out_dir, "p")
vim.opt.rtp:append(root)

require("dbclient").setup({
  core = {
    command = root .. "/rust/dbclient-core/target/release/dbclient-core",
  },
  connections = {
    shot_mariadb = {
      adapter = "mariadb",
      host = "127.0.0.1",
      port = 13306,
      user = "root",
      password = "dbclient",
      database = "shop",
    },
  },
})

local function esc(text)
  return tostring(text)
    :gsub("&", "&amp;")
    :gsub("<", "&lt;")
    :gsub(">", "&gt;")
    :gsub('"', "&quot;")
end

local colors = {
  bg = "#15161a",
  frame = "#1f2329",
  panel = "#181b20",
  panel2 = "#16191f",
  border = "#3b4048",
  title = "#e5c07b",
  text = "#abb2bf",
  muted = "#7f848e",
  schema = "#c678dd",
  table = "#98c379",
  column = "#56b6c2",
  header = "#61afef",
  sep = "#5c6370",
  row = "#20242b",
}

local function style_for(line)
  if line:find("%[db%]") then
    return colors.title
  elseif line:find("%[schema%]") then
    return colors.schema
  elseif line:find("%[table%]") then
    return colors.table
  elseif line:find("%[col%]") then
    return colors.column
  elseif line:find("%[procedure%]") or line:find("%[function%]") then
    return colors.table
  elseif line:find("%-%-%-") or line:find("%-%+%-") then
    return colors.sep
  elseif line:match("^%w[%w_]* |") or line:match("^id%s+|") then
    return colors.header
  end
  return colors.text
end

local function text_lines(lines, x, y, opts)
  opts = opts or {}
  local result = {}
  local size = opts.size or 15
  local step = opts.step or 26
  local limit = opts.limit or #lines

  for index = 1, math.min(#lines, limit) do
    local line = lines[index]
    if opts.rowstripe and index > 3 and index % 2 == 0 then
      table.insert(result, string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>', x - 8, y + (index - 1) * step - 18, opts.row_width or 720, step + 2, colors.row))
    end
    table.insert(result, string.format(
      '<text x="%d" y="%d" font-family="monospace" font-size="%d" fill="%s">%s</text>',
      x,
      y + (index - 1) * step,
      size,
      style_for(line),
      esc(line)
    ))
  end

  return table.concat(result, "\n")
end

local function cell(value)
  if value == nil or value == vim.NIL then
    return "NULL"
  end
  return tostring(value)
end

local function write_file(path, content)
  local file = assert(io.open(path, "w"))
  file:write(content)
  file:close()
end

local function svg(path, width, height, body)
  write_file(path, table.concat({
    string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" role="img">', width, height, width, height),
    string.format('<rect width="%d" height="%d" fill="%s"/>', width, height, colors.bg),
    string.format('<rect x="18" y="18" width="%d" height="%d" rx="8" fill="%s" stroke="%s"/>', width - 36, height - 36, colors.frame, colors.border),
    body,
    "</svg>",
  }, "\n"))
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

require("dbclient").connect("shot_mariadb")

local sidebar = require("dbclient.ui.sidebar")
sidebar.open()
sidebar.expanded["connection:shot_mariadb"] = true
sidebar.expanded["schema:shop"] = true
sidebar.expanded["tables:shop"] = true
sidebar.expanded["table:shop.orders"] = true
sidebar.expanded["routines:shop"] = true
sidebar.render()
local sidebar_lines = lines(sidebar.buf)

local data = require("dbclient.ui.data")
data.open("shop", "orders", 10)
local data_lines = lines(data.buf)

local inspect = require("dbclient.ui.inspect")
inspect.schema("shop")
local inspect_lines = lines(inspect.buf)

local query_result = require("dbclient.state").query([[
select c.email, count(o.id) as orders, sum(o.total) as revenue
from customers c
left join orders o on o.customer_id = c.id
group by c.email
order by revenue desc;
]])
local result_lines = (function(result)
  local cols = result.columns
  local rendered = { table.concat(cols, " | "), "---+--------+--------" }
  for _, row in ipairs(result.rows) do
    table.insert(rendered, table.concat(vim.tbl_map(cell, row), " | "))
  end
  return rendered
end)(query_result)

svg(out_dir .. "/workspace.svg", 1180, 680, table.concat({
  string.format('<rect x="34" y="70" width="332" height="574" fill="%s" stroke="%s"/>', colors.panel, colors.border),
  string.format('<rect x="366" y="70" width="778" height="390" fill="%s" stroke="%s"/>', colors.panel2, colors.border),
  string.format('<rect x="366" y="460" width="778" height="184" fill="%s" stroke="%s"/>', colors.panel, colors.border),
  string.format('<text x="54" y="104" font-family="monospace" font-size="16" fill="%s">DBClient tree - MariaDB</text>', colors.title),
  text_lines(sidebar_lines, 54, 136, { limit = 17, size = 14, step = 25 }),
  string.format('<text x="410" y="104" font-family="monospace" font-size="16" fill="%s">DBClient Query - shot_mariadb</text>', colors.title),
  text_lines({
    "select c.email, count(o.id) as orders, sum(o.total) as revenue",
    "from customers c",
    "left join orders o on o.customer_id = c.id",
    "group by c.email",
    "order by revenue desc;",
  }, 410, 140, { size = 15, step = 28 }),
  string.format('<text x="410" y="492" font-family="monospace" font-size="16" fill="%s">DBClient Results</text>', colors.title),
  text_lines(result_lines, 410, 528, { size = 14, step = 26, rowstripe = true, row_width = 680 }),
}, "\n"))

svg(out_dir .. "/data-buffer.svg", 1180, 620, table.concat({
  string.format('<text x="48" y="66" font-family="monospace" font-size="16" fill="%s">DBClient Data - shop.orders</text>', colors.title),
  text_lines(data_lines, 48, 106, { size = 15, step = 28, rowstripe = true, row_width = 1080 }),
  string.format('<text x="48" y="550" font-family="monospace" font-size="14" fill="%s">Real preview buffer from MariaDB docker. ]c/[c cells, ]r/[r rows, E edits by primary key.</text>', colors.muted),
}, "\n"))

svg(out_dir .. "/inspect-buffer.svg", 1180, 620, table.concat({
  string.format('<text x="48" y="66" font-family="monospace" font-size="16" fill="%s">DBClient Inspect - shop</text>', colors.title),
  text_lines(inspect_lines, 48, 106, { size = 15, step = 28, limit = 16 }),
  string.format('<text x="48" y="550" font-family="monospace" font-size="14" fill="%s">Real inspect buffer from MariaDB docker. gs opens this from the object tree.</text>', colors.muted),
}, "\n"))

vim.cmd("qa")

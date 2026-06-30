local M = {
  ns = vim.api.nvim_create_namespace("dbclient.ui"),
}

local links = {
  DBClientTitle = "Title",
  DBClientHeader = "Statement",
  DBClientSeparator = "Comment",
  DBClientSchema = "Type",
  DBClientTable = "Identifier",
  DBClientColumn = "Special",
  DBClientRoutine = "Function",
  DBClientNull = "Comment",
  DBClientKey = "Constant",
  DBClientAltRow = "CursorLine",
}

function M.setup()
  for group, link in pairs(links) do
    vim.cmd("highlight default link " .. group .. " " .. link)
  end
end

function M.clear(buf)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
end

function M.sidebar(buf, nodes)
  M.setup()
  M.clear(buf)

  for index, node in ipairs(nodes) do
    local line = index - 1
    if node.kind == "schema" then
      vim.api.nvim_buf_add_highlight(buf, M.ns, "DBClientSchema", line, 0, -1)
    elseif node.kind == "table" then
      vim.api.nvim_buf_add_highlight(buf, M.ns, "DBClientTable", line, 0, -1)
    elseif node.kind == "column" then
      vim.api.nvim_buf_add_highlight(buf, M.ns, "DBClientColumn", line, 0, -1)
    elseif node.kind == "routine" then
      vim.api.nvim_buf_add_highlight(buf, M.ns, "DBClientRoutine", line, 0, -1)
    elseif node.kind == "connection" then
      vim.api.nvim_buf_add_highlight(buf, M.ns, "DBClientTitle", line, 0, -1)
    end
  end
end

function M.table(buf, line_count)
  M.setup()
  M.clear(buf)

  if line_count > 0 then
    vim.api.nvim_buf_add_highlight(buf, M.ns, "DBClientTitle", 0, 0, -1)
  end
  if line_count > 1 then
    vim.api.nvim_buf_add_highlight(buf, M.ns, "DBClientHeader", 1, 0, -1)
  end
  if line_count > 2 then
    vim.api.nvim_buf_add_highlight(buf, M.ns, "DBClientSeparator", 2, 0, -1)
  end

  for line = 3, line_count - 1 do
    if line % 2 == 1 then
      vim.api.nvim_buf_set_extmark(buf, M.ns, line, 0, {
        line_hl_group = "DBClientAltRow",
      })
    end
  end
end

function M.inspect(buf, line_count)
  M.setup()
  M.clear(buf)

  if line_count > 0 then
    vim.api.nvim_buf_add_highlight(buf, M.ns, "DBClientTitle", 0, 0, -1)
  end

  for line = 1, line_count - 1 do
    local text = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1] or ""
    if text == "columns" or text == "tables" or text == "routines" then
      vim.api.nvim_buf_add_highlight(buf, M.ns, "DBClientHeader", line, 0, -1)
    elseif text:match("^%s+[^%s]+%s+") then
      vim.api.nvim_buf_add_highlight(buf, M.ns, "DBClientColumn", line, 0, -1)
    end
  end
end

return M

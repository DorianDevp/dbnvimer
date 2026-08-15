--- Highlight groups and the namespaces used to apply them.
---
--- Everything links to a standard group by default, so DBClient inherits the
--- user's colourscheme instead of imposing colours. Connection colours are the
--- one exception: they are deliberately loud, because the whole point is that a
--- production connection should be impossible to mistake for staging.

local M = {}

M.ns = vim.api.nvim_create_namespace("dbclient")
M.ns_rows = vim.api.nvim_create_namespace("dbclient-rows")
M.ns_virt = vim.api.nvim_create_namespace("dbclient-virt")
M.ns_diag = vim.api.nvim_create_namespace("dbclient-diagnostics")

local links = {
  DBClientHeader = "Title",
  DBClientSeparator = "Comment",
  DBClientNull = "Comment",
  DBClientNumber = "Number",
  DBClientBool = "Boolean",
  DBClientTemporal = "Constant",
  DBClientBinary = "SpecialChar",
  DBClientJson = "String",
  DBClientTruncated = "WarningMsg",

  DBClientSchema = "Directory",
  DBClientTable = "Identifier",
  DBClientView = "Type",
  DBClientColumn = "Normal",
  DBClientKey = "Special",
  DBClientRoutine = "Function",
  DBClientConnection = "Title",
  DBClientConnectionActive = "String",
  DBClientDetected = "Comment",
  DBClientError = "ErrorMsg",

  DBClientHelpTitle = "Title",
  DBClientHelpKey = "Special",
  DBClientHelpText = "Comment",

  DBClientPending = "DiffChange",
  DBClientPendingAdd = "DiffAdd",
  DBClientPendingDelete = "DiffDelete",

  DBClientPlanCheap = "Comment",
  DBClientPlanWarm = "WarningMsg",
  DBClientPlanHot = "ErrorMsg",
  DBClientPlanMisestimate = "ErrorMsg",

  DBClientStripe = "CursorLine",
  DBClientFk = "Comment",
}

--- Connection colour names usable as `connections.<name>.color`.
M.colors = {
  red = { fg = "#f7768e", bold = true },
  orange = { fg = "#ff9e64", bold = true },
  yellow = { fg = "#e0af68", bold = true },
  green = { fg = "#9ece6a", bold = true },
  blue = { fg = "#7aa2f7", bold = true },
  purple = { fg = "#bb9af7", bold = true },
  cyan = { fg = "#7dcfff", bold = true },
  grey = { fg = "#787c99" },
}

function M.setup()
  for name, target in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
  for name, attributes in pairs(M.colors) do
    vim.api.nvim_set_hl(
      0,
      "DBClientConn" .. name:sub(1, 1):upper() .. name:sub(2),
      vim.tbl_extend("keep", attributes, { default = true })
    )
  end
  -- Read-only and sandbox connections get their own accents.
  vim.api.nvim_set_hl(0, "DBClientAccessRead", { link = "DBClientConnBlue", default = true })
  vim.api.nvim_set_hl(0, "DBClientAccessSandbox", { link = "DBClientConnPurple", default = true })
  vim.api.nvim_set_hl(0, "DBClientTransaction", { link = "DBClientConnOrange", default = true })
end

--- Highlight group for a connection colour name.
---@param color string|nil
---@return string
function M.connection_group(color)
  if not color or not M.colors[color] then
    return "DBClientConnection"
  end
  return "DBClientConn" .. color:sub(1, 1):upper() .. color:sub(2)
end

--- Highlight group matching a value class.
---@param class string|nil
---@return string|nil
function M.class_group(class)
  return ({
    number = "DBClientNumber",
    bool = "DBClientBool",
    temporal = "DBClientTemporal",
    binary = "DBClientBinary",
    json = "DBClientJson",
  })[class]
end

--- Apply header, separator, class and NULL highlights to a rendered grid.
---@param bufnr integer
---@param opts { header_line: integer, first_row: integer, spans: table[], columns: table[], rows: integer, nulls: table<integer, table[]>, stripes: boolean }
function M.grid(bufnr, opts)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)

  local header = opts.header_line or 0
  vim.api.nvim_buf_set_extmark(bufnr, M.ns, header, 0, {
    end_row = header + 1,
    hl_group = "DBClientHeader",
    hl_eol = true,
  })
  if header + 1 < opts.first_row then
    vim.api.nvim_buf_set_extmark(bufnr, M.ns, header + 1, 0, {
      end_row = header + 2,
      hl_group = "DBClientSeparator",
      hl_eol = true,
    })
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for index = 0, (opts.rows or 0) - 1 do
    local line = opts.first_row + index
    if line >= line_count then
      break
    end

    for column_index, span in pairs(opts.spans or {}) do
      local group = M.class_group(opts.columns[column_index] and opts.columns[column_index].class)
      if group and span.width > 0 then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, line, span.start, {
          end_col = math.min(span.finish, #(vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or "")),
          hl_group = group,
          priority = 100,
        })
      end
    end

    for _, span in ipairs((opts.nulls or {})[index + 1] or {}) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, line, span.start, {
        end_col = span.finish,
        hl_group = "DBClientNull",
        priority = 110,
      })
    end

    if opts.stripes and index % 2 == 1 then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, line, 0, {
        end_row = line + 1,
        hl_group = "DBClientStripe",
        hl_eol = true,
        priority = 1,
      })
    end
  end
end

--- Apply per-line highlights described as `{ line = 0-based, group = "..." }`.
---@param bufnr integer
---@param entries table[]
---@param namespace integer|nil
function M.lines(bufnr, entries, namespace)
  namespace = namespace or M.ns
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  local count = vim.api.nvim_buf_line_count(bufnr)
  for _, entry in ipairs(entries) do
    if entry.line < count then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, entry.line, entry.col or 0, {
        end_row = entry.end_line or (entry.line + 1),
        end_col = entry.end_col,
        hl_group = entry.group,
        hl_eol = entry.end_col == nil,
        priority = entry.priority or 100,
      })
    end
  end
end

return M

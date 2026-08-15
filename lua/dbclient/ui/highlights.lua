--- Highlight groups and the namespaces used to apply them.
---
--- The colours come from `ui.theme`, which generates them from the
--- colourscheme's own background rather than shipping a fixed set. See that
--- module for why. Two escape hatches:
---
---   `ui.theme.enabled = false`  falls back to linking every group to a stock
---                               one, which is what this used to do;
---   `ui.theme.overrides`        replaces individual roles or groups.
---
--- Either way the group *names* are stable, so anything a user has already set
--- by hand keeps working.

local M = {}

M.ns = vim.api.nvim_create_namespace("dbclient")
M.ns_rows = vim.api.nvim_create_namespace("dbclient-rows")
M.ns_virt = vim.api.nvim_create_namespace("dbclient-virt")
M.ns_diag = vim.api.nvim_create_namespace("dbclient-diagnostics")

--- The fallback, used when the generated theme is switched off.
local links = {
  DBClientHeader = "Title",
  DBClientHeaderRule = "Comment",
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
  DBClientBorder = "FloatBorder",
  DBClientFloat = "NormalFloat",
  DBClientFloatTitle = "Title",

  DBClientPending = "DiffChange",
  DBClientPendingAdd = "DiffAdd",
  DBClientPendingDelete = "DiffDelete",

  DBClientPlanCheap = "Comment",
  DBClientPlanWarm = "WarningMsg",
  DBClientPlanHot = "ErrorMsg",
  DBClientPlanMisestimate = "ErrorMsg",

  DBClientSeverityError = "DiagnosticError",
  DBClientSeverityWarn = "DiagnosticWarn",
  DBClientSeverityHint = "DiagnosticHint",
  DBClientSeverityOk = "DiagnosticOk",

  DBClientStripe = "CursorLine",
  DBClientFk = "Comment",

  DBClientAccessRead = "DiagnosticInfo",
  DBClientAccessSandbox = "Constant",
  DBClientTransaction = "WarningMsg",
}

local theme = require("dbclient.ui.theme")

--- Connection colour names usable as `connections.<name>.color`.
---
--- Generated, so they land at a known contrast on the user's actual
--- background instead of being three fixed hex values that vanish on a light
--- colourscheme.
M.colors = theme.CONNECTION_HUES

local function theme_options()
  local ok, config = pcall(require, "dbclient.config")
  if not ok or not config.options then
    return { enabled = true }
  end
  return (config.options.ui or {}).theme or { enabled = true }
end

function M.setup()
  local options = theme_options()

  if options.enabled == false then
    for name, target in pairs(links) do
      vim.api.nvim_set_hl(0, name, { link = target, default = true })
    end
    for name in pairs(M.colors) do
      vim.api.nvim_set_hl(0, "DBClientConn" .. name:sub(1, 1):upper() .. name:sub(2), {
        link = "DBClientConnection",
        default = true,
      })
    end
    return
  end

  theme.apply({
    background = options.background,
    foreground = options.foreground,
    overrides = options.overrides,
  })
end

--- Highlight group for a connection colour name.
---@param color string|nil
---@return string
function M.connection_group(color)
  if not color or M.colors[color] == nil then
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
      hl_group = "DBClientHeaderRule",
      hl_eol = true,
    })
  end

  local grid = require("dbclient.ui.grid")
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local body = vim.api.nvim_buf_get_lines(bufnr, opts.first_row, opts.first_row + (opts.rows or 0), false)

  for index = 0, (opts.rows or 0) - 1 do
    local line = opts.first_row + index
    if line >= line_count then
      break
    end

    -- Spans are measured in display cells; extmarks want bytes, and on a row
    -- holding anything outside ASCII the two are different numbers.
    local text = body[index + 1] or ""
    local spans = grid.line_spans(text, opts.spans or {})

    for column_index, span in pairs(spans) do
      local group = M.class_group(opts.columns[column_index] and opts.columns[column_index].class)
      if group and span.width > 0 then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, line, span.start, {
          end_col = math.min(span.finish, #text),
          hl_group = group,
          priority = 100,
        })
      end
    end

    for _, span in ipairs(grid.line_spans(text, (opts.nulls or {})[index + 1] or {})) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, line, span.start, {
        end_col = math.min(span.finish, #text),
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

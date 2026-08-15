--- Query history, stored as JSON lines next to the connection store.
---
--- History is a file, not a hidden database, so it can be grepped, edited and
--- deleted with ordinary tools.

local config = require("dbclient.config")

local M = {
  --- In-memory mirror, newest last.
  entries = nil,
}

local function path()
  return config.get().history.path
end

local function ensure_dir()
  local directory = vim.fs.dirname(path())
  if vim.fn.isdirectory(directory) == 0 then
    vim.fn.mkdir(directory, "p")
  end
end

--- Read the history file once and keep it in memory.
---@return table[]
function M.load()
  if M.entries then
    return M.entries
  end

  M.entries = {}
  local file = path()
  if vim.fn.filereadable(file) ~= 1 then
    return M.entries
  end

  for _, line in ipairs(vim.fn.readfile(file)) do
    if line ~= "" then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and type(entry) == "table" and entry.sql then
        table.insert(M.entries, entry)
      end
    end
  end
  return M.entries
end

--- Append a statement to the history.
---@param connection string
---@param sql string
function M.record(connection, sql)
  if not config.get().history.enabled then
    return
  end
  sql = vim.trim(sql or "")
  if sql == "" then
    return
  end

  local entries = M.load()
  local last = entries[#entries]
  if last and last.sql == sql and last.connection == connection then
    return
  end

  local entry = { sql = sql, connection = connection, at = os.time() }
  table.insert(entries, entry)

  local limit = config.get().history.limit
  if #entries > limit then
    M.entries = vim.list_slice(entries, #entries - limit + 1)
    return M.flush()
  end

  ensure_dir()
  pcall(function()
    local handle = io.open(path(), "a")
    if handle then
      handle:write(vim.json.encode(entry) .. "\n")
      handle:close()
    end
  end)
end

--- Rewrite the whole file from memory, used after trimming.
function M.flush()
  ensure_dir()
  local lines = {}
  for _, entry in ipairs(M.entries or {}) do
    table.insert(lines, vim.json.encode(entry))
  end
  pcall(vim.fn.writefile, lines, path())
end

function M.clear()
  M.entries = {}
  M.flush()
end

--- History entries, newest first, most recent duplicates collapsed.
---@param connection string|nil  restrict to one connection
---@return table[]
function M.recent(connection)
  local entries = M.load()
  local seen = {}
  local result = {}
  for index = #entries, 1, -1 do
    local entry = entries[index]
    if not connection or entry.connection == connection then
      if not seen[entry.sql] then
        seen[entry.sql] = true
        table.insert(result, entry)
      end
    end
  end
  return result
end

--- One-line label for a picker.
---@param entry table
---@return string
function M.label(entry)
  local sql = entry.sql:gsub("%s+", " ")
  if #sql > 90 then
    sql = sql:sub(1, 89) .. "…"
  end
  return ("%s  %s  %s"):format(os.date("%m-%d %H:%M", entry.at or 0), entry.connection or "?", sql)
end

return M

local config = require("dbclient.config")

local M = {}

local function command_path()
  return config.get().core.command
end

local function encode(payload)
  return vim.json.encode(payload or {})
end

local function decode(text)
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok then
    error("dbclient-core returned invalid JSON: " .. text)
  end
  return decoded
end

function M.run(command, payload)
  local result = vim.system({ command_path(), command }, {
    stdin = encode(payload),
    text = true,
  }):wait()

  local response = decode(result.stdout or "")
  if result.code ~= 0 or response.ok == false then
    error(response.error or result.stderr or "dbclient-core failed")
  end
  return response.data
end

return M

--- Winbar and statusline components.
---
--- The winbar is where a production connection announces itself. Colouring
--- every buffer bound to a connection is cheap and it is the single most
--- effective guard against running the right statement against the wrong
--- database.

local client = require("dbclient.core.client")
local config = require("dbclient.config")
local highlights = require("dbclient.ui.highlights")
local session = require("dbclient.session")

local M = {
  --- bufnr -> session id
  bound = {},
  spinner_index = 1,
  timer = nil,
}

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- Bind a buffer to a session so its winbar shows that connection.
---@param bufnr integer
---@param session_id string|nil
function M.bind(bufnr, session_id)
  M.bound[bufnr] = session_id
  M.attach(bufnr)
end

---@param bufnr integer
---@return string|nil
function M.session_id(bufnr)
  return M.bound[bufnr]
end

--- The session a buffer belongs to, falling back to the active one.
---@param bufnr integer|nil
---@return table|nil
function M.session_for(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local id = M.bound[bufnr]
  if id and session.sessions[id] then
    return session.sessions[id]
  end
  return session.current()
end

local function segment(text, group)
  if not group then
    return text
  end
  return ("%%#%s#%s%%*"):format(group, text)
end

--- Build the winbar text for a buffer.
---@param bufnr integer
---@return string
function M.render(bufnr)
  local target = M.session_for(bufnr)
  if not target then
    return segment(" no connection ", "DBClientDetected")
  end

  local parts = {}
  local color_group = highlights.connection_group(target.color)
  table.insert(parts, segment((" %s "):format(target.name), color_group))

  local access = target.spec and target.spec.access or "write"
  if access == "read" then
    table.insert(parts, segment(" read-only ", "DBClientAccessRead"))
  elseif access == "sandbox" then
    table.insert(parts, segment(" sandbox ", "DBClientAccessSandbox"))
  end

  if target.in_transaction then
    table.insert(parts, segment(" TX ", "DBClientTransaction"))
  end

  if target.info and target.info.database then
    table.insert(parts, segment((" %s "):format(target.info.database), "DBClientSchema"))
  end

  local pending = client.in_flight()
  if pending > 0 then
    table.insert(
      parts,
      segment((" %s running "):format(SPINNER[M.spinner_index]), "DBClientTruncated")
    )
  end

  return table.concat(parts)
end

--- Attach the winbar to a buffer's windows.
---@param bufnr integer
function M.attach(bufnr)
  if not config.get().ui.winbar then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      pcall(function()
        vim.wo[win].winbar = "%{%v:lua.require'dbclient.ui.winbar'.render(bufnr())%}"
      end)
    end
  end
end

--- Component for user statuslines (lualine and friends).
---@return string
function M.statusline()
  local target = session.current()
  if not target then
    return ""
  end

  local parts = { target.name }
  local access = target.spec and target.spec.access or "write"
  if access ~= "write" then
    table.insert(parts, access)
  end
  if target.in_transaction then
    table.insert(parts, "TX")
  end
  local pending = client.in_flight()
  if pending > 0 then
    table.insert(parts, SPINNER[M.spinner_index])
  end
  return "󰆼 " .. table.concat(parts, " · ")
end

--- Advance the spinner while requests are in flight and redraw.
function M.start_spinner()
  if M.timer then
    return
  end
  M.timer = vim.uv.new_timer()
  M.timer:start(
    0,
    100,
    vim.schedule_wrap(function()
      if client.in_flight() == 0 then
        M.stop_spinner()
        vim.cmd.redrawstatus()
        return
      end
      M.spinner_index = (M.spinner_index % #SPINNER) + 1
      vim.cmd.redrawstatus()
    end)
  )
end

function M.stop_spinner()
  if M.timer then
    M.timer:stop()
    M.timer:close()
    M.timer = nil
  end
end

--- Refresh every bound buffer, e.g. after a transaction state change.
function M.refresh()
  for bufnr in pairs(M.bound) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      M.attach(bufnr)
    else
      M.bound[bufnr] = nil
    end
  end
  pcall(vim.cmd.redrawstatus)
end

return M

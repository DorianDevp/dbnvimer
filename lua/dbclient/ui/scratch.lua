--- The quick query tab.
---
--- Open it, type, press `<CR>`, read the rows. Nothing is named, nothing is
--- saved, nothing is in the way — the point is the shortest path from a
--- question to an answer. A tab page rather than a split because the results
--- want room, and because `:tabclose` puts your layout back exactly.
---
--- When a question turns out to be worth keeping, `gs` promotes it to a saved
--- query without retyping it.

local buffer = require("dbclient.ui.buffer")
local help = require("dbclient.ui.help")
local keymap = require("dbclient.keymap")
local queries = require("dbclient.queries")
local results = require("dbclient.ui.results")
local session = require("dbclient.session")
local winbar = require("dbclient.ui.winbar")

local M = {
  --- session id -> tabpage handle
  tabs = {},
  --- session id -> query bufnr
  buffers = {},
}

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

local PLACEHOLDER = {
  "-- Quick query. <CR> runs the statement under the cursor.",
  "-- gs saves it, gf opens a saved one, q closes the tab.",
  "",
  "",
}

---@param session_id string
---@return integer|nil
local function live_tab(session_id)
  local handle = M.tabs[session_id]
  if handle and vim.api.nvim_tabpage_is_valid(handle) then
    return handle
  end
  M.tabs[session_id] = nil
  return nil
end

--- The query buffer of the scratch tab, if the cursor is in one.
---@return integer|nil bufnr, string|nil session_id
function M.current()
  local bufnr = vim.api.nvim_get_current_buf()
  for session_id, candidate in pairs(M.buffers) do
    if candidate == bufnr then
      return bufnr, session_id
    end
  end
  return nil, nil
end

--- Open or focus the quick query tab.
---@param opts? { session_id?: string, sql?: string }
function M.open(opts)
  opts = opts or {}
  local target = session.get(opts.session_id)
  if not target then
    notify("no active connection; run :DBClientConnect", vim.log.levels.WARN)
    return
  end

  local existing = live_tab(target.id)
  if existing then
    vim.api.nvim_set_current_tabpage(existing)
    local bufnr = M.buffers[target.id]
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      buffer.focus(bufnr)
      if opts.sql then
        M.replace(bufnr, opts.sql)
      end
    end
    return bufnr
  end

  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  M.tabs[target.id] = tabpage

  local name = ("dbclient://%s/quick.sql"):format(target.name)
  local bufnr = buffer.scratch(name, { modifiable = true, buftype = "nofile" })
  vim.bo[bufnr].filetype = "sql"
  vim.bo[bufnr].bufhidden = "hide"
  M.buffers[target.id] = bufnr

  vim.api.nvim_win_set_buf(0, bufnr)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines <= 1 and (lines[1] or "") == "" then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, PLACEHOLDER)
  end

  winbar.bind(bufnr, target.id)
  M.attach(bufnr, target.id)

  if opts.sql then
    M.replace(bufnr, opts.sql)
  end

  -- Land on the first empty line so typing starts immediately.
  local count = vim.api.nvim_buf_line_count(bufnr)
  pcall(vim.api.nvim_win_set_cursor, 0, { count, 0 })

  notify(("quick query on %s"):format(target.name))
  return bufnr
end

--- Replace the buffer contents, keeping the header comment.
---@param bufnr integer
---@param sql string
function M.replace(bufnr, sql)
  local lines = {}
  vim.list_extend(lines, vim.split(sql, "\n"))
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  pcall(vim.api.nvim_win_set_cursor, 0, { 1, 0 })
end

---@param session_id string
function M.close(session_id)
  local handle = live_tab(session_id)
  if handle and #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.api.nvim_tabpage_del_var, handle, "dbclient_scratch")
    vim.api.nvim_set_current_tabpage(handle)
    vim.cmd("tabclose")
  end
  M.tabs[session_id] = nil
end

--- Run the statement under the cursor and show the rows below it.
---@param session_id string
local function execute(session_id)
  local query = require("dbclient.ui.query")
  -- The query module owns statement detection, guards and history; binding the
  -- buffer to the session is all that is needed to reuse it.
  query.buffers[vim.api.nvim_get_current_buf()] = { session_id = session_id }
  query.execute()
end

--- Attach the quick-query mappings.
---@param bufnr integer
---@param session_id string
function M.attach(bufnr, session_id)
  local query = require("dbclient.ui.query")
  query.buffers[bufnr] = { session_id = session_id }
  query.attach(bufnr)

  keymap.apply("scratch", bufnr, {
    execute = function()
      execute(session_id)
    end,
    execute_buffer = function()
      query.buffers[bufnr] = { session_id = session_id }
      query.execute_buffer()
    end,
    save = function()
      M.save(bufnr, session_id)
    end,
    saved_queries = function()
      require("dbclient.ui.queries").open({ session_id = session_id })
    end,
    pick_connection = function()
      local sessions = session.list()
      if #sessions < 2 then
        return notify("only one connection is open")
      end
      vim.ui.select(sessions, {
        prompt = "run against",
        format_item = function(entry)
          return entry.name
        end,
      }, function(choice)
        if choice then
          query.buffers[bufnr] = { session_id = choice.id }
          winbar.bind(bufnr, choice.id)
          notify("quick query now runs on " .. choice.name)
        end
      end)
    end,
    close = function()
      M.close(session_id)
    end,
    help = help.handler("scratch"),
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      M.buffers[session_id] = nil
    end,
  })
end

--- Promote whatever is in the buffer to a saved query.
---@param bufnr integer
---@param session_id string
function M.save(bufnr, session_id)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- Drop the placeholder header so it does not get saved with the query.
  local body = {}
  for _, line in ipairs(lines) do
    if not line:match("^%-%-%s*Quick query") and not line:match("^%-%-%s*gs saves") then
      table.insert(body, line)
    end
  end

  local target = session.get(session_id)
  queries.prompt_save({
    sql = vim.trim(table.concat(body, "\n")),
    connection = target and target.name,
  })
end

--- Toggle: open the tab, or leave it if you are already in it.
---@param opts? { session_id?: string }
function M.toggle(opts)
  opts = opts or {}
  local _, current_session = M.current()
  if current_session then
    return M.close(current_session)
  end
  M.open(opts)
end

return M

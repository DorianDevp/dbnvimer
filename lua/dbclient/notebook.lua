--- Executable SQL blocks inside a Markdown buffer.
---
--- An analysis is usually prose plus queries plus their answers, and keeping
--- the three together in a file you can commit is more useful than a scratch
--- buffer you lose. `<CR>` on a ```sql block runs it and writes the result back
--- underneath as a folded block, so the document stays readable and the numbers
--- stay attached to the question that produced them.

local client = require("dbclient.core.client")
local export = require("dbclient.export")
local session = require("dbclient.session")

local M = {}

local RESULT_OPEN = "<!-- dbclient:result -->"
local RESULT_CLOSE = "<!-- dbclient:end -->"

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

--- Find the fenced block containing `line` (1-based).
---@param bufnr integer
---@param line integer
---@return { first: integer, last: integer, language: string, sql: string }|nil
function M.block_at(bufnr, line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local first
  for index = line, 1, -1 do
    local fence = lines[index] and lines[index]:match("^```%s*(%S*)")
    if fence then
      -- A closing fence above us means we are between blocks.
      if fence == "" and index < line then
        return nil
      end
      first = index
      break
    end
  end
  if not first then
    return nil
  end

  local language = lines[first]:match("^```%s*(%S*)") or ""
  if language:lower() ~= "sql" then
    return nil
  end

  local last
  for index = first + 1, #lines do
    if lines[index]:match("^```") then
      last = index
      break
    end
  end
  if not last or last < line then
    return nil
  end

  return {
    first = first,
    last = last,
    language = language,
    sql = table.concat(vim.list_slice(lines, first + 1, last - 1), "\n"),
  }
end

--- Remove a previously written result that follows the block.
---@param bufnr integer
---@param after integer  1-based line of the closing fence
---@return integer  line after which the new result should go
local function clear_result(bufnr, after)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local start
  for index = after + 1, math.min(after + 3, #lines) do
    if lines[index] == RESULT_OPEN then
      start = index
      break
    end
    if lines[index] and lines[index]:match("%S") then
      break
    end
  end
  if not start then
    return after
  end

  for index = start, #lines do
    if lines[index] == RESULT_CLOSE then
      vim.api.nvim_buf_set_lines(bufnr, start - 1, index, false, {})
      return after
    end
  end
  return after
end

--- Format a result set for insertion under a block.
---@param result table
---@param sql string
---@return string[]
local function result_lines(result, sql)
  local lines = { RESULT_OPEN }

  if #(result.columns or {}) == 0 then
    table.insert(lines, ("`%d row(s) affected in %d ms`"):format(
      result.affected_rows or 0,
      result.elapsed_ms or 0
    ))
  else
    table.insert(lines, ("`%d row(s) in %d ms`"):format(
      #(result.rows or {}),
      result.elapsed_ms or 0
    ))
    table.insert(lines, "")
    vim.list_extend(lines, export.render(result, "markdown"))
    if result.truncated then
      table.insert(lines, "")
      table.insert(lines, "_truncated_")
    end
  end

  for _, notice in ipairs(result.notices or {}) do
    table.insert(lines, "")
    table.insert(lines, "> " .. notice)
  end

  table.insert(lines, RESULT_CLOSE)
  return lines
end

--- Run the SQL block under the cursor and write the result underneath.
function M.run_block()
  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1]

  local block = M.block_at(bufnr, line)
  if not block then
    return notify("the cursor is not inside a ```sql block", vim.log.levels.WARN)
  end
  if not block.sql:match("%S") then
    return notify("the block is empty", vim.log.levels.WARN)
  end

  local target = M.session_for(bufnr)
  if not target then
    return notify("no connection; add `-- @conn: name` or connect first", vim.log.levels.WARN)
  end

  notify("running...")

  client.async(function()
    local result = session.query(target.id, block.sql, 500)
    local insert_at = clear_result(bufnr, block.last)
    vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, result_lines(result, block.sql))
    notify(("%d row(s) in %d ms"):format(#(result.rows or {}), result.elapsed_ms or 0))
  end, function(err)
    local insert_at = clear_result(bufnr, block.last)
    vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, {
      RESULT_OPEN,
      "```",
      "error: " .. tostring(err),
      "```",
      RESULT_CLOSE,
    })
    notify(err, vim.log.levels.ERROR)
  end)
end

--- Every ```sql block in the buffer, in order.
---
--- Found in one pass: asking `block_at` about each line in turn re-read the
--- whole buffer per line, which is quadratic on a document of any size.
---@param bufnr integer
---@return { first: integer, last: integer, sql: string }[]
function M.blocks(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blocks = {}
  local open = nil
  local language = nil

  for index, line in ipairs(lines) do
    local fence = line:match("^```%s*(%S*)")
    if fence ~= nil then
      if open then
        if language:lower() == "sql" then
          table.insert(blocks, {
            first = open,
            last = index,
            sql = table.concat(vim.list_slice(lines, open + 1, index - 1), "\n"),
          })
        end
        open, language = nil, nil
      else
        open, language = index, fence
      end
    end
  end

  return blocks
end

--- Run every SQL block in the buffer, top to bottom.
function M.run_all()
  local bufnr = vim.api.nvim_get_current_buf()
  local target = M.session_for(bufnr)
  if not target then
    return notify("no connection for this notebook", vim.log.levels.WARN)
  end

  client.async(function()
    local ran = 0
    local processed = 0

    -- Re-scan after each block, because writing a result shifts every line
    -- below it; `processed` keeps the walk moving forward.
    while true do
      local blocks = M.blocks(bufnr)
      local block = blocks[processed + 1]
      if not block then
        break
      end

      local ok, result = pcall(session.query, target.id, block.sql, 500)
      local insert_at = clear_result(bufnr, block.last)
      local body = ok and result_lines(result, block.sql)
        or { RESULT_OPEN, "```", "error: " .. tostring(result), "```", RESULT_CLOSE }
      vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, body)

      ran = ran + 1
      processed = processed + 1
    end
    notify(("ran %d block(s)"):format(ran))
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

--- Strip every generated result from the buffer.
function M.clear_all()
  local bufnr = vim.api.nvim_get_current_buf()
  while true do
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local start
    for index, text in ipairs(lines) do
      if text == RESULT_OPEN then
        start = index
        break
      end
    end
    if not start then
      break
    end
    local stop
    for index = start, #lines do
      if lines[index] == RESULT_CLOSE then
        stop = index
        break
      end
    end
    if not stop then
      break
    end
    vim.api.nvim_buf_set_lines(bufnr, start - 1, stop, false, {})
  end
  notify("results cleared")
end

--- Which connection this notebook uses: a `-- @conn:` or `<!-- @conn: -->`
--- header, otherwise the active session.
---@param bufnr integer
---@return table|nil
function M.session_for(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 20, false)
  for _, line in ipairs(lines) do
    local name = line:match("@conn:%s*([%w_%-.:]+)")
    if name then
      local target = session.find_by_name(name)
      if target then
        return target
      end
      notify(("`%s` is named in this notebook but is not connected"):format(name), vim.log.levels.WARN)
      return session.current()
    end
  end
  return session.current()
end

--- Attach the notebook mappings to a markdown buffer.
---@param bufnr integer
function M.attach(bufnr)
  local options = { buffer = bufnr, silent = true }

  vim.keymap.set("n", "<CR>", function()
    -- Only take over `<CR>` inside a SQL block; elsewhere it stays itself.
    if M.block_at(bufnr, vim.api.nvim_win_get_cursor(0)[1]) then
      return M.run_block()
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
  end, vim.tbl_extend("force", options, { desc = "DBClient: run the SQL block" }))

  vim.keymap.set(
    "n",
    "<leader>dQ",
    M.run_all,
    vim.tbl_extend("force", options, { desc = "DBClient: run every SQL block" })
  )
  vim.keymap.set(
    "n",
    "<leader>dX",
    M.clear_all,
    vim.tbl_extend("force", options, { desc = "DBClient: clear notebook results" })
  )

  vim.b[bufnr].dbclient_notebook = true
  notify("notebook mode: <CR> runs the block under the cursor")
end

--- Turn the current markdown buffer into a notebook.
function M.enable()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "markdown" then
    vim.bo[bufnr].filetype = "markdown"
  end
  M.attach(bufnr)
end

M.RESULT_OPEN = RESULT_OPEN
M.RESULT_CLOSE = RESULT_CLOSE

return M

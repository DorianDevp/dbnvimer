--- Navigation history for data buffers.
---
--- Following a foreign key is a move through a graph, and a graph walk needs
--- more than "go back one step". This keeps a browser-style trail: every place
--- you land is an entry, going back moves a cursor rather than discarding
--- history, and navigating from a rewound position truncates the forward branch
--- the way a browser does.
---
--- Entries are places, not buffers — a place is a table plus the filter, sort
--- and page you were looking at — so returning to one reconstructs the view
--- rather than hoping the buffer still exists.

local M = {
  ---@type table[]
  entries = {},
  --- 1-based position within `entries`; 0 when the trail is empty.
  index = 0,
  --- Set while restoring so a restore does not itself push an entry.
  restoring = false,
  limit = 100,
}

--- Short human label for an entry, e.g. `shop.orders[customer_id=4]`.
---@param entry table
---@return string
function M.label(entry)
  local label = ("%s.%s"):format(entry.schema, entry.table)
  if entry.filter and entry.filter ~= "" then
    local filter = entry.filter:gsub("%s+", " ")
    if #filter > 28 then
      filter = filter:sub(1, 27) .. "…"
    end
    label = ("%s[%s]"):format(label, filter)
  end
  return label
end

--- True when two entries describe the same place.
local function same_place(a, b)
  if not a or not b then
    return false
  end
  return a.session_id == b.session_id
    and a.schema == b.schema
    and a.table == b.table
    and (a.filter or "") == (b.filter or "")
end

--- Record a place.
---
--- Called by the data buffer whenever it opens or re-opens a view. Re-opening
--- the place you are already on updates it in place instead of stacking a
--- duplicate, which is what makes paging and sorting not pollute the trail.
---@param entry table
function M.push(entry)
  if M.restoring then
    return
  end

  entry = vim.deepcopy(entry)
  entry.at = os.time()

  local current = M.entries[M.index]
  if same_place(current, entry) then
    M.entries[M.index] = entry
    return
  end

  -- Navigating from a rewound position drops what was ahead.
  for position = #M.entries, M.index + 1, -1 do
    table.remove(M.entries, position)
  end

  table.insert(M.entries, entry)
  M.index = #M.entries

  while #M.entries > M.limit do
    table.remove(M.entries, 1)
    M.index = M.index - 1
  end
end

---@return table|nil
function M.current()
  return M.entries[M.index]
end

---@return boolean
function M.can_go_back()
  return M.index > 1
end

---@return boolean
function M.can_go_forward()
  return M.index < #M.entries
end

--- Move the cursor and return the entry to restore.
---@param delta integer  negative goes back
---@return table|nil entry, string|nil err
function M.step(delta)
  if #M.entries == 0 then
    return nil, "the trail is empty"
  end

  local target = M.index + delta
  if target < 1 then
    if M.index == 1 then
      return nil, "already at the start of the trail"
    end
    target = 1
  end
  if target > #M.entries then
    if M.index == #M.entries then
      return nil, "already at the end of the trail"
    end
    target = #M.entries
  end

  M.index = target
  return M.entries[M.index], nil
end

--- Jump straight to a position, which is what the breadcrumb picker does.
---@param position integer
---@return table|nil entry, string|nil err
function M.goto_index(position)
  if not M.entries[position] then
    return nil, "no such position in the trail"
  end
  M.index = position
  return M.entries[position], nil
end

--- Render the trail as a breadcrumb, eliding the middle when it is long.
---@param opts? { width?: integer, separator?: string }
---@return string
function M.breadcrumb(opts)
  opts = opts or {}
  local separator = opts.separator or " › "
  local width = opts.width

  if #M.entries == 0 then
    return ""
  end

  local labels = {}
  for position, entry in ipairs(M.entries) do
    local label = M.label(entry)
    if position == M.index then
      label = "[" .. label .. "]"
    end
    table.insert(labels, label)
  end

  local rendered = table.concat(labels, separator)
  if not width or vim.fn.strdisplaywidth(rendered) <= width then
    return rendered
  end

  -- Keep the current position and its neighbours; elide the rest.
  local keep = {}
  for position = math.max(1, M.index - 1), math.min(#labels, M.index + 1) do
    table.insert(keep, labels[position])
  end
  local short = table.concat(keep, separator)
  if M.index - 1 > 1 then
    short = "…" .. separator .. short
  end
  if M.index + 1 < #labels then
    short = short .. separator .. "…"
  end
  return short
end

--- The trail as picker entries, newest last, with the current one marked.
---@return table[]
function M.list()
  local list = {}
  for position, entry in ipairs(M.entries) do
    table.insert(list, {
      position = position,
      entry = entry,
      current = position == M.index,
      label = ("%s%2d  %s%s"):format(
        position == M.index and "▸ " or "  ",
        position,
        M.label(entry),
        entry.via and ("   via %s"):format(entry.via) or ""
      ),
    })
  end
  return list
end

function M.clear()
  M.entries = {}
  M.index = 0
end

--- Reopen a recorded place.
---
--- Restoration goes through the data buffer, but the flag is owned here so
--- every caller gets the same protection against the restore re-pushing.
---@param entry table
function M.restore(entry)
  if not entry then
    return
  end

  local session = require("dbclient.session")
  if not session.get(entry.session_id) then
    vim.notify(
      ("DBClient: %s is no longer connected"):format(entry.connection or "that connection"),
      vim.log.levels.WARN
    )
    return
  end

  M.restoring = true
  -- An empty string clears the filter, whereas nil would leave whatever the
  -- buffer had. Going back to an unfiltered view has to actually be unfiltered.
  require("dbclient.ui.data").open({
    session_id = entry.session_id,
    schema = entry.schema,
    table = entry.table,
    filter = entry.filter or "",
    sort = entry.sort or {},
    limit = entry.limit,
    offset = entry.offset or 0,
  })

  -- The open is asynchronous; release the guard once it has settled.
  vim.defer_fn(function()
    M.restoring = false
    if entry.cursor then
      pcall(vim.api.nvim_win_set_cursor, 0, entry.cursor)
    end
  end, 300)
end

--- Go back `count` places.
---@param count integer|nil
function M.back(count)
  local entry, err = M.step(-(count or vim.v.count1 or 1))
  if err then
    return vim.notify("DBClient: " .. err, vim.log.levels.INFO)
  end
  M.restore(entry)
end

--- Go forward `count` places.
---@param count integer|nil
function M.forward(count)
  local entry, err = M.step(count or vim.v.count1 or 1)
  if err then
    return vim.notify("DBClient: " .. err, vim.log.levels.INFO)
  end
  M.restore(entry)
end

--- Pick any point on the trail.
function M.pick()
  local list = M.list()
  if #list == 0 then
    return vim.notify("DBClient: nothing on the trail yet")
  end

  vim.ui.select(list, {
    prompt = "trail",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    local entry = M.goto_index(choice.position)
    M.restore(entry)
  end)
end

return M

--- Saved queries, stored as ordinary `.sql` files.
---
--- A saved query is a file with a small header, kept either next to the project
--- (`.dbclient/queries/`, committable, shared with the team) or globally
--- (`stdpath("data")/dbclient/queries/`, yours alone). Being files means they
--- grep, diff, review and version like the rest of the repository, which a
--- proprietary store never does.
---
---   -- @name: overdue invoices
---   -- @conn: staging
---   -- @desc: everything unpaid past its due date
---   -- @tags: billing, support
---
---   select * from invoices where paid_at is null and due_at < now();

local config = require("dbclient.config")

local M = {}

local HEADERS = { "name", "conn", "desc", "tags" }

--- Where saved queries live, in lookup order.
---@return { scope: string, path: string }[]
function M.directories()
  local project = vim.fs.find(".dbclient", {
    upward = true,
    path = vim.uv.cwd(),
    type = "directory",
    limit = 1,
  })[1]

  local list = {}
  if project then
    table.insert(list, { scope = "project", path = project .. "/queries" })
  else
    table.insert(list, { scope = "project", path = vim.uv.cwd() .. "/.dbclient/queries" })
  end
  table.insert(list, {
    scope = "global",
    path = vim.fs.dirname(config.get().history.path) .. "/queries",
  })
  return list
end

---@param scope string
---@return string
function M.directory(scope)
  for _, entry in ipairs(M.directories()) do
    if entry.scope == scope then
      return entry.path
    end
  end
  return M.directories()[1].path
end

--- Parse the header block at the top of a saved query.
---@param lines string[]
---@return table meta, string[] body
function M.parse(lines)
  local meta = {}
  local first_body = 1

  for index, line in ipairs(lines) do
    local key, value = line:match("^%s*%-%-%s*@([%w_]+):%s*(.-)%s*$")
    if key and vim.tbl_contains(HEADERS, key) then
      meta[key] = value
      first_body = index + 1
    elseif line:match("%S") then
      break
    else
      first_body = index + 1
    end
  end

  local body = {}
  for index = first_body, #lines do
    table.insert(body, lines[index])
  end

  -- Trim leading blank lines from the body so re-saving does not accumulate.
  while body[1] and not body[1]:match("%S") do
    table.remove(body, 1)
  end

  if meta.tags then
    local tags = {}
    for tag in meta.tags:gmatch("[^,]+") do
      table.insert(tags, vim.trim(tag))
    end
    meta.tags = tags
  end

  return meta, body
end

--- Render a query back to file lines.
---@param entry table
---@return string[]
function M.render(entry)
  local lines = {}
  if entry.name then
    table.insert(lines, ("-- @name: %s"):format(entry.name))
  end
  if entry.connection and entry.connection ~= "" then
    table.insert(lines, ("-- @conn: %s"):format(entry.connection))
  end
  if entry.description and entry.description ~= "" then
    table.insert(lines, ("-- @desc: %s"):format(entry.description))
  end
  if entry.tags and #entry.tags > 0 then
    table.insert(lines, ("-- @tags: %s"):format(table.concat(entry.tags, ", ")))
  end
  table.insert(lines, "")
  vim.list_extend(lines, vim.split(entry.sql or "", "\n"))
  return lines
end

--- A file name derived from the query name, kept readable and safe.
---@param name string
---@return string
function M.slug(name)
  local slug = name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if slug == "" then
    slug = "query"
  end
  return slug
end

--- Every saved query, project scope first.
---@return table[]
function M.list()
  local entries = {}

  for _, directory in ipairs(M.directories()) do
    for _, path in ipairs(vim.fn.glob(directory.path .. "/*.sql", false, true)) do
      local ok, lines = pcall(vim.fn.readfile, path)
      if ok then
        local meta, body = M.parse(lines)
        local stat = vim.uv.fs_stat(path)
        table.insert(entries, {
          name = meta.name or vim.fn.fnamemodify(path, ":t:r"),
          connection = meta.conn,
          description = meta.desc,
          tags = meta.tags or {},
          sql = table.concat(body, "\n"),
          path = path,
          scope = directory.scope,
          at = stat and stat.mtime.sec or 0,
        })
      end
    end
  end

  table.sort(entries, function(a, b)
    if a.scope ~= b.scope then
      return a.scope == "project"
    end
    return a.name:lower() < b.name:lower()
  end)

  return entries
end

---@param name string
---@return table|nil
function M.find(name)
  for _, entry in ipairs(M.list()) do
    if entry.name == name then
      return entry
    end
  end
end

--- Write a query to disk.
---@param entry { name: string, sql: string, connection?: string, description?: string, tags?: string[], scope?: string, path?: string }
---@return string|nil path, string|nil err
function M.save(entry)
  if not entry.name or entry.name == "" then
    return nil, "a saved query needs a name"
  end
  if not entry.sql or not entry.sql:match("%S") then
    return nil, "there is no SQL to save"
  end

  local scope = entry.scope or "global"
  local directory = M.directory(scope)
  vim.fn.mkdir(directory, "p")

  local path = entry.path or ("%s/%s.sql"):format(directory, M.slug(entry.name))
  local ok, err = pcall(vim.fn.writefile, M.render(entry), path)
  if not ok then
    return nil, tostring(err)
  end
  return path
end

---@param path string
---@return boolean ok, string|nil err
function M.delete(path)
  if vim.fn.filereadable(path) ~= 1 then
    return false, "no such saved query"
  end
  local ok = vim.fn.delete(path) == 0
  return ok, ok and nil or "could not delete the file"
end

---@param entry table
---@param new_name string
---@return string|nil path, string|nil err
function M.rename(entry, new_name)
  -- `vim.tbl_extend` drops keys whose value is nil, so the old path has to be
  -- cleared explicitly or `save` would write straight back over it.
  local updated = vim.tbl_extend("force", {}, entry)
  updated.name = new_name
  updated.path = nil

  local path, err = M.save(updated)
  if not path then
    return nil, err
  end
  if path ~= entry.path then
    M.delete(entry.path)
  end
  return path
end

--- Move a query between the project and the global store.
---@param entry table
---@return string|nil path, string|nil err
function M.promote(entry)
  local moved = vim.tbl_extend("force", {}, entry)
  moved.scope = entry.scope == "project" and "global" or "project"
  moved.path = nil

  local path, err = M.save(moved)
  if not path then
    return nil, err
  end
  M.delete(entry.path)
  return path
end

--- Prompt for the metadata and save.
---@param opts { sql: string, connection?: string, on_saved?: fun(path: string) }
function M.prompt_save(opts)
  if not opts.sql or not opts.sql:match("%S") then
    return vim.notify("DBClient: nothing to save", vim.log.levels.WARN)
  end

  vim.ui.input({ prompt = "query name " }, function(name)
    if not name or name == "" then
      return
    end
    vim.ui.input({ prompt = "description (optional) " }, function(description)
      vim.ui.select({ "project", "global" }, { prompt = "save where" }, function(scope)
        if not scope then
          return
        end
        local path, err = M.save({
          name = name,
          sql = opts.sql,
          connection = opts.connection,
          description = description,
          scope = scope,
        })
        if not path then
          return vim.notify("DBClient: " .. tostring(err), vim.log.levels.ERROR)
        end
        vim.notify(("DBClient: saved `%s` to %s"):format(name, path))
        if opts.on_saved then
          opts.on_saved(path)
        end
      end)
    end)
  end)
end

return M

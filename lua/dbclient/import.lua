--- CSV import.
---
--- The column mapping is edited as text and confirmed with `:w`, the same
--- gesture as everywhere else. Rows are inserted through the same change-set
--- path as the data buffer, so the type coercion, the NULL handling and the
--- single surrounding transaction are all shared rather than reimplemented.

local buffer = require("dbclient.ui.buffer")
local client = require("dbclient.core.client")
local session = require("dbclient.session")

local M = {
  --- bufnr -> job
  jobs = {},
}

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

--- Split one CSV line, honouring quotes and doubled quotes.
---@param line string
---@param separator string
---@return string[]
function M.split_line(line, separator)
  local fields = {}
  local current = {}
  local index = 1
  local quoted = false

  while index <= #line do
    local char = line:sub(index, index)
    if quoted then
      if char == '"' then
        if line:sub(index + 1, index + 1) == '"' then
          table.insert(current, '"')
          index = index + 2
        else
          quoted = false
          index = index + 1
        end
      else
        table.insert(current, char)
        index = index + 1
      end
    elseif char == '"' and #current == 0 then
      quoted = true
      index = index + 1
    elseif char == separator then
      table.insert(fields, table.concat(current))
      current = {}
      index = index + 1
    else
      table.insert(current, char)
      index = index + 1
    end
  end

  table.insert(fields, table.concat(current))
  return fields
end

--- Read a delimited file into a header plus rows.
---
--- Quoted fields may span lines, so lines are joined until the quotes balance.
---@param path string
---@param separator string|nil
---@return { header: string[], rows: string[][], separator: string }
function M.read(path, separator)
  local lines = vim.fn.readfile(vim.fn.expand(path))
  if #lines == 0 then
    error("the file is empty", 0)
  end

  if not separator then
    -- Guess between comma, semicolon and tab by counting them in the header.
    local counts = {}
    for _, candidate in ipairs({ ",", ";", "\t" }) do
      local _, count = lines[1]:gsub(vim.pesc(candidate), "")
      counts[candidate] = count
    end
    separator = ","
    for candidate, count in pairs(counts) do
      if count > counts[separator] then
        separator = candidate
      end
    end
  end

  local records = {}
  local pending = nil
  for _, line in ipairs(lines) do
    local text = pending and (pending .. "\n" .. line) or line
    local _, quotes = text:gsub('"', "")
    if quotes % 2 == 1 then
      pending = text
    else
      pending = nil
      table.insert(records, M.split_line(text, separator))
    end
  end
  if pending then
    table.insert(records, M.split_line(pending, separator))
  end

  local header = table.remove(records, 1)
  return { header = header, rows = records, separator = separator }
end

--- Render the mapping buffer.
local function mapping_lines(job)
  local lines = {
    ("# import %s"):format(job.path),
    ("# into %s.%s on %s"):format(job.schema, job.table, job.connection),
    ("# %d data row(s), separator %s"):format(
      #job.data.rows,
      job.data.separator == "\t" and "tab" or job.data.separator
    ),
    "#",
    "# Map each file column to a table column. Leave a target blank to skip",
    "# the column. `skip_header` is already applied. :w imports, :q cancels.",
    "",
  }

  local width = 0
  for _, name in ipairs(job.data.header) do
    width = math.max(width, #name)
  end

  for index, name in ipairs(job.data.header) do
    local guess = job.mapping[index] or ""
    lines[#lines + 1] = ("%-" .. width .. "s -> %s"):format(name, guess)
  end

  table.insert(lines, "")
  table.insert(lines, "# available columns: " .. table.concat(job.columns, ", "))
  table.insert(lines, "#")
  table.insert(lines, "# preview of the first rows as they will be read:")
  for index = 1, math.min(3, #job.data.rows) do
    table.insert(lines, "#   " .. table.concat(job.data.rows[index], " | "))
  end

  return lines
end

--- Parse the mapping back out of the buffer.
local function parse_mapping(bufnr)
  local mapping = {}
  local index = 0
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if not line:match("^#") and line:match("%S") then
      local _, target = line:match("^(.-)%s*->%s*(.-)%s*$")
      if target ~= nil then
        index = index + 1
        mapping[index] = target ~= "" and target or nil
      end
    end
  end
  return mapping
end

--- Start an import: read the file, guess the mapping, open the buffer.
---@param opts { session_id?: string, schema: string, table: string, path: string, separator?: string }
function M.start(opts)
  local target = session.get(opts.session_id)
  if not target then
    return notify("no active connection", vim.log.levels.WARN)
  end

  local ok, data = pcall(M.read, opts.path, opts.separator)
  if not ok then
    return notify("could not read the file: " .. tostring(data), vim.log.levels.ERROR)
  end

  client.async(function()
    local columns = session.columns(target.id, opts.schema, opts.table)
    local names = {}
    local lookup = {}
    for _, column in ipairs(columns) do
      table.insert(names, column.name)
      lookup[column.name:lower()] = column.name
    end

    -- Guess by exact name, then by a normalised name.
    local mapping = {}
    for index, header in ipairs(data.header) do
      local normalised = header:lower():gsub("[%s%-]+", "_")
      mapping[index] = lookup[header:lower()] or lookup[normalised]
    end

    local job = {
      session_id = target.id,
      connection = target.name,
      schema = opts.schema,
      table = opts.table,
      path = opts.path,
      data = data,
      columns = names,
      mapping = mapping,
    }

    local bufnr = buffer.scratch("dbclient://import", {
      modifiable = true,
      buftype = "acwrite",
    })
    vim.bo[bufnr].filetype = "dbclient-import"
    M.jobs[bufnr] = job

    buffer.set_lines(bufnr, mapping_lines(job))
    buffer.show(bufnr, "botright split")

    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = bufnr,
      callback = function()
        M.execute(bufnr)
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = bufnr,
      callback = function()
        M.jobs[bufnr] = nil
      end,
    })

    local mapped = 0
    for _ in pairs(mapping) do
      mapped = mapped + 1
    end
    notify(("%d of %d columns matched by name; :w to import"):format(mapped, #data.header))
  end, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

--- Perform the import described by the buffer.
---@param bufnr integer
function M.execute(bufnr)
  local job = M.jobs[bufnr]
  if not job then
    return
  end

  local mapping = parse_mapping(bufnr)
  local used = {}
  for index, target_column in pairs(mapping) do
    if not vim.tbl_contains(job.columns, target_column) then
      return notify(
        ("`%s` is not a column of %s.%s"):format(target_column, job.schema, job.table),
        vim.log.levels.ERROR
      )
    end
    if used[target_column] then
      return notify(("`%s` is mapped twice"):format(target_column), vim.log.levels.ERROR)
    end
    used[target_column] = index
  end

  if vim.tbl_isempty(mapping) then
    return notify("nothing is mapped", vim.log.levels.WARN)
  end

  local changes = {}
  for _, row in ipairs(job.data.rows) do
    local values = {}
    local any = false
    for index, target_column in pairs(mapping) do
      local value = row[index]
      if value ~= nil and value ~= "" then
        values[target_column] = value
        any = true
      end
    end
    if any then
      table.insert(changes, {
        op = "insert",
        schema = job.schema,
        table = job.table,
        values = values,
      })
    end
  end

  if #changes == 0 then
    return notify("no rows to import", vim.log.levels.WARN)
  end

  vim.ui.select({ "no", "yes" }, {
    prompt = ("insert %d row(s) into %s.%s?"):format(#changes, job.schema, job.table),
  }, function(choice)
    if choice ~= "yes" then
      return
    end

    client.async(function()
      -- Batch so one enormous file does not become one enormous statement
      -- list; each batch is still a transaction on its own.
      local batch_size = 500
      local inserted = 0
      for start = 1, #changes, batch_size do
        local batch = vim.list_slice(changes, start, math.min(start + batch_size - 1, #changes))
        local outcome = session.apply_changes(job.session_id, batch)
        inserted = inserted + outcome.affected_rows
        notify(("imported %d/%d..."):format(inserted, #changes))
      end
      vim.bo[bufnr].modified = false
      notify(("imported %d row(s) into %s.%s"):format(inserted, job.schema, job.table))
    end, function(err)
      notify("import failed: " .. tostring(err), vim.log.levels.ERROR)
    end)
  end)
end

--- Prompt for a file and start an import into a table.
---@param opts { session_id?: string, schema: string, table: string }
function M.prompt(opts)
  vim.ui.input({ prompt = "csv file ", completion = "file" }, function(path)
    if not path or path == "" then
      return
    end
    M.start(vim.tbl_extend("force", opts, { path = path }))
  end)
end

return M

--- The export editor.
---
--- Every other client puts export behind a wizard, which makes the interesting
--- settings hard to find and impossible to repeat. Here the settings are text
--- in a buffer: discoverable because they are all visible at once, editable
--- with the keys you already use, and saveable as a file, which is what turns a
--- one-off into a preset.

local buffer = require("dbclient.ui.buffer")
local client = require("dbclient.core.client")
local config = require("dbclient.config")
local help = require("dbclient.ui.help")
local highlights = require("dbclient.ui.highlights")
local keymap = require("dbclient.keymap")
local session = require("dbclient.session")
local spec = require("dbclient.export.spec")
local window = require("dbclient.ui.window")

local M = {
  --- bufnr -> job
  jobs = {},
}

local function notify(message, level)
  vim.notify("DBClient: " .. message, level or vim.log.levels.INFO)
end

--- Highlight the editor: comments dim, keys distinct, values plain.
local function decorate(bufnr)
  local marks = {}
  for index, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:match("^%s*#") then
      table.insert(marks, { line = index - 1, group = "DBClientHelpText" })
    else
      local key = line:match("^%s*([%w_]+)%s*=")
      if key then
        table.insert(marks, {
          line = index - 1,
          col = 0,
          end_col = #key,
          group = "DBClientKey",
        })
        local comment = line:find("%s+#%s")
        if comment then
          table.insert(marks, {
            line = index - 1,
            col = comment,
            end_col = #line,
            group = "DBClientHelpText",
          })
        end
      end
    end
  end
  highlights.lines(bufnr, marks)
end

local function render(bufnr)
  local job = M.jobs[bufnr]
  if not job then
    return
  end
  buffer.set_lines(bufnr, spec.render(job.values, {
    connection = job.connection,
    sql = job.context.sql,
  }))
  decorate(bufnr)
end

--- Read the buffer and build the payload.
---@param bufnr integer
---@return table|nil payload, string|nil err
local function payload_of(bufnr)
  local job = M.jobs[bufnr]
  if not job then
    return nil, "this export editor is gone"
  end
  job.values = spec.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  return spec.to_payload(job.values, job.context)
end

--- Run the export described by the buffer.
---@param bufnr integer
---@param opts? { preview?: boolean }
local function run(bufnr, opts)
  opts = opts or {}
  local job = M.jobs[bufnr]
  if not job then
    return
  end

  local payload, err = payload_of(bufnr)
  if not payload then
    return notify(err, vim.log.levels.ERROR)
  end

  if opts.preview then
    payload.preview = true
    payload.preview_rows = 20
  end

  local target = session.get(job.session_id)
  if not target then
    return notify("the connection is gone", vim.log.levels.WARN)
  end

  notify(opts.preview and "rendering a preview..." or "exporting...")

  client.async(function()
    local outcome = client.call("export", payload, target.id)

    if opts.preview then
      return M.show_preview(outcome, payload)
    end

    vim.bo[bufnr].modified = false
    M.show_result(outcome, payload)

    if job.on_done then
      job.on_done(outcome)
    end
  end, function(error_message)
    notify(error_message, vim.log.levels.ERROR)
  end)
end

--- Show what an export produced.
---@param outcome table
---@param payload table
function M.show_result(outcome, payload)
  local lines = {
    ("%d row(s) in %d ms"):format(outcome.rows, outcome.elapsed_ms or 0),
    "",
  }

  for _, warning in ipairs(outcome.warnings or {}) do
    table.insert(lines, "! " .. warning)
  end
  if #(outcome.warnings or {}) > 0 then
    table.insert(lines, "")
  end

  for _, file in ipairs(outcome.files or {}) do
    local size = file.bytes or 0
    local human = size > 1024 * 1024 and ("%.1f MB"):format(size / 1024 / 1024)
      or size > 1024 and ("%.1f kB"):format(size / 1024)
      or ("%d B"):format(size)
    table.insert(lines, ("%s"):format(file.path))
    table.insert(
      lines,
      ("   %d row(s), %s%s"):format(
        file.rows or 0,
        human,
        file.partition and ("   partition " .. file.partition) or ""
      )
    )
    if file.sha256 then
      table.insert(lines, ("   sha256 %s"):format(file.sha256))
    end
  end

  if outcome.manifest then
    table.insert(lines, "")
    table.insert(lines, "manifest: " .. outcome.manifest)
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  local winid = window.float(bufnr, { title = "exported", max_width = 0.9, max_height = 0.6 })
  highlights.lines(bufnr, { { line = 0, group = "DBClientHeader" } })
  window.close_keys(bufnr, winid)

  notify(("wrote %d file(s), %d row(s)"):format(#(outcome.files or {}), outcome.rows))
end

--- Show the first lines the export would produce.
---@param outcome table
---@param payload table
function M.show_preview(outcome, payload)
  local text = outcome.preview or ""
  local lines = vim.split(text, "\n")
  table.insert(lines, 1, ("-- preview: %d row(s), nothing written"):format(outcome.rows))
  table.insert(lines, 2, "")

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = ({
    json = "json",
    jsonl = "json",
    markdown = "markdown",
    html = "html",
    xml = "xml",
    sql = "sql",
  })[payload.format] or ""
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  local winid = window.float(bufnr, {
    title = "export preview",
    max_width = 0.9,
    max_height = 0.8,
    cursorline = false,
  })
  highlights.lines(bufnr, { { line = 0, group = "DBClientHelpText" } })
  window.close_keys(bufnr, winid)
end

--- Choose a preset and re-render.
---@param bufnr integer
local function pick_preset(bufnr)
  local names = spec.preset_names()
  vim.ui.select(names, {
    prompt = "preset",
    format_item = function(name)
      return ("%-14s %s"):format(name, spec.presets[name].label)
    end,
  }, function(choice)
    if not choice then
      return
    end
    local job = M.jobs[bufnr]
    job.values = spec.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    local merged, err = spec.apply_preset(job.values, choice)
    if err then
      return notify(err, vim.log.levels.ERROR)
    end

    -- A preset that changes the format should change the file extension too.
    local destination = merged.destination or ""
    if destination ~= "" then
      local extension = ({
        csv = "csv",
        tsv = "tsv",
        json = "json",
        jsonl = "jsonl",
        markdown = "md",
        html = "html",
        xml = "xml",
        sql = "sql",
        xlsx = "xlsx",
        text = "txt",
      })[merged.format]
      if extension then
        merged.destination = destination:gsub("%.[%w]+$", "") .. "." .. extension
      end
    end

    job.values = merged
    render(bufnr)
    notify("applied preset: " .. choice)
  end)
end

--- Open the export editor.
---@param opts { session_id?: string, sql?: string, table?: string, schema?: string, values?: table, on_done?: fun(outcome: table) }
function M.open(opts)
  local target = session.get(opts.session_id)
  if not target then
    return notify("no active connection", vim.log.levels.WARN)
  end

  local values = opts.values or spec.defaults()
  if opts.table then
    values.table = opts.table
    values.schema = opts.schema or ""
  end
  if values.destination == nil or values.destination == "" then
    values.destination = spec.suggest_destination({
      dir = config.get().export.dir,
      table = opts.table,
      format = values.format,
      connection = target.name,
    })
  end

  local bufnr = buffer.scratch("dbclient://export", {
    modifiable = true,
    buftype = "acwrite",
  })
  vim.bo[bufnr].filetype = "dbclient-export"

  local first = M.jobs[bufnr] == nil
  M.jobs[bufnr] = {
    session_id = target.id,
    connection = target.name,
    values = values,
    context = { sql = opts.sql, schema = opts.schema },
    on_done = opts.on_done,
  }

  render(bufnr)
  buffer.show(bufnr, "botright split")

  if first then
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = bufnr,
      callback = function()
        run(bufnr)
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = bufnr,
      callback = function()
        M.jobs[bufnr] = nil
      end,
    })

    keymap.apply("export", bufnr, {
      run = function()
        run(bufnr)
      end,
      preview = function()
        run(bufnr, { preview = true })
      end,
      preset = function()
        pick_preset(bufnr)
      end,
      save_preset = function()
        M.save_preset(bufnr)
      end,
      close = function()
        buffer.hide(bufnr)
      end,
      help = help.handler("export"),
    })
  end

  -- Land on the destination, which is the one field that always needs a look.
  for index, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:match("^destination") then
      pcall(vim.api.nvim_win_set_cursor, 0, { index, #line })
      break
    end
  end
end

--- Save the current settings as a reusable file.
---@param bufnr integer
function M.save_preset(bufnr)
  local job = M.jobs[bufnr]
  if not job then
    return
  end
  job.values = spec.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

  vim.ui.input({ prompt = "preset name " }, function(name)
    if not name or name == "" then
      return
    end
    local directory = config.get().export.dir .. "/presets"
    vim.fn.mkdir(directory, "p")
    local path = ("%s/%s.export"):format(directory, name:gsub("[^%w_-]", "-"))
    vim.fn.writefile(spec.render(job.values, {}), path)
    notify("saved " .. path)
  end)
end

--- Load a saved preset file into a new editor.
---@param opts? { session_id?: string, sql?: string }
function M.load_preset(opts)
  opts = opts or {}
  local directory = config.get().export.dir .. "/presets"
  local files = vim.fn.glob(directory .. "/*.export", false, true)
  if #files == 0 then
    return notify("no saved export presets yet", vim.log.levels.WARN)
  end

  vim.ui.select(files, {
    prompt = "export preset",
    format_item = function(path)
      return vim.fn.fnamemodify(path, ":t:r")
    end,
  }, function(choice)
    if not choice then
      return
    end
    M.open(vim.tbl_extend("force", opts, {
      values = spec.parse(vim.fn.readfile(choice)),
    }))
  end)
end

return M

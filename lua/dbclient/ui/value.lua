--- The value inspector.
---
--- Cells are truncated in the grid, which is fine until the column holds JSON,
--- a token, a blob or a paragraph of text. `K` opens the whole value in a real
--- buffer with the right filetype, decodes the encodings that show up in
--- practice, and can write an edit straight back into the staged change set.

local client = require("dbclient.core.client")
local config = require("dbclient.config")
local window = require("dbclient.ui.window")

local M = {}

--- Pretty print decoded JSON. `vim.json` has no encoder with indentation, and
--- round-tripping through an external formatter would be a hard dependency.
---@param value any
---@param indent string|nil
---@return string[]
function M.format_json(value, indent)
  indent = indent or ""
  local step = indent .. "  "

  if type(value) ~= "table" then
    if value == vim.NIL or value == nil then
      return { indent .. "null" }
    end
    if type(value) == "string" then
      return { indent .. vim.json.encode(value) }
    end
    return { indent .. tostring(value) }
  end

  if vim.tbl_isempty(value) then
    return { indent .. (vim.islist(value) and "[]" or "{}") }
  end

  local lines = {}
  if vim.islist(value) then
    table.insert(lines, indent .. "[")
    for index, item in ipairs(value) do
      local rendered = M.format_json(item, step)
      rendered[#rendered] = rendered[#rendered] .. (index < #value and "," or "")
      vim.list_extend(lines, rendered)
    end
    table.insert(lines, indent .. "]")
    return lines
  end

  local keys = vim.tbl_keys(value)
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)

  table.insert(lines, indent .. "{")
  for index, key in ipairs(keys) do
    local rendered = M.format_json(value[key], step)
    rendered[1] = ("%s%s: %s"):format(step, vim.json.encode(tostring(key)), vim.trim(rendered[1]))
    rendered[#rendered] = rendered[#rendered] .. (index < #keys and "," or "")
    vim.list_extend(lines, rendered)
  end
  table.insert(lines, indent .. "}")
  return lines
end

local function decode_base64(text)
  local ok, decoded = pcall(function()
    return vim.base64.decode(text)
  end)
  if ok and type(decoded) == "string" then
    return decoded
  end
  return nil
end

local function is_printable(text)
  return text ~= "" and not text:find("[%z\1-\8\11\12\14-\31]")
end

--- Recognise the encodings that turn up in real columns.
---@param text string
---@return { kind: string, lines: string[], filetype?: string }|nil
function M.decode(text)
  -- JSON object or array.
  local trimmed = vim.trim(text)
  if trimmed:match("^[%[{]") then
    local ok, decoded = pcall(vim.json.decode, trimmed)
    if ok then
      return { kind = "json", lines = M.format_json(decoded), filetype = "json" }
    end
  end

  -- JSON Web Token: three base64url segments.
  local header, payload = trimmed:match("^([%w_-]+)%.([%w_-]+)%.[%w_-]*$")
  if header and payload then
    local function decode_segment(segment)
      local padded = segment:gsub("-", "+"):gsub("_", "/")
      padded = padded .. string.rep("=", (4 - #padded % 4) % 4)
      local raw = decode_base64(padded)
      if not raw then
        return nil
      end
      local ok, decoded = pcall(vim.json.decode, raw)
      return ok and decoded or nil
    end

    local header_json = decode_segment(header)
    local payload_json = decode_segment(payload)
    if header_json and payload_json then
      local lines = { "// header" }
      vim.list_extend(lines, M.format_json(header_json))
      table.insert(lines, "")
      table.insert(lines, "// payload")
      vim.list_extend(lines, M.format_json(payload_json))
      if type(payload_json) == "table" and tonumber(payload_json.exp) then
        table.insert(lines, "")
        table.insert(
          lines,
          ("// exp: %s"):format(os.date("!%Y-%m-%d %H:%M:%S UTC", tonumber(payload_json.exp)))
        )
      end
      return { kind = "jwt", lines = lines, filetype = "javascript" }
    end
  end

  -- Unix timestamps, in seconds or milliseconds.
  local digits = trimmed:match("^%d+$")
  if digits and (#digits == 10 or #digits == 13) then
    local seconds = tonumber(digits)
    if #digits == 13 then
      seconds = math.floor(seconds / 1000)
    end
    if seconds > 946684800 and seconds < 4102444800 then -- 2000..2100
      return {
        kind = "timestamp",
        lines = {
          trimmed,
          "",
          ("UTC:   %s"):format(os.date("!%Y-%m-%d %H:%M:%S", seconds)),
          ("local: %s"):format(os.date("%Y-%m-%d %H:%M:%S", seconds)),
        },
      }
    end
  end

  -- Base64 payloads that decode to text.
  if #trimmed >= 8 and #trimmed % 4 == 0 and trimmed:match("^[A-Za-z0-9+/]+=*$") then
    local decoded = decode_base64(trimmed)
    if decoded and is_printable(decoded) then
      local lines = { "// base64 decoded" }
      vim.list_extend(lines, vim.split(decoded, "\n"))
      return { kind = "base64", lines = lines }
    end
  end

  return nil
end

--- Render a hex dump of raw bytes, 16 per line.
---@param bytes string
---@return string[]
function M.hex_dump(bytes)
  local lines = {}
  for offset = 1, #bytes, 16 do
    local chunk = bytes:sub(offset, offset + 15)
    local hex = {}
    local ascii = {}
    for index = 1, #chunk do
      local byte = chunk:byte(index)
      table.insert(hex, ("%02x"):format(byte))
      table.insert(ascii, (byte >= 32 and byte < 127) and string.char(byte) or ".")
    end
    while #hex < 16 do
      table.insert(hex, "  ")
    end
    table.insert(
      lines,
      ("%08x  %s %s  |%s|"):format(
        offset - 1,
        table.concat(vim.list_slice(hex, 1, 8), " "),
        table.concat(vim.list_slice(hex, 9, 16), " "),
        table.concat(ascii)
      )
    )
    if #lines >= 512 then
      table.insert(lines, "...")
      break
    end
  end
  return lines
end

--- Open the inspector.
---@param opts { value: any, column?: table, title?: string, session?: string, on_save?: fun(text: string) }
function M.open(opts)
  local column = opts.column or {}
  local raw = opts.value

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"

  local function present(lines, filetype, note)
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    if filetype then
      vim.bo[bufnr].filetype = filetype
    end
    vim.bo[bufnr].modifiable = opts.on_save ~= nil
    vim.bo[bufnr].modified = false

    local title = opts.title or column.name or "value"
    if note then
      title = ("%s  (%s)"):format(title, note)
    end

    local winid = window.float(bufnr, {
      title = title,
      max_width = 0.85,
      max_height = 0.8,
      wrap = true,
      cursorline = false,
    })

    if opts.on_save then
      vim.bo[bufnr].buftype = "acwrite"
      vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = bufnr,
        callback = function()
          local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
          opts.on_save(text)
          vim.bo[bufnr].modified = false
          window.close(winid, bufnr)
        end,
      })
    end

    window.close_keys(bufnr, winid)
  end

  if raw == nil or raw == vim.NIL then
    return present({ config.get().ui.null_display, "", "-- SQL NULL --" }, nil, "null")
  end

  local text = tostring(raw)

  -- Binary columns arrive as `\x...`; ask the core for the real bytes.
  if column.class == "binary" or text:match("^\\x%x*$") then
    if not opts.session then
      return present(M.hex_dump(text), nil, "binary")
    end
    return client.async(function()
      local blob = client.call("blob", { value = text })
      local bytes = vim.base64.decode(blob.base64)
      local lines = {
        ("%d bytes, %s"):format(blob.size, blob.mime),
        "",
      }
      if blob.mime == "text/plain" then
        vim.list_extend(lines, vim.split(bytes, "\n"))
      else
        vim.list_extend(lines, M.hex_dump(bytes))
      end
      present(lines, nil, blob.mime)
    end, function(err)
      present({ "could not decode blob: " .. err, "", text }, nil, "binary")
    end)
  end

  local decoded = M.decode(text)
  if decoded then
    return present(decoded.lines, decoded.filetype, decoded.kind)
  end

  local filetype = column.class == "json" and "json" or nil
  local lines = vim.split(text, "\n", { plain = true })
  present(lines, filetype, ("%s, %d chars"):format(column.type or "value", vim.fn.strchars(text)))
end

return M

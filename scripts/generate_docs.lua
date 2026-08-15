--- Regenerate the documentation that describes mappings.
---
--- `doc/dbclient.txt` and the README's keyboard section are both produced from
--- `dbclient.keymap`, so a new mapping cannot silently go undocumented.
---
---   nvim --headless -u NONE -c "luafile scripts/generate_docs.lua"
---
--- Run with `--check` to fail instead of writing, which is what CI does.

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local keymap = require("dbclient.keymap")

local check_only = vim.tbl_contains(vim.v.argv, "--check")

local START = "<!-- keys:start -->"
local STOP = "<!-- keys:stop -->"
local HELP_START = "*dbclient-keys*"
local HELP_STOP = "=============================================================================="

local function wrap(text, width)
  local lines = {}
  local current = ""
  for word in text:gmatch("%S+") do
    if current == "" then
      current = word
    elseif #current + #word + 1 <= width then
      current = current .. " " .. word
    else
      table.insert(lines, current)
      current = word
    end
  end
  if current ~= "" then
    table.insert(lines, current)
  end
  return lines
end

--- Markdown table of every mapping group.
local function markdown()
  local lines = {}
  for _, group in ipairs(keymap.order) do
    local spec = keymap.groups[group]
    if spec then
      table.insert(lines, "### " .. spec.title)
      table.insert(lines, "")
      if spec.description then
        for _, paragraph in ipairs(vim.split(vim.trim(spec.description), "\n\n")) do
          table.insert(lines, (paragraph:gsub("\n", " ")))
          table.insert(lines, "")
        end
      end
      table.insert(lines, "| key | action |")
      table.insert(lines, "| --- | --- |")
      for _, entry in ipairs(spec.keys) do
        local modes = ""
        if type(entry.mode) == "table" then
          modes = (" _(%s)_"):format(table.concat(entry.mode, ", "))
        elseif type(entry.mode) == "string" and entry.mode ~= "n" then
          modes = (" _(%s)_"):format(entry.mode)
        end
        table.insert(
          lines,
          ("| `%s` | %s%s |"):format(keymap.lhs(group, entry), entry.desc, modes)
        )
      end
      table.insert(lines, "")
    end
  end
  return lines
end

--- Vim help section for the mappings.
local function helptext()
  local lines = { "KEYS                                                    *dbclient-keys*", "" }

  for _, group in ipairs(keymap.order) do
    local spec = keymap.groups[group]
    if spec then
      table.insert(lines, spec.title:upper())
      if spec.description then
        table.insert(lines, "")
        for _, paragraph in ipairs(vim.split(vim.trim(spec.description), "\n\n")) do
          for _, line in ipairs(wrap((paragraph:gsub("\n", " ")), 76)) do
            table.insert(lines, line)
          end
          table.insert(lines, "")
        end
      else
        table.insert(lines, "")
      end

      for _, entry in ipairs(spec.keys) do
        local modes = ""
        if type(entry.mode) == "table" then
          modes = (" [%s]"):format(table.concat(entry.mode, ""))
        elseif type(entry.mode) == "string" and entry.mode ~= "n" then
          modes = (" [%s]"):format(entry.mode)
        end
        table.insert(lines, ("    %-16s %s%s"):format(keymap.lhs(group, entry), entry.desc, modes))
      end
      table.insert(lines, "")
    end
  end

  return lines
end

--- Replace the region between two markers.
local function splice(lines, start_marker, stop_marker, replacement)
  local out = {}
  local index = 1
  local start_index, stop_index

  for position, line in ipairs(lines) do
    if not start_index and line:find(start_marker, 1, true) then
      start_index = position
    elseif start_index and not stop_index and line:find(stop_marker, 1, true) then
      stop_index = position
    end
  end

  if not start_index or not stop_index then
    return nil, ("markers %s / %s not found"):format(start_marker, stop_marker)
  end

  while index <= start_index do
    table.insert(out, lines[index])
    index = index + 1
  end
  vim.list_extend(out, replacement)
  for position = stop_index, #lines do
    table.insert(out, lines[position])
  end
  return out
end

local changed = {}

local function update(path, transform)
  local existing = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
  local updated, err = transform(existing)
  if not updated then
    print(("%s: %s"):format(path, err))
    return false
  end

  if vim.deep_equal(existing, updated) then
    print(("%s is up to date"):format(path))
    return true
  end

  table.insert(changed, path)
  if check_only then
    print(("%s is OUT OF DATE"):format(path))
    return false
  end

  vim.fn.writefile(updated, path)
  print(("%s regenerated"):format(path))
  return true
end

local ok = true

ok = update("README.md", function(lines)
  return splice(lines, START, STOP, vim.list_extend({ "" }, markdown()))
end) and ok

ok = update("doc/dbclient.txt", function(lines)
  local out = {}
  local index = 1
  local start_index
  for position, line in ipairs(lines) do
    if line:find(HELP_START, 1, true) then
      start_index = position
      break
    end
  end
  if not start_index then
    return nil, "*dbclient-keys* section not found"
  end

  -- Find the section separator that closes the keys section.
  local stop_index
  for position = start_index + 1, #lines do
    if lines[position]:find(HELP_STOP, 1, true) then
      stop_index = position
      break
    end
  end
  if not stop_index then
    return nil, "no section separator after *dbclient-keys*"
  end

  while index < start_index do
    table.insert(out, lines[index])
    index = index + 1
  end
  vim.list_extend(out, helptext())
  for position = stop_index, #lines do
    table.insert(out, lines[position])
  end
  return out
end) and ok

if check_only and #changed > 0 then
  print("\nDocumentation is stale. Run: nvim --headless -u NONE -c 'luafile scripts/generate_docs.lua'")
end

vim.cmd(ok and "cquit 0" or "cquit 1")

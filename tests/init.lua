--- Minimal test harness.
---
--- Deliberately dependency free: `nvim --headless` plus this file is the whole
--- runner, so contributors and CI need nothing installed.
---
--- A spec file returns a table of `["name"] = function() ... end`.

local M = {
  passed = 0,
  failed = 0,
  failures = {},
  current = nil,
}

local function format_value(value)
  if type(value) == "string" then
    return ("%q"):format(value)
  end
  return vim.inspect(value)
end

function M.eq(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(
      ("%s\n  expected: %s\n  actual:   %s"):format(
        message or "values differ",
        format_value(expected),
        format_value(actual)
      ),
      2
    )
  end
end

function M.ok(value, message)
  if not value then
    error(message or "expected a truthy value", 2)
  end
end

function M.falsy(value, message)
  if value then
    error(message or ("expected a falsy value, got " .. format_value(value)), 2)
  end
end

function M.matches(text, pattern, message)
  if type(text) ~= "string" or not text:match(pattern) then
    error(
      ("%s\n  pattern: %s\n  text:    %s"):format(
        message or "pattern did not match",
        pattern,
        format_value(text)
      ),
      2
    )
  end
end

function M.errors(fn, pattern)
  local ok, err = pcall(fn)
  if ok then
    error("expected the call to fail", 2)
  end
  if pattern and not tostring(err):match(pattern) then
    error(("error %q did not match %q"):format(tostring(err), pattern), 2)
  end
  return err
end

--- Run a suite.
---
--- Accepts either a map of `name = fn`, which runs in sorted order, or a list
--- of `{ "name", fn }` pairs, which runs in the order written. Integration
--- suites need the second form because each step builds on the last.
---@param name string
---@param tests table
function M.describe(name, tests)
  local ordered = {}
  if vim.islist(tests) and #tests > 0 then
    for _, entry in ipairs(tests) do
      table.insert(ordered, { entry[1], entry[2] })
    end
  else
    local names = vim.tbl_keys(tests)
    table.sort(names)
    for _, test_name in ipairs(names) do
      table.insert(ordered, { test_name, tests[test_name] })
    end
  end

  print("\n" .. name)
  for _, entry in ipairs(ordered) do
    local test_name, fn = entry[1], entry[2]
    local ok, err = pcall(fn)
    if ok then
      M.passed = M.passed + 1
      print(("  ok    %s"):format(test_name))
    else
      M.failed = M.failed + 1
      table.insert(M.failures, { suite = name, test = test_name, error = err })
      print(("  FAIL  %s"):format(test_name))
      for _, line in ipairs(vim.split(tostring(err), "\n")) do
        print("          " .. line)
      end
    end
  end
end

function M.report()
  print("")
  print(("%d passed, %d failed"):format(M.passed, M.failed))
  return M.failed == 0
end

return M

--- Test entry point: `nvim --headless -u NONE -c "luafile tests/run.lua"`.

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local t = require("tests.init")

require("dbclient.config").setup({ connections = {} })

local specs = vim.fn.glob(vim.fn.getcwd() .. "/tests/*_spec.lua", false, true)
table.sort(specs)

for _, path in ipairs(specs) do
  local name = vim.fn.fnamemodify(path, ":t:r")
  local ok, err = pcall(dofile, path)
  if not ok then
    t.failed = t.failed + 1
    print(("\n%s\n  FAIL  could not load spec"):format(name))
    for _, line in ipairs(vim.split(tostring(err), "\n")) do
      print("          " .. line)
    end
  end
end

local success = t.report()
vim.cmd(success and "cquit 0" or "cquit 1")

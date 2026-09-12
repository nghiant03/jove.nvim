-- minimal_init.lua: Neovim init for headless mini.test runs.
-- Usage: nvim --headless -u scripts/minimal_init.lua -c 'lua MiniTest.run()'
-- Run from the repo root (scripts/run_tests.sh does this).

local this_file = debug.getinfo(1).source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(this_file))

-- Make the plugin itself available on the runtimepath.
vim.opt.runtimepath:prepend(root)

-- Make the vendored mini.test dependency available on the runtimepath.
vim.opt.runtimepath:prepend(vim.fs.joinpath(root, ".testdeps", "mini.test"))

-- Keep test runs hermetic.
vim.opt.swapfile = false
vim.opt.undofile = false
vim.opt.shadafile = "NONE"

require("mini.test").setup({
  collect = {
    find_files = function()
      return vim.fn.globpath("tests/spec", "*_spec.lua", true, true)
    end,
  },
})

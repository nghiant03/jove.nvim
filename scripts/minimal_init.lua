-- minimal_init.lua: Neovim init for headless mini.test runs.

local this_file = debug.getinfo(1).source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(this_file))

vim.opt.runtimepath:prepend(root)

vim.opt.runtimepath:prepend(vim.fs.joinpath(root, ".testdeps", "mini.test"))

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

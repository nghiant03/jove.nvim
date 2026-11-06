-- Neovim init for headless mini.test runs.

local this_file = debug.getinfo(1).source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(this_file))

vim.opt.runtimepath:prepend(root)

vim.opt.runtimepath:prepend(vim.fs.joinpath(root, ".testdeps", "mini.test"))

vim.opt.swapfile = false
vim.opt.undofile = false
vim.opt.shadafile = "NONE"

local tier = vim.env.JOVE_TEST_TIER or "all"
local tiers = { all = true, unit = true, component = true, adapter = true, e2e = true }
assert(tiers[tier], "Unknown JOVE_TEST_TIER: " .. tier)

local unit = {
  ansi_spec = true,
  lang_spec = true,
  mime_spec = true,
  output_render_spec = true,
  persist_spec = true,
  webview_document_spec = true,
  webview_transport_spec = true,
}
local adapter = {
  buffer_spec = true,
  convert_spec = true,
  persist_adapter_spec = true,
  webview_terminal_spec = true,
}

require("mini.test").setup({
  collect = {
    find_files = function()
      local files = vim.fn.globpath("tests/spec", "*_spec.lua", true, true)
      return vim.tbl_filter(function(file)
        local name = vim.fn.fnamemodify(file, ":t:r")
        local category = unit[name] and "unit"
          or adapter[name] and "adapter"
          or name:match("_e2e_spec$") and "e2e"
          or "component"
        return tier == "all" or tier == category
      end, files)
    end,
  },
})

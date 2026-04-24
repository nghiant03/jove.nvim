-- jove: native .ipynb editing for Neovim, backed by jupytext + molten.
local M = {}

---@class jove.Config
---@field jupytext string                Path to the jupytext binary.
---@field auto_kernel boolean            Auto-run MoltenInit on open.
---@field auto_import_outputs boolean    Auto-run MoltenImportOutput after kernel init.
---@field auto_export_outputs boolean    Auto-run MoltenExportOutput! after save.
---@field keymap table<string, string|false>

---@type jove.Config
M.config = {
  jupytext = "jupytext",
  auto_kernel = true,
  auto_import_outputs = true,
  auto_export_outputs = true,
  keymap = {
    run_cell = false,
    next_cell = false,
    prev_cell = false,
  },
}

---@param opts jove.Config?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  require("jove.keymaps").apply(M.config.keymap)
end

return M

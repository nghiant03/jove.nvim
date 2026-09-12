-- jove: native .ipynb editing for Neovim, backed by jupytext + molten.
local M = {}

---@class jove.Config
---@field jupytext string                Path to the jupytext binary.
---@field auto_kernel boolean            Auto-run MoltenInit on open.
---@field auto_import_outputs boolean    Auto-run MoltenImportOutput after kernel init.
---@field auto_export_outputs boolean    Auto-run MoltenExportOutput! after save.
---@field auto_reload boolean           Auto-reload buffer when the .ipynb changes on disk (our own writes are suppressed).
---@field keymap table<string, string|false>

---@type jove.Config
M.config = {
  jupytext = "jupytext",
  auto_kernel = true,
  auto_import_outputs = true,
  auto_export_outputs = true,
  auto_reload = false,
  keymap = {
    run_cell = false,
    next_cell = false,
    prev_cell = false,
  },
}

---Valid keymap lhs: a mapping string or `false` to disable.
---@param v any
---@return boolean
local function is_keymap_lhs(v)
  return type(v) == "string" or v == false
end

---Validate a (fully merged) config table; raises via vim.validate on bad types.
---@param cfg jove.Config
local function validate_config(cfg)
  vim.validate("jupytext", cfg.jupytext, "string")
  vim.validate("auto_kernel", cfg.auto_kernel, "boolean")
  vim.validate("auto_import_outputs", cfg.auto_import_outputs, "boolean")
  vim.validate("auto_export_outputs", cfg.auto_export_outputs, "boolean")
  vim.validate("auto_reload", cfg.auto_reload, "boolean")
  vim.validate("keymap", cfg.keymap, "table")
  for k, v in pairs(cfg.keymap) do
    vim.validate(("keymap.%s"):format(k), v, is_keymap_lhs)
  end
end

---@param opts jove.Config?
function M.setup(opts)
  vim.validate("opts", opts, "table", true)

  -- Validate the merged config so defaults and user opts are both covered.
  local merged = vim.tbl_deep_extend("force", M.config, opts or {})
  validate_config(merged)

  M.config = merged
  require("jove.keymaps").apply(M.config.keymap)
end

return M

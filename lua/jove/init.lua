-- jove: native .ipynb editing for Neovim, backed by jupytext and a
-- first-party Python kernel bridge (see PROTOCOL.md).
local M = {}

---@class jove.Config
---@field jupytext string                Path to the jupytext binary.
---@field bridge_python string           Python interpreter for the kernel bridge. An active $CONDA_PREFIX or $VIRTUAL_ENV interpreter takes precedence at use time; this is the fallback.
---@field auto_kernel boolean            Start a bridge + kernel on open (kernelspec from notebook metadata, env, or picker).
---@field auto_import_outputs boolean    Import persisted outputs from the .ipynb on open/reload (gates persist.import).
---@field auto_export_outputs boolean    Merge session outputs into the .ipynb on save (gates persist.export).
---@field auto_reload boolean            Auto-reload buffer when the .ipynb changes on disk (our own writes are suppressed).
---@field cell_motions boolean           Map [c / ]c cell motions on jove buffers.
---@field signs table<string, string>    Gutter sign chars per cell status: queued/running/ok/error.
---@field output table                   Output rendering options: { max_lines, images }.
---@field keymap table<string, string|false>

---@type jove.Config
M.config = {
  jupytext = "jupytext",
  bridge_python = "python3",
  auto_kernel = true,
  auto_import_outputs = true,
  auto_export_outputs = true,
  auto_reload = false,
  cell_motions = true,
  signs = {
    queued = "…",
    running = "▶",
    ok = "✓",
    error = "✗",
  },
  output = {
    max_lines = 50,
    images = true,
  },
  keymap = {
    run_cell = false,
    run_and_advance = false,
    run_selection = false,
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
  vim.validate("bridge_python", cfg.bridge_python, "string")
  vim.validate("auto_kernel", cfg.auto_kernel, "boolean")
  vim.validate("auto_import_outputs", cfg.auto_import_outputs, "boolean")
  vim.validate("auto_export_outputs", cfg.auto_export_outputs, "boolean")
  vim.validate("auto_reload", cfg.auto_reload, "boolean")
  vim.validate("cell_motions", cfg.cell_motions, "boolean")
  vim.validate("signs", cfg.signs, "table")
  for _, k in ipairs({ "queued", "running", "ok", "error" }) do
    vim.validate(("signs.%s"):format(k), cfg.signs[k], "string")
  end
  vim.validate("output", cfg.output, "table")
  vim.validate("output.max_lines", cfg.output.max_lines, "number")
  vim.validate("output.images", cfg.output.images, "boolean")
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

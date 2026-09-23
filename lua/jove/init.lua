local M = {}

---@class jove.Config
---@field jupytext string                Path to the jupytext binary.
---@field bridge_python string           Python interpreter for the kernel bridge. An active $CONDA_PREFIX or $VIRTUAL_ENV interpreter takes precedence at use time; this is the fallback.
---@field auto_kernel boolean            Start a bridge + kernel on open (kernelspec from notebook metadata, env, or picker).
---@field auto_import_outputs boolean    Import persisted outputs from the .ipynb on open/reload (gates persist.import).
---@field auto_export_outputs boolean    Merge session outputs into the .ipynb on save (gates persist.export).
---@field persist_exec_counts boolean    Persist kernel execution counts into the .ipynb on save.
---@field elapsed boolean                Show per-cell elapsed execution time (UI).
---@field auto_reload boolean            Auto-reload buffer when the .ipynb changes on disk (our own writes are suppressed).
---@field cell_motions boolean           Map [c / ]c cell motions on jove buffers.
---@field signs table<string, string>    Gutter sign chars per cell status: queued/running/ok/error.
---@field output table                   Output rendering options:
---  | { max_lines, max_bytes, images, image_max_width, image_max_height,
---  | header, guide, inside_border, hl }.
---  | image_max_width/image_max_height: cap rendered image size in terminal
---  | cells (number|nil, nil disables); aspect ratio is preserved and images
---  | smaller than the cap keep their natural size.
---  | max_bytes: per-cell payload cap in bytes (default 1 MiB); streamed
---  | tails beyond it are dropped and a truncation marker is shown/persisted.
---  | header: draw the Output block's `┌─ Out[n] ─┐` top frame below each
---  | cell (boolean); setting false renders just content with the guide rail,
---  | no Output frame.
---  | guide: per-line inner rail string (placed before the text), or
---  | `false` to disable (`string|false`).
---  | inside_border: render output inside the cell border instead of in its
---  | own dedicated bordered block (boolean).
---  | hl: output background tint — an existing hl group name (`string`, linked
---  | to `JoveOutput`) or attrs passed to `nvim_set_hl` (`table`); nil disables.
---@field variables table                Variables inspector options: { auto_refresh, width }.
---  | width: sidebar width in columns, or a fraction (0 < width < 1) for a
---  | share of the total screen columns.
---@field ui table
---  | UI options: { conceal_headers, active_cell, exec_counts, elapsed, borders, border_hl, window_mode }.
---  | border_hl: `string|nil` (an existing hl group to link `JoveCellBorder` to)
---  | or `table|nil` (attrs passed to `nvim_set_hl` for `JoveCellBorder`, e.g.
---  | `{ fg = "#ff9e64" }`). nil leaves the default link in place.
---  | window_mode: how to open the sidebar (variables, kernel info, TOC),
---  | the variable detail view, and the output viewer: "float", "vsplit"
---  | (default), or "hsplit".
---@field keymap table<string, string|false>

---@type jove.Config
M.config = {
  jupytext = "jupytext",
  bridge_python = "python3",
  auto_kernel = true,
  auto_import_outputs = true,
  auto_export_outputs = true,
  persist_exec_counts = true,
  elapsed = true,
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
    max_bytes = 1048576,
    images = true,
    image_max_width = 80,
    image_max_height = 40,
    header = true,
    guide = "▎ ",
    inside_border = false,
    hl = nil,
  },
  variables = {
    auto_refresh = true,
    width = 48,
  },
  ui = {
    conceal_headers = true,
    active_cell = true,
    exec_counts = true,
    elapsed = true,
    borders = true,
    window_mode = "vsplit",
  },
  keymap = {
    run_cell = false,
    run_and_advance = false,
    run_selection = false,
    next_cell = false,
    prev_cell = false,
    goto_running_cell = false,
    toggle_follow_running = false,
  },
}

---@param v any
---@return boolean
local function is_keymap_lhs(v)
  return type(v) == "string" or v == false
end

local KNOWN_KEYS = {
  jupytext = true,
  bridge_python = true,
  auto_kernel = true,
  auto_import_outputs = true,
  auto_export_outputs = true,
  persist_exec_counts = true,
  elapsed = true,
  auto_reload = true,
  cell_motions = true,
  signs = true,
  output = true,
  variables = true,
  ui = true,
  keymap = true,
}
local KNOWN_KEYMAP_KEYS = {
  run_cell = true,
  run_and_advance = true,
  run_selection = true,
  next_cell = true,
  prev_cell = true,
  goto_running_cell = true,
  toggle_follow_running = true,
}

local warned = {}

function M._reset_shim_state()
  warned = {}
end

---@param opts table?
local function warn_unknown_opts(opts)
  for k, v in pairs(opts or {}) do
    local keys_to_check = {}
    if not KNOWN_KEYS[k] then
      keys_to_check[1] = tostring(k)
    elseif k == "keymap" and type(v) == "table" then
      for kk in pairs(v) do
        if not KNOWN_KEYMAP_KEYS[kk] then
          keys_to_check[#keys_to_check + 1] = ("keymap.%s"):format(tostring(kk))
        end
      end
    end
    for _, key in ipairs(keys_to_check) do
      if not warned[key] then
        warned[key] = true
        vim.notify(
          ("[jove] unknown option '%s' (molten-era or typo?) — check :h jove-config"):format(key),
          vim.log.levels.WARN
        )
      end
    end
  end
end

local function validate_config(cfg)
  vim.validate("jupytext", cfg.jupytext, "string")
  vim.validate("bridge_python", cfg.bridge_python, "string")
  vim.validate("auto_kernel", cfg.auto_kernel, "boolean")
  vim.validate("auto_import_outputs", cfg.auto_import_outputs, "boolean")
  vim.validate("auto_export_outputs", cfg.auto_export_outputs, "boolean")
  vim.validate("persist_exec_counts", cfg.persist_exec_counts, "boolean")
  vim.validate("elapsed", cfg.elapsed, "boolean")
  vim.validate("auto_reload", cfg.auto_reload, "boolean")
  vim.validate("cell_motions", cfg.cell_motions, "boolean")
  vim.validate("signs", cfg.signs, "table")
  for _, k in ipairs({ "queued", "running", "ok", "error" }) do
    vim.validate(("signs.%s"):format(k), cfg.signs[k], "string")
  end
  vim.validate("output", cfg.output, "table")
  vim.validate("output.max_lines", cfg.output.max_lines, "number")
  vim.validate("output.max_bytes", cfg.output.max_bytes, "number")
  vim.validate("output.images", cfg.output.images, "boolean")
  vim.validate("output.image_max_width", cfg.output.image_max_width, "number", true)
  vim.validate("output.image_max_height", cfg.output.image_max_height, "number", true)
  vim.validate("output.header", cfg.output.header, "boolean")
  vim.validate("output.guide", cfg.output.guide, is_keymap_lhs) -- string-or-false
  vim.validate("output.inside_border", cfg.output.inside_border, "boolean")
  vim.validate("output.hl", cfg.output.hl, { "string", "table" }, true)
  vim.validate("variables", cfg.variables, "table")
  vim.validate("variables.auto_refresh", cfg.variables.auto_refresh, "boolean")
  vim.validate("variables.width", cfg.variables.width, "number")
  vim.validate("ui", cfg.ui, "table")
  vim.validate("ui.conceal_headers", cfg.ui.conceal_headers, "boolean")
  vim.validate("ui.active_cell", cfg.ui.active_cell, "boolean")
  vim.validate("ui.exec_counts", cfg.ui.exec_counts, "boolean")
  vim.validate("ui.elapsed", cfg.ui.elapsed, "boolean")
  vim.validate("ui.borders", cfg.ui.borders, "boolean")
  vim.validate("ui.border_hl", cfg.ui.border_hl, { "string", "table" }, true)
  vim.validate("ui.window_mode", cfg.ui.window_mode, function(v)
    return v == "float" or v == "vsplit" or v == "hsplit"
  end, '"float", "vsplit", or "hsplit"')
  vim.validate("keymap", cfg.keymap, "table")
  for k, v in pairs(cfg.keymap) do
    vim.validate(("keymap.%s"):format(k), v, is_keymap_lhs)
  end
end

---@param opts jove.Config?
function M.setup(opts)
  vim.validate("opts", opts, "table", true)

  warn_unknown_opts(opts)

  local merged = vim.tbl_deep_extend("force", M.config, opts or {})
  validate_config(merged)

  M.config = merged
  require("jove.keymaps").apply(M.config.keymap)
end

return M

local M = {}

---@class jove.Config.Output  Output rendering options.
---@field max_lines integer                 Max rendered lines per output block.
---@field max_bytes integer                 Per-cell payload cap in bytes (default 1 MiB); streamed tails beyond it are dropped and a truncation marker is shown/persisted.
---@field images boolean                    Render images (via snacks.image) when available.
---@field image_max_width integer|nil       Cap rendered image width in terminal cells; nil disables. Aspect ratio is preserved and images smaller than the cap keep their natural size.
---@field image_max_height integer|nil      Cap rendered image height in terminal cells; nil disables.
---@field header boolean                    Draw the Output block's `┌─ Out[n] ─┐` top frame below each cell; false renders just content with the guide rail, no Output frame.
---@field guide string|false                Per-line inner rail string placed before the text, or false to disable.
---@field inside_border boolean             Render output inside the cell border instead of in its own dedicated bordered block.
---@field hl string|table|nil               Output background tint: an existing hl group name (linked to `JoveOutput`) or attrs passed to `nvim_set_hl`; nil disables.

---@class jove.Config.Variables  Variables inspector options.
---@field auto_refresh boolean
---@field size number  Sidebar size as a fraction of the screen (0 < size < 1, default 0.25): share of columns in vsplit/float mode, share of lines in hsplit mode.

---@class jove.Config.UI
---@field conceal_headers boolean
---@field active_cell boolean
---@field exec_counts boolean
---@field elapsed boolean
---@field borders boolean
---@field border_hl string|table|nil  An existing hl group to link `JoveCellBorder` to, or attrs passed to `nvim_set_hl` for `JoveCellBorder` (e.g. `{ fg = "#ff9e64" }`); nil leaves the default link in place.
---@field window_mode "float"|"vsplit"|"hsplit"  How to open the sidebar (variables, kernel info, TOC), the variable detail view, and the output viewer (default "vsplit").

---@class jove.Config.LSP  LSP integration.
---@field auto_attach boolean         Start the servers listed in `servers` for the notebook's language on open (default false); servers enabled via vim.lsp.enable()/nvim-lspconfig attach on their own regardless.
---@field servers table<string, string[]>  Map of kernelspec language id to vim.lsp.config server names, e.g. { python = { "pyright" } }.

---@class jove.Config
---@field jupytext string                Path to the jupytext binary.
---@field bridge_python string           Python interpreter for the kernel bridge. An active $CONDA_PREFIX or $VIRTUAL_ENV interpreter, then g:python3_host_prog, takes precedence at use time; this is the fallback.
---@field auto_kernel boolean            Start a bridge + kernel on open (kernelspec from notebook metadata, env, or picker).
---@field auto_import_outputs boolean    Import persisted outputs from the .ipynb on open/reload (gates persist.import).
---@field auto_export_outputs boolean    Merge session outputs into the .ipynb on save (gates persist.export).
---@field persist_exec_counts boolean    Persist kernel execution counts into the .ipynb on save.
---@field elapsed boolean                Show per-cell elapsed execution time (UI).
---@field auto_reload boolean            Auto-reload buffer when the .ipynb changes on disk (our own writes are suppressed).
---@field cell_motions boolean           Map [c / ]c cell motions on jove buffers.
---@field signs table<string, string>    Gutter sign chars per cell status: queued/running/ok/error.
---@field output jove.Config.Output
---@field variables jove.Config.Variables
---@field ui jove.Config.UI
---@field lsp jove.Config.LSP

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
    size = 0.25,
  },
  ui = {
    conceal_headers = true,
    active_cell = true,
    exec_counts = true,
    elapsed = true,
    borders = true,
    window_mode = "vsplit",
  },
  lsp = {
    auto_attach = false,
    servers = {},
  },
}

---@param v any
---@return boolean
local function is_string_or_false(v)
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
  lsp = true,
}

local warned = {}

function M._reset_shim_state()
  warned = {}
end

---@param opts table?
local function warn_unknown_opts(opts)
  for k in pairs(opts or {}) do
    if not KNOWN_KEYS[k] and not warned[k] then
      warned[k] = true
      vim.notify(("[Jove] unknown option '%s'"):format(tostring(k)), vim.log.levels.WARN)
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
  vim.validate("output.guide", cfg.output.guide, is_string_or_false)
  vim.validate("output.inside_border", cfg.output.inside_border, "boolean")
  vim.validate("output.hl", cfg.output.hl, { "string", "table" }, true)
  vim.validate("variables", cfg.variables, "table")
  vim.validate("variables.auto_refresh", cfg.variables.auto_refresh, "boolean")
  vim.validate("variables.size", cfg.variables.size, function(v)
    return type(v) == "number" and v > 0 and v < 1
  end, "fraction between 0 and 1")
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
  vim.validate("lsp", cfg.lsp, "table")
  vim.validate("lsp.auto_attach", cfg.lsp.auto_attach, "boolean")
  vim.validate("lsp.servers", cfg.lsp.servers, "table")
  for lang_id, servers in pairs(cfg.lsp.servers) do
    vim.validate(("lsp.servers.%s"):format(lang_id), servers, "table")
    for i, name in ipairs(servers) do
      vim.validate(("lsp.servers.%s[%d]"):format(lang_id, i), name, "string")
    end
  end
end

---@param opts jove.Config?
function M.setup(opts)
  vim.validate("opts", opts, "table", true)
  opts = vim.deepcopy(opts or {})

  if opts.keymap ~= nil then
    vim.deprecate(
      "the jove setup() `keymap` option",
      '<Plug> mappings, e.g. vim.keymap.set("n", "<leader>x", "<Plug>(JoveRunCell)")',
      "0.5.0",
      "jove.nvim"
    )
    opts.keymap = nil
  end

  warn_unknown_opts(opts)

  local merged = vim.tbl_deep_extend("force", M.config, opts)
  validate_config(merged)

  M.config = merged
end

return M

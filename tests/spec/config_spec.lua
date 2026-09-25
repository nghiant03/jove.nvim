local MiniTest = require("mini.test")
local jove = require("jove")

local T = MiniTest.new_set()

local defaults = vim.deepcopy(jove.config)

local function reset_config()
  jove.config = vim.deepcopy(defaults)
end

T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      reset_config()
      jove._reset_shim_state()
    end,
  },
})

T["setup"] = MiniTest.new_set()

T["setup"]["accepts valid opts"] = function()
  jove.setup({
    jupytext = "/usr/local/bin/jupytext",
    auto_kernel = false,
  })
  MiniTest.expect.equality(jove.config.jupytext, "/usr/local/bin/jupytext")
  MiniTest.expect.equality(jove.config.auto_kernel, false)
  MiniTest.expect.equality(jove.config.auto_import_outputs, defaults.auto_import_outputs)
end

T["setup"]["accepts no opts"] = function()
  jove.setup()
  MiniTest.expect.equality(jove.config.jupytext, defaults.jupytext)
  MiniTest.expect.equality(jove.config.bridge_python, defaults.bridge_python)
end

T["setup"]["shim: warns on unknown top-level option"] = function()
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  jove.setup({ molten = {} })
  vim.notify = orig

  MiniTest.expect.equality(#notes, 1)
  MiniTest.expect.equality(notes[1].level, vim.log.levels.WARN)
  MiniTest.expect.equality(notes[1].msg, "[jove] unknown option 'molten'")
  MiniTest.expect.equality(jove.config.molten, {})
end

T["setup"]["shim: deprecated keymap option warns once and is ignored"] = function()
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  jove.setup({ keymap = { run_cell = "<leader>rc" } })
  local after_first = #notes
  jove.setup({ keymap = { run_cell = "<leader>rc" } })
  vim.notify = orig

  MiniTest.expect.equality(after_first >= 1, true)
  MiniTest.expect.equality(#notes, after_first)
  MiniTest.expect.equality(notes[1].level, vim.log.levels.WARN)
  MiniTest.expect.equality(notes[1].msg:match("deprecated") ~= nil, true)
  MiniTest.expect.equality(notes[1].msg:match("<Plug>") ~= nil, true)
  MiniTest.expect.equality(jove.config.keymap, nil)
end

T["setup"]["shim: silent for a fully-valid setup; warns once per key"] = function()
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  jove.setup({
    jupytext = "/x/jupytext",
    signs = { queued = "…" },
  })
  MiniTest.expect.equality(#notes, 0)

  jove.setup({ molten = {} })
  jove.setup({ molten = {} })
  vim.notify = orig
  MiniTest.expect.equality(#notes, 1)
end

T["setup"]["shim: defaults table itself raises zero warnings"] = function()
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  jove.setup(vim.deepcopy(jove.config))
  MiniTest.expect.equality(#notes, 0)
  vim.notify = orig
end

T["setup"]["bridge_python: string type check"] = function()
  MiniTest.expect.error(function()
    jove.setup({ bridge_python = 123 })
  end)
  MiniTest.expect.error(function()
    jove.setup({ bridge_python = true })
  end)
  MiniTest.expect.equality(jove.config.bridge_python, defaults.bridge_python)
end

T["setup"]["bridge_python: merge behavior"] = function()
  jove.setup({ bridge_python = "/opt/venv/bin/python" })
  MiniTest.expect.equality(jove.config.bridge_python, "/opt/venv/bin/python")
  jove.setup({ jupytext = "/other/jupytext" })
  MiniTest.expect.equality(jove.config.bridge_python, "/opt/venv/bin/python")
  MiniTest.expect.equality(jove.config.jupytext, "/other/jupytext")
end

T["setup"]["cell_motions: boolean type check"] = function()
  MiniTest.expect.error(function()
    jove.setup({ cell_motions = "yes" })
  end)
  MiniTest.expect.equality(jove.config.cell_motions, defaults.cell_motions)
end

T["setup"]["signs: char type checks"] = function()
  MiniTest.expect.error(function()
    jove.setup({ signs = { running = 5 } })
  end)
  MiniTest.expect.error(function()
    jove.setup({ signs = "▶" })
  end)
  MiniTest.expect.equality(jove.config.signs.running, defaults.signs.running)
end

T["setup"]["output: nested validation and partial merge"] = function()
  MiniTest.expect.error(function()
    jove.setup({ output = { max_lines = "lots" } })
  end)
  MiniTest.expect.error(function()
    jove.setup({ output = { images = "sure" } })
  end)
  jove.setup({ output = { max_lines = 10 } })
  MiniTest.expect.equality(jove.config.output.max_lines, 10)
  MiniTest.expect.equality(jove.config.output.images, defaults.output.images)
end

T["setup"]["output.image_max_width/height: optional numbers"] = function()
  MiniTest.expect.error(function()
    jove.setup({ output = { image_max_width = "wide" } })
  end)
  MiniTest.expect.error(function()
    jove.setup({ output = { image_max_height = true } })
  end)
  MiniTest.expect.equality(jove.config.output.image_max_width, defaults.output.image_max_width)
  MiniTest.expect.equality(jove.config.output.image_max_height, defaults.output.image_max_height)
  jove.setup({ output = { image_max_width = 120, image_max_height = 10 } })
  MiniTest.expect.equality(jove.config.output.image_max_width, 120)
  MiniTest.expect.equality(jove.config.output.image_max_height, 10)
end

T["setup"]["ui.border_hl: accepts string or table; rejects other types"] = function()
  jove.setup({ ui = { border_hl = "MyBorder" } })
  MiniTest.expect.equality(jove.config.ui.border_hl, "MyBorder")
  jove.setup({ ui = { border_hl = { fg = "#ff9e64", bold = true } } })
  MiniTest.expect.equality(jove.config.ui.border_hl.fg, "#ff9e64")
  MiniTest.expect.equality(jove.config.ui.border_hl.bold, true)
  MiniTest.expect.error(function()
    jove.setup({ ui = { border_hl = 42 } })
  end)
  MiniTest.expect.error(function()
    jove.setup({ ui = { border_hl = true } })
  end)
  -- Successful setup after the errors must still leave a valid config;
  -- vim.validate on the failed calls runs before M.config is reassigned,
  -- so earlier good values are preserved.
  jove.setup({ ui = { border_hl = "MyBorder" } })
  MiniTest.expect.equality(jove.config.ui.border_hl, "MyBorder")
  -- Resetting ui and re-setup without border_hl drops it (post-reset
  -- mutation; defaults table does not contain border_hl at all).
  jove.config = vim.deepcopy(defaults)
  jove._reset_shim_state()
  jove.setup({ ui = { borders = false } })
  MiniTest.expect.equality(jove.config.ui.border_hl, nil)
end

T["setup"]["ui.window_mode: accepts float/vsplit/hsplit; rejects other values"] = function()
  MiniTest.expect.equality(defaults.ui.window_mode, "vsplit")
  jove.setup({ ui = { window_mode = "float" } })
  MiniTest.expect.equality(jove.config.ui.window_mode, "float")
  jove.setup({ ui = { window_mode = "hsplit" } })
  MiniTest.expect.equality(jove.config.ui.window_mode, "hsplit")
  MiniTest.expect.error(function()
    jove.setup({ ui = { window_mode = "popup" } })
  end)
  MiniTest.expect.error(function()
    jove.setup({ ui = { window_mode = 42 } })
  end)
  MiniTest.expect.equality(jove.config.ui.window_mode, "hsplit")
end

T["setup"]["raises on invalid opt types"] = function()
  MiniTest.expect.error(function()
    jove.setup({ jupytext = 123 })
  end)
  MiniTest.expect.error(function()
    jove.setup({ bridge_python = 123 })
  end)
  MiniTest.expect.error(function()
    jove.setup({ auto_kernel = "yes" })
  end)
  MiniTest.expect.error(function()
    jove.setup({ auto_import_outputs = 1 })
  end)
  MiniTest.expect.error(function()
    jove.setup({ auto_export_outputs = "no" })
  end)
  MiniTest.expect.error(function()
    jove.setup("not a table")
  end)
  MiniTest.expect.equality(jove.config.jupytext, defaults.jupytext)
end

T["setup"]["lsp: nested validation and merge"] = function()
  MiniTest.expect.equality(jove.config.lsp.auto_attach, false)
  MiniTest.expect.error(function()
    jove.setup({ lsp = { auto_attach = "yes" } })
  end)
  MiniTest.expect.error(function()
    jove.setup({ lsp = { servers = "pyright" } })
  end)
  MiniTest.expect.error(function()
    jove.setup({ lsp = { servers = { python = "pyright" } } })
  end)
  MiniTest.expect.error(function()
    jove.setup({ lsp = { servers = { python = { 42 } } } })
  end)
  jove.setup({ lsp = { auto_attach = true, servers = { python = { "pyright" } } } })
  MiniTest.expect.equality(jove.config.lsp.auto_attach, true)
  MiniTest.expect.equality(jove.config.lsp.servers.python, { "pyright" })
end

T["setup"]["called twice is safe (no duplicate FileType autocmds)"] = function()
  -- The FileType autocmd for <Plug> mappings is registered once at plugin
  -- load (plugin/jove.lua), not by setup(). nvim_get_autocmds returns one
  -- record per pattern (python/julia/r/javascript/typescript).
  local before = vim.api.nvim_get_autocmds({ group = "jove_keymaps", event = "FileType" })

  jove.setup({})
  jove.setup({})
  jove.setup({})
  local after = vim.api.nvim_get_autocmds({ group = "jove_keymaps", event = "FileType" })

  MiniTest.expect.equality(#before, 5)
  MiniTest.expect.equality(#after, #before)
end

return T

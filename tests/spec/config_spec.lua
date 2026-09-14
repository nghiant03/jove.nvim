-- config_spec.lua: setup() validation and idempotency.
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
    keymap = { run_cell = "<leader>rc" },
  })
  MiniTest.expect.equality(jove.config.jupytext, "/usr/local/bin/jupytext")
  MiniTest.expect.equality(jove.config.auto_kernel, false)
  MiniTest.expect.equality(jove.config.keymap.run_cell, "<leader>rc")
  -- Unspecified fields keep their defaults.
  MiniTest.expect.equality(jove.config.auto_import_outputs, defaults.auto_import_outputs)
end

T["setup"]["accepts no opts"] = function()
  jove.setup()
  MiniTest.expect.equality(jove.config.jupytext, defaults.jupytext)
  MiniTest.expect.equality(jove.config.bridge_python, defaults.bridge_python)
end

T["setup"]["shim: warns on unknown top-level option (molten-era or typo)"] = function()
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  jove.setup({ molten = {} })
  vim.notify = orig

  MiniTest.expect.equality(#notes, 1)
  MiniTest.expect.equality(notes[1].level, vim.log.levels.WARN)
  MiniTest.expect.equality(
    notes[1].msg,
    "[jove] unknown option 'molten' (molten-era or typo?) — check :h jove-config"
  )
  -- Permissive: the option still merges, nothing errors.
  MiniTest.expect.equality(jove.config.molten, {})
end

T["setup"]["shim: warns on unknown keymap member; validates known ones still"] = function()
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  jove.setup({ keymap = { bogus = "x" } })
  vim.notify = orig

  MiniTest.expect.equality(#notes, 1)
  MiniTest.expect.equality(
    notes[1].msg,
    "[jove] unknown option 'keymap.bogus' (molten-era or typo?) — check :h jove-config"
  )
  MiniTest.expect.equality(jove.config.keymap.bogus, "x")
  -- Known keymap members are still validated: a bad type still errors.
  MiniTest.expect.error(function()
    jove.setup({ keymap = { run_cell = 42 } })
  end)
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
    keymap = { run_cell = "<cr>" },
  })
  MiniTest.expect.equality(#notes, 0)

  -- Second setup with the same unknown key: warns only once per key.
  jove.setup({ molten = {} })
  jove.setup({ molten = {} })
  vim.notify = orig
  MiniTest.expect.equality(#notes, 1)
end

-- Structural pin: the DEFAULTS table must be fully covered by the shim's
-- allowlists (KNOWN_KEYS + KNOWN_KEYMAP_KEYS). Feeding the defaults back as
-- opts must produce ZERO warnings — a future key added to config without
-- updating the allowlists fails here instead of shipping a false warning.
T["setup"]["shim: defaults table itself raises zero warnings"] = function()
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  jove.setup(vim.deepcopy(jove.config))
  MiniTest.expect.equality(#notes, 0)
  -- The documented keymap.run_selection is allowlisted too (README example).
  jove.setup({ keymap = { run_selection = "<leader>rs" } })
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
  -- Failed setup must not corrupt the stored default.
  MiniTest.expect.equality(jove.config.bridge_python, defaults.bridge_python)
end

T["setup"]["bridge_python: merge behavior"] = function()
  jove.setup({ bridge_python = "/opt/venv/bin/python" })
  MiniTest.expect.equality(jove.config.bridge_python, "/opt/venv/bin/python")
  -- A later setup() without the key keeps the previously merged value.
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
    jove.setup({ keymap = { run_cell = 42 } })
  end)
  MiniTest.expect.error(function()
    jove.setup("not a table")
  end)
  -- Failed setup must not corrupt the stored config.
  MiniTest.expect.equality(jove.config.jupytext, defaults.jupytext)
end

T["setup"]["called twice is safe (no duplicate FileType autocmds)"] = function()
  local keymaps = {
    run_cell = "<leader>x",
    next_cell = "<leader>n",
    prev_cell = "<leader>p",
  }
  jove.setup({ keymap = keymaps })
  local after_first = vim.api.nvim_get_autocmds({ group = "jove_keymaps", event = "FileType" })

  jove.setup({ keymap = keymaps })
  jove.setup({ keymap = keymaps })
  local after_third = vim.api.nvim_get_autocmds({ group = "jove_keymaps", event = "FileType" })

  -- nvim_get_autocmds returns one record per pattern (python/julia/r/
  -- javascript). A single apply() registers 3 keymap autocmds + 1 built-in
  -- text-object autocmd = 4 FileType autocmds = 16 records; repeated setup()
  -- calls must not grow that count.
  MiniTest.expect.equality(#after_first, 16)
  MiniTest.expect.equality(#after_third, #after_first)
end

return T

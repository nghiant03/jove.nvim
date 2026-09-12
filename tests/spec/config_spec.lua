-- config_spec.lua: setup() validation and idempotency.
local MiniTest = require("mini.test")
local jove = require("jove")

local T = MiniTest.new_set()

local defaults = vim.deepcopy(jove.config)

local function reset_config()
  jove.config = vim.deepcopy(defaults)
end

T = MiniTest.new_set({ hooks = { pre_case = reset_config } })

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
end

T["setup"]["raises on invalid opt types"] = function()
  MiniTest.expect.error(function()
    jove.setup({ jupytext = 123 })
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

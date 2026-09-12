-- jove.nvim: native .ipynb editing via jupytext + molten.
-- This file only registers autocmds; configuration lives in lua/jove/init.lua.

if vim.g.loaded_jove == 1 then
  return
end
vim.g.loaded_jove = 1

if vim.fn.has("nvim-0.10") ~= 1 then
  vim.notify("[jove] requires Neovim >= 0.10", vim.log.levels.ERROR)
  return
end

-- Refuse to load alongside jupytext.nvim to avoid duplicate BufReadCmd.
if vim.g.loaded_jupytext == 1 or package.loaded["jupytext"] then
  vim.notify(
    "[jove] jupytext.nvim detected; jove.nvim will not register handlers. "
      .. "Disable one of them.",
    vim.log.levels.WARN
  )
  return
end

local group = vim.api.nvim_create_augroup("jove", { clear = true })

vim.api.nvim_create_autocmd({ "BufReadCmd" }, {
  group = group,
  pattern = { "*.ipynb" },
  callback = function(ev)
    require("jove.buffer").read(ev.buf, ev.match)
  end,
})

vim.api.nvim_create_autocmd({ "BufWriteCmd" }, {
  group = group,
  pattern = { "*.ipynb" },
  callback = function(ev)
    require("jove.buffer").write(ev.buf, ev.match)
  end,
})

vim.api.nvim_create_autocmd({ "FileChangedShell" }, {
  group = group,
  pattern = { "*.ipynb" },
  callback = function(ev)
    -- true: the change is our own last write -> suppress silently.
    -- false: config.auto_reload is on and a reload was scheduled -> nothing
    -- else to do (v:fcs_choice stays empty, so the default handler no-ops).
    if require("jove.buffer").changed_shell(ev.buf, ev.match) ~= nil then
      return
    end
    vim.notify(
      ("[jove] %s changed on disk; reload with :JoveReload to pick up changes."):format(ev.match),
      vim.log.levels.WARN
    )
  end,
})

vim.api.nvim_create_user_command("JoveRunCell", function()
  require("jove.keymaps").run_cell()
end, { desc = "Run current notebook cell via molten" })

vim.api.nvim_create_user_command("JoveRunAbove", function()
  require("jove.keymaps").run_above()
end, { desc = "Run all notebook cells above the cursor" })

vim.api.nvim_create_user_command("JoveRunAll", function()
  require("jove.keymaps").run_all()
end, { desc = "Run all notebook cells" })

vim.api.nvim_create_user_command("JoveNextCell", function()
  require("jove.keymaps").next_cell()
end, { desc = "Jump to next notebook cell" })

vim.api.nvim_create_user_command("JovePrevCell", function()
  require("jove.keymaps").prev_cell()
end, { desc = "Jump to previous notebook cell" })

vim.api.nvim_create_user_command("JoveInitKernel", function()
  require("jove.kernel").init(0)
end, { desc = "Initialize molten kernel for current notebook" })

vim.api.nvim_create_user_command("JoveImportOutputs", function()
  require("jove.outputs").import(0)
end, { desc = "Import existing outputs from .ipynb JSON into molten" })

vim.api.nvim_create_user_command("JoveExportOutputs", function()
  require("jove.outputs").export(0)
end, { desc = "Export molten outputs back into the .ipynb on disk" })

vim.api.nvim_create_user_command("JoveReload", function()
  require("jove.buffer").reload(0)
end, { desc = "Reload the current notebook buffer from disk" })

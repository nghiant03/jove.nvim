-- jove.nvim: native .ipynb editing via jupytext + molten.
-- This file only registers autocmds; configuration lives in lua/ipynb/init.lua.

if vim.g.loaded_ipynb == 1 then
  return
end
vim.g.loaded_ipynb = 1

if vim.fn.has("nvim-0.10") ~= 1 then
  vim.notify("[ipynb] requires Neovim >= 0.10", vim.log.levels.ERROR)
  return
end

-- Refuse to load alongside jupytext.nvim to avoid duplicate BufReadCmd.
if vim.g.loaded_jupytext == 1 or package.loaded["jupytext"] then
  vim.notify(
    "[ipynb] jupytext.nvim detected; jove.nvim will not register handlers. "
      .. "Disable one of them.",
    vim.log.levels.WARN
  )
  return
end

local group = vim.api.nvim_create_augroup("ipynb", { clear = true })

vim.api.nvim_create_autocmd({ "BufReadCmd" }, {
  group = group,
  pattern = { "*.ipynb" },
  callback = function(ev)
    require("ipynb.buffer").read(ev.buf, ev.match)
  end,
})

vim.api.nvim_create_autocmd({ "BufWriteCmd" }, {
  group = group,
  pattern = { "*.ipynb" },
  callback = function(ev)
    require("ipynb.buffer").write(ev.buf, ev.match)
  end,
})

vim.api.nvim_create_autocmd({ "FileChangedShell" }, {
  group = group,
  pattern = { "*.ipynb" },
  callback = function(ev)
    vim.notify(
      ("[ipynb] %s changed on disk; reload with :e to pick up changes."):format(ev.match),
      vim.log.levels.WARN
    )
  end,
})

vim.api.nvim_create_user_command("IpynbRunCell", function()
  require("ipynb.keymaps").run_cell()
end, { desc = "Run current notebook cell via molten" })

vim.api.nvim_create_user_command("IpynbRunAbove", function()
  require("ipynb.keymaps").run_above()
end, { desc = "Run all notebook cells above the cursor" })

vim.api.nvim_create_user_command("IpynbRunAll", function()
  require("ipynb.keymaps").run_all()
end, { desc = "Run all notebook cells" })

vim.api.nvim_create_user_command("IpynbNextCell", function()
  require("ipynb.keymaps").next_cell()
end, { desc = "Jump to next notebook cell" })

vim.api.nvim_create_user_command("IpynbPrevCell", function()
  require("ipynb.keymaps").prev_cell()
end, { desc = "Jump to previous notebook cell" })

vim.api.nvim_create_user_command("IpynbInitKernel", function()
  require("ipynb.kernel").init(0)
end, { desc = "Initialize molten kernel for current notebook" })

vim.api.nvim_create_user_command("IpynbImportOutputs", function()
  require("ipynb.outputs").import(0)
end, { desc = "Import existing outputs from .ipynb JSON into molten" })

vim.api.nvim_create_user_command("IpynbExportOutputs", function()
  require("ipynb.outputs").export(0)
end, { desc = "Export molten outputs back into the .ipynb on disk" })

-- jove.nvim: native .ipynb editing via jupytext + a first-party kernel bridge.
-- Registers notebook autocmds and commands; configuration lives in lua/jove/init.lua.

if vim.g.loaded_jove == 1 then
  return
end
vim.g.loaded_jove = 1

if vim.fn.has("nvim-0.11") ~= 1 then
  vim.notify("[jove] requires Neovim >= 0.11", vim.log.levels.ERROR)
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
end, { desc = "Run current notebook cell" })

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
end, { desc = "Start a kernel for the current notebook" })

vim.api.nvim_create_user_command("JoveSelectKernel", function()
  require("jove.kernel").select(0)
end, { desc = "Pick a kernelspec for the current notebook (replaces running kernel)" })

vim.api.nvim_create_user_command("JoveInterrupt", function()
  require("jove.execute").interrupt(0)
end, { desc = "Interrupt the running execution" })

vim.api.nvim_create_user_command("JoveRestartKernel", function()
  require("jove.kernel").restart(0)
end, { desc = "Restart the current notebook kernel" })

vim.api.nvim_create_user_command("JoveShutdownKernel", function()
  require("jove.kernel").shutdown(0)
end, { desc = "Shut down the current notebook kernel and bridge" })

vim.api.nvim_create_user_command("JoveRunSelection", function()
  require("jove.execute").run_selection(0)
end, { desc = "Run the visual selection as one unit" })

vim.api.nvim_create_user_command("JoveRunCellAndAdvance", function()
  require("jove.execute").run_cell_and_advance(0)
end, { desc = "Run the current cell and jump to the next" })

vim.api.nvim_create_user_command("JoveToggleOutput", function()
  require("jove.output").toggle(0)
end, { desc = "Show/hide rendered outputs of the current cell" })

vim.api.nvim_create_user_command("JoveOpenOutput", function()
  require("jove.output").open_float(0)
end, { desc = "Open the current cell's outputs in a float" })

vim.api.nvim_create_user_command("JoveClearOutput", function()
  local c = require("jove.cell").at(0, vim.fn.line("."))
  if c then
    require("jove.output").clear(0, c.hash)
  end
end, { desc = "Clear outputs of the current cell" })

vim.api.nvim_create_user_command("JoveClearOutputs", function()
  require("jove.output").clear(0)
end, { desc = "Clear all rendered outputs in this buffer" })

vim.api.nvim_create_user_command("JoveReload", function()
  require("jove.buffer").reload(0)
end, { desc = "Reload the current notebook buffer from disk" })

vim.api.nvim_create_user_command("JoveVariables", function()
  require("jove.ui.vars").toggle(0)
end, { desc = "Toggle the variable inspector sidebar" })

vim.api.nvim_create_user_command("JoveKernelInfo", function()
  local float = require("jove.ui.panel").info_float(0)
  local win = vim.api.nvim_open_win(float.buf, true, float.opts)
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  vim.keymap.set(
    "n",
    "q",
    close,
    { buffer = float.buf, nowait = true, silent = true, desc = "Jove: Close Kernel Panel" }
  )
  vim.keymap.set(
    "n",
    "<Esc>",
    close,
    { buffer = float.buf, nowait = true, silent = true, desc = "Jove: Close Kernel Panel" }
  )
end, { desc = "Show kernel panel (current session, running kernels, installed kernelspecs)" })

vim.api.nvim_create_user_command("JoveToc", function()
  require("jove.toc").pick(0)
end, { desc = "Show a table of contents for the current notebook" })

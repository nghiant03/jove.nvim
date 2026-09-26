if vim.g.loaded_jove == 1 then
  return
end
vim.g.loaded_jove = 1

if vim.fn.has("nvim-0.11") ~= 1 then
  vim.notify("[Jove] requires Neovim >= 0.11", vim.log.levels.ERROR)
  return
end

if vim.g.loaded_jupytext == 1 or package.loaded["jupytext"] then
  vim.notify(
    "[Jove] jupytext.nvim detected, jove.nvim will not register handlers. "
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
    if require("jove.buffer").changed_shell(ev.buf, ev.match) ~= nil then
      return
    end
    vim.notify(
      ("[Jove] %s changed on disk; reload with :Jove reload to pick up changes."):format(ev.match),
      vim.log.levels.WARN
    )
  end,
})

local keymaps_group = vim.api.nvim_create_augroup("jove_keymaps", { clear = true })

vim.api.nvim_create_autocmd("FileType", {
  group = keymaps_group,
  pattern = { "python", "julia", "r", "javascript", "typescript" },
  desc = "Jove: built-in cell text-objects, motions, <Plug> mappings",
  callback = function(ev)
    require("jove.keymaps").on_filetype(ev.buf)
  end,
})

vim.api.nvim_create_user_command("Jove", function(opts)
  require("jove.commands").dispatch(opts)
end, {
  nargs = "+",
  desc = "Jove notebook commands: :Jove <subcommand>",
  complete = function(arg_lead, cmdline)
    return require("jove.commands").complete(arg_lead, cmdline)
  end,
})

local legacy = {
  JoveClearOutput = "clear-output",
  JoveClearOutputs = "clear-outputs",
  JoveGotoRunningCell = "goto-running-cell",
  JoveInitKernel = "init-kernel",
  JoveInterrupt = "interrupt",
  JoveNextCell = "next-cell",
  JoveOpenOutput = "open-output",
  JovePrevCell = "prev-cell",
  JoveReload = "reload",
  JoveRestartKernel = "restart-kernel",
  JoveRunAbove = "run-above",
  JoveRunAll = "run-all",
  JoveRunCell = "run-cell",
  JoveRunCellAndAdvance = "run-cell-and-advance",
  JoveRunSelection = "run-selection",
  JoveSelectKernel = "select-kernel",
  JoveShutdownKernel = "shutdown-kernel",
  JoveSidebar = "sidebar",
  JoveToggleFollowRunning = "toggle-follow-running",
  JoveToggleOutput = "toggle-output",
}
for old, sub in pairs(legacy) do
  vim.api.nvim_create_user_command(old, function()
    vim.deprecate(":" .. old, ":Jove " .. sub, "0.5.0", "jove.nvim")
    require("jove.commands").dispatch({ fargs = { sub } })
  end, { desc = ("Deprecated, use :Jove %s"):format(sub) })
end

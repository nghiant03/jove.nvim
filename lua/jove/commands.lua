--- Subcommanded :Jove command dispatcher.

local M = {}

---@class jove.Subcommand
---@field impl fun()
---@field desc string

---@type table<string, jove.Subcommand>
M.subcommands = {
  ["run-cell"] = {
    impl = function()
      require("jove.keymaps").run_cell()
    end,
    desc = "Run current notebook cell",
  },
  ["run-above"] = {
    impl = function()
      require("jove.keymaps").run_above()
    end,
    desc = "Run all notebook cells above the cursor",
  },
  ["run-all"] = {
    impl = function()
      require("jove.keymaps").run_all()
    end,
    desc = "Run all notebook cells",
  },
  ["next-cell"] = {
    impl = function()
      require("jove.keymaps").next_cell()
    end,
    desc = "Jump to next notebook cell",
  },
  ["prev-cell"] = {
    impl = function()
      require("jove.keymaps").prev_cell()
    end,
    desc = "Jump to previous notebook cell",
  },
  ["goto-running-cell"] = {
    impl = function()
      require("jove.keymaps").goto_running_cell()
    end,
    desc = "Jump to the currently executing cell",
  },
  ["toggle-follow-running"] = {
    impl = function()
      require("jove.keymaps").toggle_follow_running()
    end,
    desc = "Toggle following the currently executing cell with the cursor",
  },
  ["init-kernel"] = {
    impl = function()
      require("jove.kernel").init(0)
    end,
    desc = "Start a kernel for the current notebook",
  },
  ["select-kernel"] = {
    impl = function()
      require("jove.kernel").select(0)
    end,
    desc = "Pick a kernelspec for the current notebook (replaces running kernel)",
  },
  ["interrupt"] = {
    impl = function()
      require("jove.execute").interrupt(0)
    end,
    desc = "Interrupt the running execution",
  },
  ["restart-kernel"] = {
    impl = function()
      require("jove.kernel").restart(0)
    end,
    desc = "Restart the current notebook kernel",
  },
  ["shutdown-kernel"] = {
    impl = function()
      require("jove.kernel").shutdown(0)
    end,
    desc = "Shut down the current notebook kernel and bridge",
  },
  ["run-selection"] = {
    impl = function()
      require("jove.execute").run_selection(0)
    end,
    desc = "Run the visual selection as one unit",
  },
  ["run-cell-and-advance"] = {
    impl = function()
      require("jove.execute").run_cell_and_advance(0)
    end,
    desc = "Run the current cell and jump to the next",
  },
  ["toggle-output"] = {
    impl = function()
      require("jove.output").toggle(0)
    end,
    desc = "Show/hide rendered outputs of the current cell",
  },
  ["open-output"] = {
    impl = function()
      require("jove.output").open_float(0)
    end,
    desc = "Open the current cell's outputs in a float",
  },
  ["clear-output"] = {
    impl = function()
      require("jove.output").clear_at_cursor(0)
    end,
    desc = "Clear outputs of the current cell",
  },
  ["clear-outputs"] = {
    impl = function()
      require("jove.output").clear(0)
    end,
    desc = "Clear all rendered outputs in this buffer",
  },
  ["reload"] = {
    impl = function()
      require("jove.buffer").reload(0)
    end,
    desc = "Reload the current notebook buffer from disk",
  },
  ["sidebar"] = {
    impl = function()
      require("jove.ui.sidebar").toggle(0)
    end,
    desc = "Toggle the sidebar (variables, kernel info, table of contents)",
  },
}

---@return string[] names  sorted subcommand names
function M.names()
  local names = vim.tbl_keys(M.subcommands)
  table.sort(names)
  return names
end

---@param opts {fargs: string[]}
function M.dispatch(opts)
  local name = opts.fargs[1]
  local sub = name and M.subcommands[name]
  if not sub then
    vim.notify(
      ("[jove] unknown subcommand '%s' (expected one of: %s)"):format(
        tostring(name),
        table.concat(M.names(), ", ")
      ),
      vim.log.levels.ERROR
    )
    return
  end
  sub.impl()
end

---@param arg_lead string
---@param cmdline string
---@return string[]
function M.complete(arg_lead, cmdline)
  if cmdline:match("^%s*Jove%s+%S+%s") then
    return {}
  end
  return vim
    .iter(M.names())
    :filter(function(name)
      return name:find(arg_lead, 1, true) == 1
    end)
    :totable()
end

return M

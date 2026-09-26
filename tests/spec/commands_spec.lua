---@diagnostic disable: duplicate-set-field
local MiniTest = require("mini.test")
local commands = require("jove.commands")

local T = MiniTest.new_set()

T = MiniTest.new_set({
  hooks = {
    post_case = function()
      commands.subcommands["test-dummy"] = nil
    end,
  },
})

T["plugin"] = MiniTest.new_set()

T["plugin"]["registers :Jove plus deprecated legacy aliases"] = function()
  MiniTest.expect.equality(vim.fn.exists(":Jove"), 2)
  MiniTest.expect.equality(vim.fn.exists(":JoveRunCell"), 2)
  MiniTest.expect.equality(vim.fn.exists(":JoveSidebar"), 2)
end

T["dispatch"] = MiniTest.new_set()

T["dispatch"]["invokes the subcommand impl"] = function()
  local called = 0
  commands.subcommands["test-dummy"] = {
    impl = function()
      called = called + 1
    end,
    desc = "test seam",
  }
  commands.dispatch({ fargs = { "test-dummy" } })
  MiniTest.expect.equality(called, 1)
end

T["dispatch"]["unknown subcommand notifies an error"] = function()
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  commands.dispatch({ fargs = { "bogus" } })
  vim.notify = orig

  MiniTest.expect.equality(#notes, 1)
  MiniTest.expect.equality(notes[1].level, vim.log.levels.ERROR)
  MiniTest.expect.equality(notes[1].msg:match("unknown subcommand 'bogus'") ~= nil, true)
end

T["dispatch"]["missing subcommand notifies an error"] = function()
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  commands.dispatch({ fargs = {} })
  vim.notify = orig

  MiniTest.expect.equality(#notes, 1)
  MiniTest.expect.equality(notes[1].level, vim.log.levels.ERROR)
end

T["complete"] = MiniTest.new_set()

T["complete"]["filters subcommands by prefix"] = function()
  local items = commands.complete("run", "Jove run")
  MiniTest.expect.equality(vim.tbl_contains(items, "run-cell"), true)
  MiniTest.expect.equality(vim.tbl_contains(items, "run-all"), true)
  MiniTest.expect.equality(vim.tbl_contains(items, "sidebar"), false)
end

T["complete"]["lists everything on empty lead"] = function()
  MiniTest.expect.equality(#commands.complete("", "Jove "), #commands.names())
end

T["complete"]["offers nothing past the subcommand argument"] = function()
  MiniTest.expect.equality(commands.complete("", "Jove run-cell "), {})
end

return T

-- Sidebar interaction with a stubbed bridge; Python tests cover variable inspection.
local MiniTest = require("mini.test")
local state = require("jove.state")
local vars = require("jove.ui.vars")

local T = MiniTest.new_set()

local created, real_variables, saved_config_variables

---@param cond any
local function expect_truthy(cond)
  MiniTest.expect.equality(cond == true, true)
end

---@param lines string[]
---@return integer
local function make_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  state.get(buf).path = "fake.ipynb"
  created[#created + 1] = buf
  return buf
end

---@param win integer
---@return string
local function win_text(win)
  local fbuf = vim.api.nvim_win_get_buf(win)
  return table.concat(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false), "\n")
end

T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      created = {}
      real_variables = vars._variables
      saved_config_variables = require("jove").config.variables
      require("jove").config.variables = { width = 40, auto_refresh = false }
    end,
    post_case = function()
      for _, buf in ipairs(created) do
        pcall(vars.close, buf)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
      vars._variables = real_variables
      require("jove").config.variables = saved_config_variables
    end,
  },
})

T["format"] = MiniTest.new_set()

T["format"]["renders name, type, and value columns"] = function()
  local lines = vars.format({
    { name = "alpha", type = "int", value = "42" },
    { name = "beta", type = "str", value = "'hello'" },
  }, 40)
  MiniTest.expect.equality(#lines, 2)
  expect_truthy(lines[1]:find("alpha", 1, true) ~= nil)
  expect_truthy(lines[1]:find("int", 1, true) ~= nil)
  expect_truthy(lines[1]:find("42", 1, true) ~= nil)
  expect_truthy(lines[2]:find("'hello'", 1, true) ~= nil)
end

T["format"]["truncates long values to fit the width"] = function()
  local lines = vars.format({
    { name = "n", type = "list", value = string.rep("x", 200) },
  }, 30)
  MiniTest.expect.equality(#lines, 1)
  expect_truthy(vim.fn.strdisplaywidth(lines[1]) <= 30)
  expect_truthy(lines[1]:find("…", 1, true) ~= nil)
end

T["format"]["flattens embedded newlines in values for sidebar rows"] = function()
  local lines = vars.format({
    { name = "df", type = "DataFrame", value = "   a\n0  1\n1  2" },
  }, 40)
  MiniTest.expect.equality(#lines, 1)
  expect_truthy(not lines[1]:find("\n", 1, true))
  expect_truthy(lines[1]:find("a", 1, true) ~= nil)
end

T["format"]["keeps empty values empty"] = function()
  local lines = vars.format({
    { name = "n", type = "NoneType", value = "" },
  }, 40)
  MiniTest.expect.equality(#lines, 1)
  expect_truthy(not lines[1]:find("\n", 1, true))
  expect_truthy(lines[1]:find("NoneType", 1, true) ~= nil)
end

T["format"]["handles the empty case"] = function()
  MiniTest.expect.equality(vars.format({}, 40), { "[no variables]" })
  MiniTest.expect.equality(vars.format(nil, 40), { "[no variables]" })
end

T["sidebar"] = MiniTest.new_set()

T["sidebar"]["open fetches through the bridge seam, renders, and closes"] = function()
  local buf = make_buffer({ "# %%", "x = 1" })
  local called = 0
  vars._variables = function(_, cb)
    called = called + 1
    cb({
      variables = {
        { name = "alpha", type = "int", value = "42" },
        { name = "beta", type = "str", value = "'hello'" },
      },
    })
  end

  local win = vars.open(buf)
  expect_truthy(win ~= nil)
  MiniTest.expect.equality(vars.is_open(buf), true)
  MiniTest.expect.equality(called, 1)
  local text = win_text(win)
  expect_truthy(text:find("alpha", 1, true) ~= nil)
  expect_truthy(text:find("'hello'", 1, true) ~= nil)

  vars.close(buf)
  MiniTest.expect.equality(vars.is_open(buf), false)
end

T["sidebar"]["toggle opens then closes"] = function()
  local buf = make_buffer({ "# %%", "x = 1" })
  vars._variables = function(_, cb)
    cb({ variables = {} })
  end
  vars.toggle(buf)
  MiniTest.expect.equality(vars.is_open(buf), true)
  vars.toggle(buf)
  MiniTest.expect.equality(vars.is_open(buf), false)
end

T["sidebar"]["shows the unsupported marker for non-python kernels"] = function()
  local buf = make_buffer({ "# %%", "x = 1" })
  vars._variables = function(_, cb)
    cb({ variables = nil, unsupported = "julia" })
  end
  local win = vars.open(buf)
  expect_truthy(win_text(win):find("unsupported for julia", 1, true) ~= nil)
  vars.close(buf)
end

T["sidebar"]["refresh re-queries and re-renders"] = function()
  local buf = make_buffer({ "# %%", "x = 1" })
  local payload = { variables = { { name = "first", type = "int", value = "1" } } }
  vars._variables = function(_, cb)
    cb(payload)
  end
  local win = vars.open(buf)
  expect_truthy(win_text(win):find("first", 1, true) ~= nil)

  payload = { variables = { { name = "second", type = "str", value = "2" } } }
  vars.refresh(buf)
  expect_truthy(win_text(win):find("second", 1, true) ~= nil)
  vars.close(buf)
end

T["sidebar"]["opens a vertical split by default and a float when configured"] = function()
  local buf = make_buffer({ "# %%", "x = 1" })
  vars._variables = function(_, cb)
    cb({ variables = {} })
  end

  local jove = require("jove")
  local saved = jove.config.ui.window_mode

  jove.config.ui.window_mode = "vsplit"
  local win = vars.open(buf)
  expect_truthy(win ~= nil)
  MiniTest.expect.equality(vim.api.nvim_win_get_config(win).relative, "")
  vars.close(buf)

  jove.config.ui.window_mode = "float"
  win = vars.open(buf)
  expect_truthy(win ~= nil)
  MiniTest.expect.equality(vim.api.nvim_win_get_config(win).relative, "editor")
  vars.close(buf)

  jove.config.ui.window_mode = saved
end

return T

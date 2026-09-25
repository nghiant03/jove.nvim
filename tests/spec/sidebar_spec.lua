local MiniTest = require("mini.test")
local state = require("jove.state")
local vars = require("jove.ui.vars")
local sidebar = require("jove.ui.sidebar")

local T = MiniTest.new_set()

local created, real_variables, real_kernelspecs, saved_config_variables

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

---@param win integer
---@return string[] hl_groups
local function tab_hl_groups(win)
  local fbuf = vim.api.nvim_win_get_buf(win)
  local marks = vim.api.nvim_buf_get_extmarks(fbuf, -1, { 0, 0 }, { 0, -1 }, { details = true })
  local groups = {}
  for _, m in ipairs(marks) do
    groups[#groups + 1] = m[4].hl_group
  end
  return groups
end

---@param groups string[]
---@param name string
---@return boolean
local function has_group(groups, name)
  for _, g in ipairs(groups) do
    if g == name then
      return true
    end
  end
  return false
end

T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      created = {}
      real_variables = vars._variables
      real_kernelspecs = sidebar._kernelspecs
      saved_config_variables = require("jove").config.variables
      require("jove").config.variables = { size = 0.4, auto_refresh = false }
      vars._variables = function(_, cb)
        cb({ variables = { { name = "alpha", type = "int", value = "42" } } })
      end
      sidebar._kernelspecs = function(cb)
        cb({ { name = "python3", display_name = "Python 3", language = "python" } })
      end
    end,
    post_case = function()
      for _, buf in ipairs(created) do
        pcall(sidebar.close, buf)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
      vars._variables = real_variables
      sidebar._kernelspecs = real_kernelspecs
      require("jove").config.variables = saved_config_variables
    end,
  },
})

T["tabs"] = MiniTest.new_set()

T["tabs"]["tab bar names every tab with its switch key"] = function()
  local buf = make_buffer({ "# %%", "x = 1" })
  local win = sidebar.open(buf, "vars")
  expect_truthy(win ~= nil)
  local text = win_text(win)
  expect_truthy(text:find("1 Variables", 1, true) ~= nil)
  expect_truthy(text:find("2 Kernel", 1, true) ~= nil)
  expect_truthy(text:find("3 TOC", 1, true) ~= nil)
  sidebar.close(buf)
end

T["tabs"]["buffer-local number keys switch tabs"] = function()
  local buf = make_buffer({ "# %%", "x = 1" })
  local win = sidebar.open(buf, "vars")
  local fbuf = vim.api.nvim_win_get_buf(win)
  local mapped = {}
  for _, km in ipairs(vim.api.nvim_buf_get_keymap(fbuf, "n")) do
    mapped[km.lhs] = true
  end
  expect_truthy(mapped["1"] == true)
  expect_truthy(mapped["2"] == true)
  expect_truthy(mapped["3"] == true)
  expect_truthy(mapped["q"] == true)
  expect_truthy(mapped["r"] == true)
  sidebar.close(buf)
end

T["tabs"]["switching swaps content and the active-tab highlight"] = function()
  local buf = make_buffer({
    "# %% [markdown]",
    "# # Title A",
    "# %% code",
    "x = 1",
  })
  local win = sidebar.open(buf, "vars")
  MiniTest.expect.equality(sidebar.current_tab(buf), "vars")
  expect_truthy(win_text(win):find("alpha", 1, true) ~= nil)
  expect_truthy(has_group(tab_hl_groups(win), "JoveSidebarTabActive"))

  sidebar.switch(buf, "kernel")
  MiniTest.expect.equality(sidebar.current_tab(buf), "kernel")
  local kernel_text = win_text(win)
  expect_truthy(kernel_text:find("Session", 1, true) ~= nil)
  expect_truthy(kernel_text:find("python3", 1, true) ~= nil)

  sidebar.switch(buf, "toc")
  MiniTest.expect.equality(sidebar.current_tab(buf), "toc")
  expect_truthy(win_text(win):find("Title A", 1, true) ~= nil)
  sidebar.close(buf)
end

T["tabs"]["toggle on the same tab closes, on another tab switches"] = function()
  local buf = make_buffer({ "# %%", "x = 1" })
  local win = sidebar.open(buf, "vars")
  sidebar.toggle(buf, "kernel")
  expect_truthy(sidebar.is_open(buf))
  MiniTest.expect.equality(sidebar.current_tab(buf), "kernel")
  MiniTest.expect.equality(vim.api.nvim_win_is_valid(win), true)
  sidebar.toggle(buf, "kernel")
  expect_truthy(not sidebar.is_open(buf))
end

T["tabs"]["reopening while open keeps one window"] = function()
  local buf = make_buffer({ "# %%", "x = 1" })
  local win = sidebar.open(buf, "vars")
  local again = sidebar.open(buf, "toc")
  MiniTest.expect.equality(again, win)
  MiniTest.expect.equality(sidebar.current_tab(buf), "toc")
  sidebar.close(buf)
end

T["size"] = MiniTest.new_set()

T["size"]["clamps an oversized configured share"] = function()
  require("jove").config.variables = { size = 0.95, auto_refresh = false }
  local buf = make_buffer({ "# %%", "x = 1" })
  local win = sidebar.open(buf, "vars")
  expect_truthy(win ~= nil)
  local width = vim.api.nvim_win_get_width(win)
  expect_truthy(width <= math.floor(vim.o.columns * 0.9))
  expect_truthy(width >= 20)
  sidebar.close(buf)
end

T["size"]["accepts a fraction of the screen columns"] = function()
  require("jove").config.variables = { size = 0.5, auto_refresh = false }
  local buf = make_buffer({ "# %%", "x = 1" })
  local win = sidebar.open(buf, "vars")
  expect_truthy(win ~= nil)
  local width = vim.api.nvim_win_get_width(win)
  MiniTest.expect.equality(width, math.floor(vim.o.columns * 0.5))
  sidebar.close(buf)
end

T["size"]["sets the pane height in hsplit mode"] = function()
  local jove = require("jove")
  jove.config.variables = { size = 0.5, auto_refresh = false }
  local saved_mode = jove.config.ui.window_mode
  jove.config.ui.window_mode = "hsplit"
  local buf = make_buffer({ "# %%", "x = 1" })
  local win = sidebar.open(buf, "vars")
  expect_truthy(win ~= nil)
  MiniTest.expect.equality(vim.api.nvim_win_get_height(win), math.floor(vim.o.lines * 0.5))
  sidebar.close(buf)
  jove.config.ui.window_mode = saved_mode
end

T["actions"] = MiniTest.new_set()

T["actions"]["<CR> on the TOC tab jumps to the heading in the notebook window"] = function()
  local buf = make_buffer({
    "# %% [markdown]",
    "# # Title A",
    "# %% code",
    "x = 1",
    "# %% [markdown]",
    "# ## Sub B",
  })
  vim.api.nvim_set_current_buf(buf)
  local win = sidebar.open(buf, "toc")
  vim.api.nvim_win_set_cursor(win, { 4, 0 })
  sidebar.activate(buf)
  MiniTest.expect.equality(vim.api.nvim_get_current_buf(), buf)
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 5)
  sidebar.close(buf)
end

T["actions"]["<CR> on the variables tab inspects the variable"] = function()
  local buf = make_buffer({ "# %%", "x = 1" })
  local inspected
  local real_inspect = vars.inspect_var
  vars.inspect_var = function(_, name)
    inspected = name
  end
  local win = sidebar.open(buf, "vars")
  vim.api.nvim_win_set_cursor(win, { 4, 0 })
  sidebar.activate(buf)
  vars.inspect_var = real_inspect
  MiniTest.expect.equality(inspected, "alpha")
  sidebar.close(buf)
end

T["chrome"] = MiniTest.new_set()

T["chrome"]["sidebar buffer is a non-modifiable nofile buffer without line numbers"] = function()
  local buf = make_buffer({ "# %%", "x = 1" })
  local win = sidebar.open(buf, "vars")
  local fbuf = vim.api.nvim_win_get_buf(win)
  MiniTest.expect.equality(vim.bo[fbuf].buftype, "nofile")
  MiniTest.expect.equality(vim.bo[fbuf].modifiable, false)
  MiniTest.expect.equality(vim.wo[win].number, false)
  MiniTest.expect.equality(vim.wo[win].relativenumber, false)
  MiniTest.expect.equality(vim.wo[win].signcolumn, "no")
  MiniTest.expect.equality(vim.wo[win].statuscolumn, "")
  sidebar.close(buf)
end

return T

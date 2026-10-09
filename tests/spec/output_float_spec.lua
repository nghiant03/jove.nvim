---@diagnostic disable: missing-fields, need-check-nil
local MiniTest = require("mini.test")
local state = require("jove.state")
local cell = require("jove.cell")
local output = require("jove.output")
local jove = require("jove")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      jove.config.output.max_lines = 50
      jove.config.output.images = true
      jove.config.output.image_max_width = 80
      jove.config.output.image_max_height = 40
      jove.config.output.header = true
      jove.config.output.guide = "▎ "
      jove.config.output.inside_border = false
      jove.config.output.hl = nil
    end,
    post_case = function()
      package.loaded["snacks.image"] = nil
    end,
  },
})

---@param cond any
local function expect_truthy(cond)
  MiniTest.expect.equality(cond == true, true)
end

---@param lines string[]
---@return integer buf
local function make_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  state.get(buf).path = "fake.ipynb"
  return buf
end

---@param buf integer
local function release_buffer(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end

---@param buf integer
---@param idx integer?
---@return string
local function cell_hash(buf, idx)
  return cell.all(buf)[idx or 1].hash
end

---@param s string
---@param prefix string
---@return boolean
local function starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

T["open_float"] = MiniTest.new_set()

T["open_float"]["shows untruncated output and closes on demand"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)
  local orig = jove.config.output.max_lines
  jove.config.output.max_lines = 2
  local lines = {}
  for i = 1, 8 do
    lines[#lines + 1] = ("l%d"):format(i)
  end
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = table.concat(lines, "\n") } })

  local before = vim.api.nvim_get_current_win()
  local win = output.open_float(buf, 1)
  expect_truthy(win ~= nil)
  expect_truthy(vim.api.nvim_win_is_valid(win))
  local fbuf = vim.api.nvim_win_get_buf(win)
  MiniTest.expect.equality(vim.api.nvim_buf_line_count(fbuf), 8)
  local float_lines = vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)
  MiniTest.expect.equality(float_lines[1], "l1")
  for _, l in ipairs(float_lines) do
    MiniTest.expect.equality(l:find("└─", 1, true), nil)
    expect_truthy(not starts_with(l, "▎ "))
  end

  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys("q", "mx", false)
  expect_truthy(not vim.api.nvim_win_is_valid(win))
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), before)

  jove.config.output.max_lines = orig
  release_buffer(buf)
end

T["open_float"]["returns nil when there is nothing to show"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  MiniTest.expect.equality(output.open_float(buf, 1), nil)
  output.push(buf, cell_hash(buf), { kind = "stream", mime = { ["text/plain"] = "x" } })
  expect_truthy(output.open_float(buf, 1) ~= nil)
  vim.cmd("silent! close")
  release_buffer(buf)
end

T["open_float"]["renders the float with treesitter highlighting best-effort"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  vim.bo[buf].filetype = "python"
  local hash = cell_hash(buf)
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "x = 1" } })
  local win = output.open_float(buf, 1)
  expect_truthy(win ~= nil)
  MiniTest.expect.equality(vim.bo[vim.api.nvim_win_get_buf(win)].filetype, "python")
  vim.api.nvim_win_close(win, true)
  release_buffer(buf)
end

T["open_float"]["opens a vertical split by default"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  output.push(buf, cell_hash(buf), { kind = "stream", mime = { ["text/plain"] = "x" } })
  local win = output.open_float(buf, 1)
  expect_truthy(win ~= nil)
  MiniTest.expect.equality(vim.api.nvim_win_get_config(win).relative, "")
  expect_truthy(vim.api.nvim_win_get_width(win) < vim.o.columns)
  vim.api.nvim_win_close(win, true)
  release_buffer(buf)
end

T["open_float"]["honors ui.window_mode is float"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  output.push(buf, cell_hash(buf), { kind = "stream", mime = { ["text/plain"] = "x" } })
  local saved = jove.config.ui.window_mode
  jove.config.ui.window_mode = "float"
  local win = output.open_float(buf, 1)
  jove.config.ui.window_mode = saved
  expect_truthy(win ~= nil)
  MiniTest.expect.equality(vim.api.nvim_win_get_config(win).relative, "editor")
  vim.api.nvim_win_close(win, true)
  release_buffer(buf)
end

T["open_float"]["honors ui.window_mode is hsplit"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  output.push(buf, cell_hash(buf), { kind = "stream", mime = { ["text/plain"] = "x" } })
  local saved = jove.config.ui.window_mode
  jove.config.ui.window_mode = "hsplit"
  local win = output.open_float(buf, 1)
  jove.config.ui.window_mode = saved
  expect_truthy(win ~= nil)
  MiniTest.expect.equality(vim.api.nvim_win_get_config(win).relative, "")
  expect_truthy(vim.api.nvim_win_get_height(win) < vim.o.lines)
  vim.api.nvim_win_close(win, true)
  release_buffer(buf)
end

return T

local MiniTest = require("mini.test")
local state = require("jove.state")

local T = MiniTest.new_set()

---@param cond any
local function expect_truthy(cond)
  MiniTest.expect.equality(cond == true, true)
end

T["get"] = MiniTest.new_set()

T["get"]["creates state on demand"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  local entry = state.get(buf)
  MiniTest.expect.equality(type(entry), "table")
  MiniTest.expect.equality(entry.path, nil)
  MiniTest.expect.equality(entry.json, nil)
  MiniTest.expect.equality(entry.last_write, nil)
  state.clear(buf)
end

T["get"]["returns a stable per-buffer table"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  local first = state.get(buf)
  local second = state.get(buf)
  expect_truthy(first == second)
  first.path = "/tmp/smoke.ipynb"
  MiniTest.expect.equality(state.get(buf).path, "/tmp/smoke.ipynb")
  state.clear(buf)
end

T["get"]["resolves bufnr 0 to the current buffer"] = function()
  local buf = vim.api.nvim_get_current_buf()
  expect_truthy(state.get(0) == state.get(buf))
  state.clear(buf)
end

T["get"]["keeps state per buffer"] = function()
  local buf_a = vim.api.nvim_create_buf(false, true)
  local buf_b = vim.api.nvim_create_buf(false, true)
  state.get(buf_a).path = "/tmp/a.ipynb"
  state.get(buf_b).path = "/tmp/b.ipynb"
  MiniTest.expect.equality(state.get(buf_a).path, "/tmp/a.ipynb")
  MiniTest.expect.equality(state.get(buf_b).path, "/tmp/b.ipynb")
  state.clear(buf_a)
  state.clear(buf_b)
end

T["peek"] = MiniTest.new_set()

T["peek"]["returns nil without creating an entry"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  expect_truthy(state.peek(buf) == nil)
  expect_truthy(state.peek(buf) == nil)
  state.clear(buf)
end

T["clear"] = MiniTest.new_set()

T["clear"]["removes the entry"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  state.get(buf).path = "/tmp/smoke.ipynb"
  state.clear(buf)
  expect_truthy(state.peek(buf) == nil)
  local fresh = state.get(buf)
  expect_truthy(type(fresh) == "table")
  MiniTest.expect.equality(fresh.path, nil)
  state.clear(buf)
end

T["cleanup"] = MiniTest.new_set()

T["cleanup"]["clears state on BufWipeout"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  state.get(buf).path = "/tmp/smoke.ipynb"
  vim.api.nvim_buf_delete(buf, { force = true })
  expect_truthy(state.peek(buf) == nil)
end

return T

-- Keymap actions; kernel bridge faked like in execute_spec.
local MiniTest = require("mini.test")
local state = require("jove.state")
local execute = require("jove.execute")
local keymaps = require("jove.keymaps")

local T = MiniTest.new_set()

local LINES = { "# %% a", "x = 1", "# %% b", "y = 2", "# %% c", "z = 3" }

---@return table
local function fake_bridge()
  local br = { requests = {}, handlers = {}, alive = true }
  function br:request(method, params, cb, opts)
    table.insert(self.requests, { method = method, params = params, cb = cb, opts = opts })
  end
  function br:on(event, fn)
    self.handlers[event] = self.handlers[event] or {}
    table.insert(self.handlers[event], fn)
    return function() end
  end
  function br:is_alive()
    return br.alive
  end
  function br:stop() end
  function br:reply(result, err)
    local req = table.remove(self.requests, 1)
    req.cb(result, err)
  end
  return br
end

local created, real_notify, real_output, notes

local function make_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  state.get(buf).path = "fake.ipynb"
  created[#created + 1] = buf
  return buf
end

T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      created, notes = {}, {}
      real_notify, real_output = vim.notify, execute._output
      vim.notify = function(msg, level)
        table.insert(notes, { msg = msg, level = level })
      end
      execute._output = function()
        return nil
      end
    end,
    post_case = function()
      execute._output = real_output
      vim.notify = real_notify
      for _, buf in ipairs(created) do
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end,
  },
})

T["goto_running_cell"] = MiniTest.new_set()

T["goto_running_cell"]["jumps to the running cell's header"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  state.get(buf).kernel = { bridge = br, name = "python3", status = "idle" }
  vim.api.nvim_set_current_buf(buf)

  execute.run_cell(buf, 3) -- cell b, header at line 3
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  keymaps.goto_running_cell()
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 3)

  br:reply({ status = "ok" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  keymaps.goto_running_cell()
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 1) -- idle: no jump
  MiniTest.expect.equality(#notes, 1)
end

T["goto_running_cell"]["tracks the cell after buffer edits shift its lines"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  state.get(buf).kernel = { bridge = br, name = "python3", status = "idle" }
  vim.api.nvim_set_current_buf(buf)

  execute.run_cell(buf, 3) -- cell b
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "", "" }) -- push everything down 2
  keymaps.goto_running_cell()
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 5)
end

T["toggle_follow_running"] = MiniTest.new_set()

T["toggle_follow_running"]["cursor follows each cell as it starts running"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  state.get(buf).kernel = { bridge = br, name = "python3", status = "idle" }
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  MiniTest.expect.equality(keymaps.is_following(buf), false)
  keymaps.toggle_follow_running()
  MiniTest.expect.equality(keymaps.is_following(buf), true)

  execute.run_all(buf)
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 1)

  br:reply({ status = "ok" }) -- cell a done, cell b starts
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 3)

  keymaps.toggle_follow_running()
  MiniTest.expect.equality(keymaps.is_following(buf), false)
  br:reply({ status = "ok" }) -- cell c starts; no more following
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 3)
end

T["toggle_follow_running"]["jumps immediately when a cell is already running"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  state.get(buf).kernel = { bridge = br, name = "python3", status = "idle" }
  vim.api.nvim_set_current_buf(buf)

  execute.run_cell(buf, 5) -- cell c
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  keymaps.toggle_follow_running()
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 5)
end

return T

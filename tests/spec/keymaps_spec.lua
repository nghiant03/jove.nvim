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

  execute.run_cell(buf, 3)
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  keymaps.goto_running_cell()
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 3)

  br:reply({ status = "ok" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  keymaps.goto_running_cell()
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 1)
  MiniTest.expect.equality(#notes, 1)
end

T["goto_running_cell"]["tracks the cell after buffer edits shift its lines"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  state.get(buf).kernel = { bridge = br, name = "python3", status = "idle" }
  vim.api.nvim_set_current_buf(buf)

  execute.run_cell(buf, 3)
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "", "" })
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

  br:reply({ status = "ok" })
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 3)

  keymaps.toggle_follow_running()
  MiniTest.expect.equality(keymaps.is_following(buf), false)
  br:reply({ status = "ok" })
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 3)
end

T["toggle_follow_running"]["jumps immediately when a cell is already running"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  state.get(buf).kernel = { bridge = br, name = "python3", status = "idle" }
  vim.api.nvim_set_current_buf(buf)

  execute.run_cell(buf, 5)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  keymaps.toggle_follow_running()
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 5)
end

T["plug_mappings"] = MiniTest.new_set()

local function attach_notebook_buffer(lines)
  local buf = make_buffer(lines)
  keymaps.apply()
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "python"
  return buf
end

local function buf_lhs(buf, mode, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if m.lhs == lhs then
      return m
    end
  end
  return nil
end

T["plug_mappings"]["defines buffer-local <Plug> mappings and default motions"] = function()
  require("jove").config.cell_motions = true
  local buf = attach_notebook_buffer(LINES)

  MiniTest.expect.equality(buf_lhs(buf, "n", "<Plug>(JoveRunCell)") ~= nil, true)
  MiniTest.expect.equality(buf_lhs(buf, "n", "<Plug>(JoveNextCell)") ~= nil, true)
  MiniTest.expect.equality(buf_lhs(buf, "n", "<Plug>(JoveGotoRunningCell)") ~= nil, true)
  MiniTest.expect.equality(buf_lhs(buf, "x", "<Plug>(JoveRunSelection)") ~= nil, true)
  MiniTest.expect.equality(buf_lhs(buf, "n", "]c") ~= nil, true)
  MiniTest.expect.equality(buf_lhs(buf, "n", "[c") ~= nil, true)
end

T["plug_mappings"]["<Plug> mappings stay off non-notebook buffers"] = function()
  keymaps.apply()
  local buf = vim.api.nvim_create_buf(false, true)
  created[#created + 1] = buf
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "python"

  MiniTest.expect.equality(buf_lhs(buf, "n", "<Plug>(JoveRunCell)"), nil)
end

T["plug_mappings"]["does not clobber an existing ]c mapping"] = function()
  require("jove").config.cell_motions = true
  local buf = make_buffer(LINES)
  vim.keymap.set("n", "]c", "<cmd>echo 'user'<cr>", { buffer = buf })
  keymaps.apply()
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "python"

  MiniTest.expect.equality(vim.fn.maparg("]c", "n"):match("user") ~= nil, true)
  MiniTest.expect.equality(buf_lhs(buf, "n", "<Plug>(JoveNextCell)") ~= nil, true)
end

T["plug_mappings"]["skips motion defaults when the user bound the <Plug> mapping"] = function()
  require("jove").config.cell_motions = true
  vim.keymap.set("n", "<leader>jn", "<Plug>(JoveNextCell)")
  local buf = attach_notebook_buffer(LINES)
  vim.keymap.del("n", "<leader>jn")

  MiniTest.expect.equality(buf_lhs(buf, "n", "]c"), nil)
  MiniTest.expect.equality(buf_lhs(buf, "n", "[c") ~= nil, true)
end

T["plug_mappings"]["cell_motions = false disables the default motions"] = function()
  require("jove").config.cell_motions = false
  local buf = attach_notebook_buffer(LINES)
  require("jove").config.cell_motions = true

  MiniTest.expect.equality(buf_lhs(buf, "n", "]c"), nil)
  MiniTest.expect.equality(buf_lhs(buf, "n", "<Plug>(JoveNextCell)") ~= nil, true)
end

return T

local MiniTest = require("mini.test")
local bridge_mod = require("jove.bridge")
local state = require("jove.state")
local panel = require("jove.ui.panel")

local fixture = require("tests.helpers.bridge")
local job

local created

---@param name string
---@param lines string[]?
---@return integer
local function make_buffer(name, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
  created[#created + 1] = buf
  return buf
end

---@param name string
---@param status string
---@param alive boolean?
---@return table
local function stub_kernel(name, status, alive)
  return {
    name = name,
    status = status,
    bridge = {
      is_alive = function()
        return alive ~= false
      end,
    },
  }
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      created = {}
      job = fixture.new()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        state.clear(buf)
      end
    end,
    post_case = function()
      local ok, err = pcall(job.restore)
      for _, buf in ipairs(created) do
        state.clear(buf)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
      if not ok then
        error(err, 0)
      end
    end,
  },
})

T["running_kernels"] = MiniTest.new_set()

T["running_kernels"]["collects kernel buffers sorted by path"] = function()
  local buf_b = make_buffer("/tmp/jove_b.ipynb")
  local buf_a = make_buffer("/tmp/jove_a.ipynb")
  make_buffer("/tmp/jove_plain.ipynb")
  state.get(buf_b).kernel = stub_kernel("py", "idle")
  state.get(buf_a).kernel = stub_kernel("julia", "busy")

  local running = panel.running_kernels()
  MiniTest.expect.equality(#running, 2)
  MiniTest.expect.equality(running[1].buf, buf_a)
  MiniTest.expect.equality(running[1].path, vim.api.nvim_buf_get_name(buf_a))
  MiniTest.expect.equality(running[1].kernel, "julia")
  MiniTest.expect.equality(running[1].status, "busy")
  MiniTest.expect.equality(running[1].alive, true)
  MiniTest.expect.equality(running[2].buf, buf_b)
  MiniTest.expect.equality(running[2].kernel, "py")
end

T["info"] = MiniTest.new_set()

T["info"]["reports kernel, status, and queue length"] = function()
  local buf = make_buffer("/tmp/jove_info.ipynb")
  state.get(buf).kernel = stub_kernel("py", "busy")
  local info = panel.info(buf)
  MiniTest.expect.equality(info.kernel, "py")
  MiniTest.expect.equality(info.status, "busy")
  MiniTest.expect.equality(info.queue_len, 0)
end

T["status"] = MiniTest.new_set()

T["status"]["keeps the statusline contract"] = function()
  local buf = make_buffer("/tmp/jove_status.ipynb")
  state.get(buf).kernel = stub_kernel("py", "busy")
  MiniTest.expect.equality(panel.status(buf), "⚡ py · busy")
  state.get(buf).kernel.status = "idle"
  MiniTest.expect.equality(panel.status(buf), "⚡ py · idle")
end

T["installed_kernelspecs"] = MiniTest.new_set()

T["installed_kernelspecs"]["reuses a live bridge and sorts specs by name"] = function()
  local bridge = bridge_mod.new()
  bridge:start()
  job.stdout('{"event":"ready","params":{"protocol":1}}\n')

  local buf = make_buffer("/tmp/jove_reuse.ipynb")
  state.get(buf).kernel = { name = "py", status = "idle", bridge = bridge }
  vim.api.nvim_set_current_buf(buf)

  local got = {}
  panel.installed_kernelspecs(function(specs, err)
    got.specs = specs
    got.err = err
    got.called = true
  end)
  job.stdout(
    '{"id":1,"result":{"kernelspecs":{"julia":{"display_name":"Julia","language":"julia"},"python3":{"display_name":"Python 3","language":"python"}}}}\n'
  )
  vim.wait(200, function()
    return got.called
  end)

  MiniTest.expect.equality(got.called, true)
  MiniTest.expect.equality(got.err == nil, true)
  MiniTest.expect.equality(#got.specs, 2)
  MiniTest.expect.equality(got.specs[1].name, "julia")
  MiniTest.expect.equality(got.specs[1].display_name, "Julia")
  MiniTest.expect.equality(got.specs[2].name, "python3")
  MiniTest.expect.equality(got.specs[2].language, "python")
  MiniTest.expect.equality(job.stopped, false)
end

T["installed_kernelspecs"]["starts a temporary bridge and stops it"] = function()
  make_buffer("/tmp/jove_temp.ipynb")

  local got = {}
  panel.installed_kernelspecs(function(specs, err)
    got.specs = specs
    got.err = err
    got.called = true
  end)
  job.stdout('{"event":"ready","params":{"protocol":1}}\n')
  job.stdout(
    '{"id":1,"result":{"kernelspecs":{"python3":{"display_name":"Python 3","language":"python"}}}}\n'
  )
  vim.wait(200, function()
    return got.called
  end)

  MiniTest.expect.equality(got.called, true)
  MiniTest.expect.equality(got.specs[1].name, "python3")
  MiniTest.expect.equality(
    vim.wait(2000, function()
      return job.stopped
    end),
    true
  )
end

T["installed_kernelspecs"]["reports a spawn failure when the bridge cannot start"] = function()
  job.fail_spawn = true
  make_buffer("/tmp/jove_spawn_fail.ipynb")

  local got = {}
  panel.installed_kernelspecs(function(specs, err)
    got.specs = specs
    got.err = err
    got.called = true
  end)
  MiniTest.expect.equality(
    vim.wait(200, function()
      return got.called
    end),
    true
  )
  MiniTest.expect.equality(got.specs, nil)
  MiniTest.expect.equality(type(got.err), "string")
  MiniTest.expect.no_equality(got.err, "")
end

T["installed_kernelspecs"]["reports an error and still stops the temporary bridge"] = function()
  make_buffer("/tmp/jove_temperr.ipynb")

  local got = {}
  panel.installed_kernelspecs(function(specs, err)
    got.specs = specs
    got.err = err
    got.called = true
  end)
  job.stdout('{"event":"ready","params":{"protocol":1}}\n')
  job.stdout('{"id":1,"error":{"ename":"x","message":"y"}}\n')
  vim.wait(200, function()
    return got.called
  end)

  MiniTest.expect.equality(got.called, true)
  MiniTest.expect.equality(got.specs == nil, true)
  MiniTest.expect.equality(got.err ~= nil, true)
  MiniTest.expect.equality(
    vim.wait(2000, function()
      return job.stopped
    end),
    true
  )
end

return T

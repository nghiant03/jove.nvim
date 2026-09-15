-- Kernel panel: running-kernel enumeration and the three-section info float.
local MiniTest = require("mini.test")
local bridge_mod = require("jove.bridge")
local state = require("jove.state")
local panel = require("jove.ui.panel")

local T = MiniTest.new_set()

-- Inject job callbacks so tests can control stdout delivery and process exits.

---@return table
local function fake_job()
  local job = { id = 7, sent = {}, spawn_count = 0, stopped = false }
  local real = {
    jobstart = bridge_mod._impl.jobstart,
    jobsend = bridge_mod._impl.jobsend,
    jobstop = bridge_mod._impl.jobstop,
  }

  function job.install()
    bridge_mod._impl.jobstart = function(_, opts)
      job.spawn_count = job.spawn_count + 1
      job.opts = opts
      return job.id
    end
    bridge_mod._impl.jobsend = function(_, data)
      table.insert(job.sent, data)
      return true
    end
    bridge_mod._impl.jobstop = function(_)
      job.stopped = true
      return 1
    end
  end

  function job.restore()
    bridge_mod._impl.jobstart = real.jobstart
    bridge_mod._impl.jobsend = real.jobsend
    bridge_mod._impl.jobstop = real.jobstop
  end

  function job.stdout(chunk)
    job.opts.on_stdout(job.id, vim.split(chunk, "\n", { plain = true }))
  end

  function job.stderr(chunk)
    job.opts.on_stderr(job.id, vim.split(chunk, "\n", { plain = true }))
  end

  function job.exit(code)
    job.opts.on_exit(job.id, code or 0)
  end

  return job
end

-- Buffers created by a case, wiped in post_case.
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

---@param fbuf integer
---@return string[]
local function buf_lines(fbuf)
  return vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)
end

---@param lines string[]
---@param needle string
---@return boolean
local function has_line(lines, needle)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return true
    end
  end
  return false
end

T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      created = {}
      bridge_mod._impl.jobstart = vim.fn.jobstart
      bridge_mod._impl.jobsend = vim.fn.jobsend
      bridge_mod._impl.jobstop = vim.fn.jobstop
      bridge_mod.respawn_backoff_ms = { 1000, 2000, 4000 }
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        state.clear(buf)
      end
    end,
    post_case = function()
      for _, buf in ipairs(created) do
        state.clear(buf)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
      bridge_mod._impl.jobstart = vim.fn.jobstart
      bridge_mod._impl.jobsend = vim.fn.jobsend
      bridge_mod._impl.jobstop = vim.fn.jobstop
      bridge_mod.respawn_backoff_ms = { 1000, 2000, 4000 }
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
  MiniTest.expect.equality(running[1].path, "/tmp/jove_a.ipynb")
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
  local job = fake_job()
  job.install()
  local bridge = bridge_mod.new()
  bridge:start()
  job.stdout('{"event":"ready","params":{"protocol":1,"version":"0.1"}}\n')

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
  job.restore()
end

T["installed_kernelspecs"]["starts a temporary bridge and stops it"] = function()
  local job = fake_job()
  job.install()
  make_buffer("/tmp/jove_temp.ipynb")

  local got = {}
  panel.installed_kernelspecs(function(specs, err)
    got.specs = specs
    got.err = err
    got.called = true
  end)
  job.stdout('{"event":"ready","params":{"protocol":1,"version":"0.1"}}\n')
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
  job.restore()
end

T["installed_kernelspecs"]["reports an error and still stops the temporary bridge"] = function()
  local job = fake_job()
  job.install()
  make_buffer("/tmp/jove_temperr.ipynb")

  local got = {}
  panel.installed_kernelspecs(function(specs, err)
    got.specs = specs
    got.err = err
    got.called = true
  end)
  job.stdout('{"event":"ready","params":{"protocol":1,"version":"0.1"}}\n')
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
  job.restore()
end

T["info_float"] = MiniTest.new_set()

T["info_float"]["renders three sections and fills specs asynchronously"] = function()
  local job = fake_job()
  job.install()
  local buf = make_buffer("/tmp/jove_float.ipynb")
  state.get(buf).kernel = stub_kernel("py", "idle", false)

  local float = panel.info_float(buf)
  created[#created + 1] = float.buf
  local fbuf = float.buf
  MiniTest.expect.equality(vim.bo[fbuf].buflisted, false)
  MiniTest.expect.equality(vim.bo[fbuf].bufhidden, "wipe")
  MiniTest.expect.equality(float.opts.relative, "editor")
  MiniTest.expect.equality(float.opts.border, "rounded")
  MiniTest.expect.equality(has_line(float.lines, "session"), true)
  MiniTest.expect.equality(has_line(float.lines, "running kernels"), true)
  MiniTest.expect.equality(has_line(float.lines, "installed kernelspecs"), true)
  MiniTest.expect.equality(has_line(float.lines, "(loading…)"), true)

  job.stdout('{"event":"ready","params":{"protocol":1,"version":"0.1"}}\n')
  job.stdout(
    '{"id":1,"result":{"kernelspecs":{"python3":{"display_name":"Python 3","language":"python"}}}}\n'
  )
  vim.wait(200, function()
    return has_line(buf_lines(fbuf), "python3")
  end)

  local lines = buf_lines(fbuf)
  MiniTest.expect.equality(has_line(lines, "python3  Python 3"), true)
  MiniTest.expect.equality(has_line(lines, "(loading…)"), false)
  job.restore()
end

T["info_float"]["ignores the async reply after the float buffer is wiped"] = function()
  local job = fake_job()
  job.install()
  local buf = make_buffer("/tmp/jove_wipe.ipynb")
  state.get(buf).kernel = stub_kernel("py", "idle", false)

  local float = panel.info_float(buf)
  vim.api.nvim_buf_delete(float.buf, { force = true })
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(float.buf), false)

  job.stdout('{"event":"ready","params":{"protocol":1,"version":"0.1"}}\n')
  job.stdout(
    '{"id":1,"result":{"kernelspecs":{"python3":{"display_name":"Python 3","language":"python"}}}}\n'
  )
  local ok = pcall(vim.wait, 200, function()
    return false
  end)
  MiniTest.expect.equality(ok, true)
  job.restore()
end

T["info_float"]["resizes the open window when specs arrive"] = function()
  local job = fake_job()
  job.install()
  local buf = make_buffer("/tmp/jove_resize.ipynb")
  state.get(buf).kernel = stub_kernel("py", "idle", false)

  local float = panel.info_float(buf)
  created[#created + 1] = float.buf
  local win = vim.api.nvim_open_win(float.buf, true, float.opts)

  job.stdout('{"event":"ready","params":{"protocol":1,"version":"0.1"}}\n')
  job.stdout(
    '{"id":1,"result":{"kernelspecs":{"julia":{"display_name":"Julia","language":"julia"},"python3":{"display_name":"Python 3","language":"python"}}}}\n'
  )
  vim.wait(200, function()
    return #buf_lines(float.buf) > #float.lines
  end)
  local expected = #buf_lines(float.buf)
  MiniTest.expect.equality(vim.api.nvim_win_get_height(win), expected)
  vim.api.nvim_win_close(win, true)
  job.restore()
end

return T

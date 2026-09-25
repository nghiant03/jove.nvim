local MiniTest = require("mini.test")
local bridge_mod = require("jove.bridge")

local T = MiniTest.new_set()

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

T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      bridge_mod._impl.jobstart = vim.fn.jobstart
      bridge_mod._impl.jobsend = vim.fn.jobsend
      bridge_mod._impl.jobstop = vim.fn.jobstop
      bridge_mod.respawn_backoff_ms = { 1000, 2000, 4000 }
    end,
  },
})

T["line buffering"] = MiniTest.new_set()

T["line buffering"]["assembles JSON split across chunks"] = function()
  local job = fake_job()
  job.install()
  local b = bridge_mod.new()
  b:start()

  local events = {}
  b:on("kernel_status", function(params)
    table.insert(events, params)
  end)

  job.stdout('{"event":"ready","params":{"protocol":1}}\n{"event":"kernel_status"')
  job.stdout(',"params":{"status":"busy"}}\n')
  vim.wait(200, function()
    return #events > 0
  end)

  MiniTest.expect.equality(#events, 1)
  MiniTest.expect.equality(events[1].status, "busy")
  MiniTest.expect.equality(b:is_ready(), true)
  job.restore()
end

T["line buffering"]["ignores trailing partial data until a newline arrives"] = function()
  local job = fake_job()
  job.install()
  local b = bridge_mod.new()
  b:start()

  local events = {}
  b:on("kernel_status", function(params)
    table.insert(events, params)
  end)

  job.stdout('{"event":"kernel_status","params":{"status":"idle"}')
  vim.wait(50, function()
    return false
  end)
  MiniTest.expect.equality(#events, 0)
  job.stdout("}\n")
  vim.wait(200, function()
    return #events > 0
  end)
  MiniTest.expect.equality(events[1].status, "idle")
  job.restore()
end

T["requests"] = MiniTest.new_set()

T["requests"]["queue before ready, flush in order, route by id"] = function()
  local job = fake_job()
  job.install()
  local b = bridge_mod.new()
  local got = {}

  b:request("list_kernelspecs", {}, function(result)
    got.ks = result
  end)
  b:request("execute", { code = "1", cell = "h1" }, function(result)
    got.exec = result
  end)
  MiniTest.expect.equality(#job.sent, 0)

  b:start()
  job.stdout('{"event":"ready","params":{"protocol":1}}\n')

  MiniTest.expect.equality(#job.sent, 2)
  local first = vim.json.decode(job.sent[1])
  local second = vim.json.decode(job.sent[2])
  MiniTest.expect.equality(first.id, 1)
  MiniTest.expect.equality(first.method, "list_kernelspecs")
  MiniTest.expect.equality(second.id, 2)
  MiniTest.expect.equality(second.method, "execute")
  MiniTest.expect.equality(second.params.cell, "h1")

  job.stdout('{"id":2,"result":{"status":"ok"}}\n')
  job.stdout('{"id":1,"result":{"kernelspecs":{"python3":{"display_name":"Python 3"}}}}\n')
  vim.wait(200, function()
    return got.ks ~= nil and got.exec ~= nil
  end)
  MiniTest.expect.equality(got.exec.status, "ok")
  MiniTest.expect.equality(got.ks.kernelspecs.python3.display_name, "Python 3")
  job.restore()
end

T["requests"]["deliver error responses as err"] = function()
  local job = fake_job()
  job.install()
  local b = bridge_mod.new()
  b:start()
  job.stdout('{"event":"ready","params":{"protocol":1}}\n')

  local called, result, err
  b:request("restart", {}, function(r, e)
    called, result, err = true, r, e
  end)
  job.stdout('{"id":1,"error":{"code":"kernel_not_running","message":"start a kernel first"}}\n')
  vim.wait(200, function()
    return called
  end)
  MiniTest.expect.equality(called, true)
  MiniTest.expect.equality(result == nil, true)
  MiniTest.expect.equality(err.code, "kernel_not_running")
  MiniTest.expect.equality(err.message, "start a kernel first")
  job.restore()
end

T["requests"]["time out when no response arrives"] = function()
  local job = fake_job()
  job.install()
  local b = bridge_mod.new()
  b:start()
  job.stdout('{"event":"ready","params":{"protocol":1}}\n')

  local called, result, err
  b:request("execute", { code = "1" }, function(r, e)
    called, result, err = true, r, e
  end, { timeout_ms = 10 })
  vim.wait(500, function()
    return called
  end)
  MiniTest.expect.equality(called, true)
  MiniTest.expect.equality(result == nil, true)
  MiniTest.expect.equality(type(err) == "string" and err:find("timeout", 1, true) ~= nil, true)
  job.restore()
end

T["requests"]["timeout_ms = false disables the timer"] = function()
  local job = fake_job()
  job.install()
  local b = bridge_mod.new()
  b:start()
  job.stdout('{"event":"ready","params":{"protocol":1}}\n')

  local called, result, err
  b:request("execute", { code = "1" }, function(r, e)
    called, result, err = true, r, e
  end, { timeout_ms = false })
  vim.wait(50, function()
    return false
  end)
  MiniTest.expect.equality(not called, true)
  MiniTest.expect.equality(result == nil and err == nil, true)
  job.restore()
end

T["lifecycle"] = MiniTest.new_set()

T["lifecycle"]["respawns on unexpected exit with backoff"] = function()
  bridge_mod.respawn_backoff_ms = { 10, 10, 10 }
  local job = fake_job()
  job.install()
  local b = bridge_mod.new()
  b:start()
  job.stdout('{"event":"ready","params":{"protocol":1}}\n')

  local called, result, err
  b:request("execute", { code = "1" }, function(r, e)
    called, result, err = true, r, e
  end, { timeout_ms = false })
  job.exit(1)
  vim.wait(200, function()
    return called and job.spawn_count == 2
  end)
  MiniTest.expect.equality(called, true)
  MiniTest.expect.equality(result == nil, true)
  MiniTest.expect.equality(type(err) == "string" and err:find("exited", 1, true) ~= nil, true)
  MiniTest.expect.equality(job.spawn_count, 2)
  MiniTest.expect.equality(b:is_ready(), false)
  job.restore()
end

T["lifecycle"]["does not respawn after user-initiated stop"] = function()
  bridge_mod.respawn_backoff_ms = { 10, 10, 10 }
  local job = fake_job()
  job.install()
  local b = bridge_mod.new()
  b:start()
  job.stdout('{"event":"ready","params":{"protocol":1}}\n')

  local stopped = false
  b:stop(function()
    stopped = true
  end)
  job.exit(0)
  vim.wait(200, function()
    return stopped
  end)
  MiniTest.expect.equality(job.spawn_count, 1)
  MiniTest.expect.equality(b:is_ready(), false)
  job.restore()
end

T["lifecycle"]["sends shutdown request before killing the job"] = function()
  local job = fake_job()
  job.install()
  local b = bridge_mod.new()
  b:start()
  job.stdout('{"event":"ready","params":{"protocol":1}}\n')

  b:stop()
  vim.wait(200, function()
    return #job.sent == 1
  end)
  local req = vim.json.decode(job.sent[1])
  MiniTest.expect.equality(req.method, "shutdown")
  MiniTest.expect.equality(not job.stopped, true)
  job.restore()
end

T["lifecycle"]["readiness timeout fails queued requests once"] = function()
  local job = fake_job()
  job.install()
  local timeout = bridge_mod.ready_timeout_ms
  bridge_mod.ready_timeout_ms = 10
  local b = bridge_mod.new({ respawn = false }):start()
  local replies = {}
  b:request("list_kernelspecs", {}, function(_, err)
    replies[#replies + 1] = err
  end)
  local expired = vim.wait(1000, function()
    return #replies > 0
  end)
  job.exit(1)
  vim.wait(30, function()
    return false
  end)
  bridge_mod.ready_timeout_ms = timeout
  job.restore()
  MiniTest.expect.equality(expired, true)
  MiniTest.expect.equality(job.stopped, true)
  MiniTest.expect.equality(replies, { "bridge readiness timeout" })
end

T["resolve_python"] = MiniTest.new_set()

local function with_clean_env(fn)
  local saved = {
    conda = vim.env.CONDA_PREFIX,
    venv = vim.env.VIRTUAL_ENV,
    host = vim.g.python3_host_prog,
  }
  vim.env.CONDA_PREFIX = nil
  vim.env.VIRTUAL_ENV = nil
  vim.g.python3_host_prog = nil
  local ok, err = pcall(fn)
  vim.env.CONDA_PREFIX = saved.conda
  vim.env.VIRTUAL_ENV = saved.venv
  vim.g.python3_host_prog = saved.host
  if not ok then
    error(err, 0)
  end
end

T["resolve_python"]["falls back to cfg value when no env or host prog"] = function()
  with_clean_env(function()
    MiniTest.expect.equality(bridge_mod.resolve_python("/cfg/python"), "/cfg/python")
    MiniTest.expect.equality(bridge_mod.resolve_python(nil), "python3")
  end)
end

T["resolve_python"]["prefers g:python3_host_prog over cfg fallback"] = function()
  with_clean_env(function()
    local host = vim.fn.tempname()
    vim.fn.writefile({}, host)
    vim.g.python3_host_prog = host
    MiniTest.expect.equality(bridge_mod.resolve_python("/cfg/python"), host)
    vim.fn.delete(host)
  end)
end

T["resolve_python"]["ignores g:python3_host_prog when the file does not exist"] = function()
  with_clean_env(function()
    vim.g.python3_host_prog = "/nonexistent/host/python"
    MiniTest.expect.equality(bridge_mod.resolve_python("/cfg/python"), "/cfg/python")
  end)
end

T["resolve_python"]["active virtualenv beats g:python3_host_prog"] = function()
  with_clean_env(function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/bin", "p")
    vim.fn.writefile({}, dir .. "/bin/python")
    vim.env.VIRTUAL_ENV = dir
    local host = vim.fn.tempname()
    vim.fn.writefile({}, host)
    vim.g.python3_host_prog = host
    MiniTest.expect.equality(bridge_mod.resolve_python("/cfg/python"), dir .. "/bin/python")
    vim.fn.delete(dir, "rf")
    vim.fn.delete(host)
  end)
end

return T

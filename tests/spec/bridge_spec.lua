-- bridge_spec.lua: bridge.lua line buffering, queue-before-ready, request
-- routing, and respawn behavior — against an injected fake jobstart.
local MiniTest = require("mini.test")
local bridge_mod = require("jove.bridge")

local T = MiniTest.new_set()

-- ---------------------------------------------------------------------------
-- Fake job plumbing: installs itself into the module's impl seam and lets
-- tests drive stdout/exit events by hand.
-- ---------------------------------------------------------------------------

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

  ---Feed one stdout chunk; the fake splits on "\n" exactly like real
  ---jobstart does (complete lines + partial remainder, trailing "" after a
  ---final newline), so bridge.lua sees the same shape as in production.
  function job.stdout(chunk)
    job.opts.on_stdout(job.id, vim.split(chunk, "\n", { plain = true }))
  end

  ---Feed one stderr chunk (same split shape).
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
      -- Defensive restore (a failed case may leave fakes installed).
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

  -- One ready line, then a kernel_status event split across two chunks.
  job.stdout('{"event":"ready","params":{"protocol":1,"version":"0.1"}}\n{"event":"kernel_status"')
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

  -- Partial event without a newline: must NOT be dispatched yet.
  job.stdout('{"event":"kernel_status","params":{"status":"idle"}')
  vim.wait(50, function()
    return false
  end) -- pump the loop; nothing should fire
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
  MiniTest.expect.equality(#job.sent, 0) -- nothing sent before ready

  b:start()
  job.stdout('{"event":"ready","params":{"protocol":1,"version":"0.1"}}\n')

  MiniTest.expect.equality(#job.sent, 2)
  local first = vim.json.decode(job.sent[1])
  local second = vim.json.decode(job.sent[2])
  MiniTest.expect.equality(first.id, 1)
  MiniTest.expect.equality(first.method, "list_kernelspecs")
  MiniTest.expect.equality(second.id, 2)
  MiniTest.expect.equality(second.method, "execute")
  MiniTest.expect.equality(second.params.cell, "h1")

  -- Responses arrive out of order; routing must still match by id.
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
  job.stdout('{"event":"ready","params":{"protocol":1,"version":"0.1"}}\n')

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
  job.stdout('{"event":"ready","params":{"protocol":1,"version":"0.1"}}\n')

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
  job.stdout('{"event":"ready","params":{"protocol":1,"version":"0.1"}}\n')

  local called, result, err
  b:request("execute", { code = "1" }, function(r, e)
    called, result, err = true, r, e
  end, { timeout_ms = false })
  vim.wait(50, function()
    return false
  end) -- longer than the default would allow if a timer existed
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
  job.stdout('{"event":"ready","params":{"protocol":1,"version":"0.1"}}\n')

  -- Pending request at death time must be failed, then the bridge respawns.
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
  job.stdout('{"event":"ready","params":{"protocol":1,"version":"0.1"}}\n')

  local stopped = false
  b:stop(function()
    stopped = true
  end)
  job.exit(0)
  vim.wait(200, function()
    return stopped
  end)
  MiniTest.expect.equality(job.spawn_count, 1) -- no respawn
  MiniTest.expect.equality(b:is_ready(), false)
  job.restore()
end

T["lifecycle"]["sends shutdown request before killing the job"] = function()
  local job = fake_job()
  job.install()
  local b = bridge_mod.new()
  b:start()
  job.stdout('{"event":"ready","params":{"protocol":1,"version":"0.1"}}\n')

  b:stop()
  vim.wait(200, function()
    return #job.sent == 1
  end)
  local req = vim.json.decode(job.sent[1])
  MiniTest.expect.equality(req.method, "shutdown")
  MiniTest.expect.equality(not job.stopped, true) -- killed only after the grace period
  job.restore()
end

return T

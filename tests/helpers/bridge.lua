local bridge_mod = require("jove.bridge")

local M = {}
local next_id = 10000

function M.new()
  local job =
    { sent = {}, spawn_count = 0, stopped = false, jobs = {}, handles = {}, auto_exit = true }
  local saved = {
    jobstart = bridge_mod._impl.jobstart,
    jobsend = bridge_mod._impl.jobsend,
    jobstop = bridge_mod._impl.jobstop,
    defer_fn = bridge_mod._impl.defer_fn,
    new = bridge_mod.new,
    backoff = bridge_mod.respawn_backoff_ms,
    ready_timeout = bridge_mod.ready_timeout_ms,
  }
  local restored = false
  local timers = {}

  local function drain()
    local done = false
    vim.schedule(function()
      vim.schedule(function()
        done = true
      end)
    end)
    assert(
      vim.wait(1000, function()
        return done
      end),
      "scheduled callbacks did not drain"
    )
  end

  rawset(bridge_mod._impl, "defer_fn", function(callback, timeout)
    local entry = { callback = callback }
    entry.timer = saved.defer_fn(function()
      entry.fired = true
      callback()
    end, timeout)
    table.insert(timers, entry)
    return entry.timer
  end)

  function job.flush_timers()
    for _, entry in ipairs(timers) do
      if not entry.fired and not entry.timer:is_closing() then
        entry.timer:stop()
        entry.timer:close()
        entry.fired = true
        entry.callback()
      end
    end
    drain()
  end

  function job.exit(code, id)
    id = id or job.id
    local process = assert(job.jobs[id], "unknown fake job")
    if process.exited then
      return
    end
    process.exited = true
    process.opts.on_exit(id, code or 0)
  end

  function job.stdout(chunk, id)
    id = id or job.id
    job.jobs[id].opts.on_stdout(id, vim.split(chunk, "\n", { plain = true }))
  end

  function job.stderr(chunk, id)
    id = id or job.id
    job.jobs[id].opts.on_stderr(id, vim.split(chunk, "\n", { plain = true }))
  end

  rawset(bridge_mod, "new", function(opts)
    local handle = saved.new(opts)
    table.insert(job.handles, handle)
    return handle
  end)
  bridge_mod._impl.jobstart = function(_, opts)
    job.spawn_count = job.spawn_count + 1
    if job.fail_spawn then
      return -1
    end
    next_id = next_id + 1
    job.id = next_id
    job.jobs[job.id] = { opts = opts, exited = false }
    return job.id
  end
  bridge_mod._impl.jobsend = function(id, data)
    assert(job.jobs[id] and not job.jobs[id].exited, "send to inactive fake job")
    table.insert(job.sent, data)
    return true
  end
  bridge_mod._impl.jobstop = function(id)
    local process = assert(job.jobs[id], "stop of unknown fake job")
    job.stopped = true
    process.stopped = true
    if job.auto_exit then
      job.exit(0, id)
    end
    return 1
  end

  function job.assert_quiescent()
    for _, entry in ipairs(timers) do
      assert(entry.fired or entry.timer:is_closing(), "bridge timer remains")
    end
    for _, handle in ipairs(job.handles) do
      assert(not handle:is_alive(), "bridge is still alive")
      assert(handle._ready_timer == nil, "bridge readiness timer remains")
      assert(handle._respawn_timer == nil, "bridge respawn timer remains")
      assert(next(handle._pending) == nil, "bridge requests remain")
      assert(#handle._queue == 0, "bridge queue remains")
      assert(handle._stop_cbs == nil, "bridge stop callbacks remain")
    end
    for _, process in pairs(job.jobs) do
      assert(process.exited, "fake job has not exited")
    end
  end

  function job.restore()
    if restored then
      return
    end
    local ok, err = pcall(function()
      for _, handle in ipairs(job.handles) do
        handle:stop()
      end
      for id, process in pairs(job.jobs) do
        if not process.exited then
          job.exit(0, id)
        end
      end
      drain()
      for _, handle in ipairs(job.handles) do
        handle:stop()
      end
      job.flush_timers()
      job.assert_quiescent()
    end)
    bridge_mod._impl.jobstart = saved.jobstart
    bridge_mod._impl.jobsend = saved.jobsend
    bridge_mod._impl.jobstop = saved.jobstop
    rawset(bridge_mod._impl, "defer_fn", saved.defer_fn)
    rawset(bridge_mod, "new", saved.new)
    bridge_mod.respawn_backoff_ms = saved.backoff
    bridge_mod.ready_timeout_ms = saved.ready_timeout
    restored = true
    if not ok then
      error(err, 0)
    end
  end

  return job
end

return M

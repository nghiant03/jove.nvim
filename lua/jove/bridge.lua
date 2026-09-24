-- JSON-lines client jove_bridge python package.

local M = {}

local impl = {
  jobstart = vim.fn.jobstart,
  jobsend = vim.fn.chansend,
  jobstop = vim.fn.jobstop,
}

M._impl = impl

M.trace = false

M.respawn_backoff_ms = { 1000, 2000, 4000 }

M.ready_timeout_ms = 20000

local DEFAULT_TIMEOUT_MS = 15000
local MAX_RESPAWNS = 3
local SHUTDOWN_GRACE_MS = 1000

local function cancel_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

---@return string
local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

---@param cfg_value string?
---@return string
function M.resolve_python(cfg_value)
  local candidates = {}
  if vim.env.CONDA_PREFIX and vim.env.CONDA_PREFIX ~= "" then
    table.insert(candidates, vim.fs.joinpath(vim.env.CONDA_PREFIX, "bin", "python"))
  end
  if vim.env.VIRTUAL_ENV and vim.env.VIRTUAL_ENV ~= "" then
    table.insert(candidates, vim.fs.joinpath(vim.env.VIRTUAL_ENV, "bin", "python"))
  end
  if vim.g.python3_host_prog and vim.g.python3_host_prog ~= "" then
    table.insert(candidates, vim.g.python3_host_prog)
  end
  for _, path in ipairs(candidates) do
    if vim.uv.fs_stat(path) then
      return path
    end
  end
  return cfg_value or "python3"
end

---@return string
local function path_sep()
  return vim.uv.os_uname().sysname:find("Windows", 1, true) and ";" or ":"
end

---@class jove.bridge.Opts
---@field bridge_python string?  Interpreter override (default: $CONDA_PREFIX/bin/python -> $VIRTUAL_ENV/bin/python -> g:python3_host_prog -> "python3").
---@field timeout_ms integer|boolean?  Default per-request timeout in ms; `false`/0 disables (execute uses no timeout). Default 15000.
---@field trace boolean?  Log wire traffic at TRACE level.
---@field respawn boolean?  Auto-respawn on unexpected exit with backoff (default true).

---@class jove.bridge
---@field _opts jove.bridge.Opts
local Bridge = {}
Bridge.__index = Bridge
M.Bridge = Bridge

---@param opts jove.bridge.Opts?
---@return jove.bridge
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Bridge)
  self._opts = {
    bridge_python = opts.bridge_python,
    timeout_ms = opts.timeout_ms,
    trace = opts.trace,
    respawn = opts.respawn,
  }
  self._handlers = {}
  self._pending = {}
  self._queue = {}
  self._next_id = 1
  self._ready = false
  self._job = nil
  self._rbuf = ""
  self._stderr = ""
  self._stopping = false
  self._shutdown_sent = false
  self._respawn_attempts = 0
  self._started = false
  self._start_cb = nil
  self._stop_cbs = nil
  self._ready_timer = nil
  self._respawn_timer = nil
  return self
end

---@param cb fun(ok: boolean, err: string?)?
---@return jove.bridge self
function Bridge:start(cb)
  if self._job then
    if cb then
      vim.schedule(function()
        cb(true)
      end)
    end
    return self
  end
  self._started = true
  self._stopping = false
  self._shutdown_sent = false
  self._respawn_attempts = 0
  self._start_cb = cb
  self:_spawn()
  return self
end

---@private
function Bridge:_spawn()
  local pythonpath = vim.fs.joinpath(plugin_root(), "python")
  local existing = vim.env.PYTHONPATH
  if existing and existing ~= "" then
    pythonpath = pythonpath .. path_sep() .. existing
  end
  local python = M.resolve_python(self._opts.bridge_python)
  local handle = self
  local jobid = impl.jobstart({ python, "-m", "jove_bridge" }, {
    env = { PYTHONPATH = pythonpath },
    on_stdout = function(...)
      handle:_on_stdout(...)
    end,
    on_stderr = function(...)
      handle:_on_stderr(...)
    end,
    on_exit = function(...)
      handle:_on_exit(...)
    end,
  })
  if type(jobid) ~= "number" or jobid <= 0 then
    local msg = (
      "jove: bridge_python %q not found; set jove.bridge_python or install "
      .. "jupyter_client (pip install jupyter_client ipykernel) — then :checkhealth jove%s"
    ):format(python, self:_stderr_tail())
    vim.notify(msg, vim.log.levels.ERROR)
    self:_fail_pending(msg)
    local cb = self._start_cb
    self._start_cb = nil
    if cb then
      vim.schedule(function()
        cb(false, msg)
      end)
    end
    return
  end
  self._job = jobid
  self._next_id = 1
  self._ready = false
  self._rbuf = ""
  self._ready_timer = vim.defer_fn(function()
    self._ready_timer = nil
    if self._ready or not self._job then
      return
    end
    local job = self._job
    self:_fail_pending("bridge readiness timeout")
    vim.notify(
      ("[jove] bridge did not become ready within %dms; killing it%s"):format(
        M.ready_timeout_ms,
        self:_stderr_tail()
      ),
      vim.log.levels.ERROR
    )
    impl.jobstop(job)
  end, M.ready_timeout_ms)
  local cb = self._start_cb
  self._start_cb = nil
  if cb then
    vim.schedule(function()
      cb(true)
    end)
  end
end

---@param method string
---@param params table?
---@param cb fun(result: table?, err: any)?
---@param opts {timeout_ms: integer|boolean?}?
---@return jove.bridge self
function Bridge:request(method, params, cb, opts)
  opts = opts or {}
  local timeout = opts.timeout_ms
  if timeout == nil then
    timeout = self._opts.timeout_ms ~= nil and self._opts.timeout_ms or DEFAULT_TIMEOUT_MS
  end
  local req = { method = method, params = params or {}, cb = cb, timeout_ms = timeout }
  if self._ready then
    self:_send(req)
  elseif self._started and self._job == nil and self._respawn_timer == nil then
    if cb then
      vim.schedule(function()
        cb(nil, "bridge not running")
      end)
    end
  else
    table.insert(self._queue, req)
  end
  return self
end

---@private
---@param req {method: string, params: table, cb: function?, timeout_ms: integer|boolean}
function Bridge:_send(req)
  local id = self._next_id
  self._next_id = id + 1
  if req.method == "shutdown" then
    self._shutdown_sent = true
  end
  local entry = { cb = req.cb }
  if req.timeout_ms and req.timeout_ms > 0 then
    entry.timer = vim.defer_fn(function()
      entry.timer = nil
      if self._pending[id] ~= entry then
        return
      end
      self._pending[id] = nil
      self:_trace(("timeout after %dms: %s"):format(req.timeout_ms, req.method))
      if entry.cb then
        vim.schedule(function()
          entry.cb(nil, ("timeout after %dms (%s)"):format(req.timeout_ms, req.method))
        end)
      end
    end, req.timeout_ms)
  end
  self._pending[id] = entry
  local payload = { id = id, method = req.method }
  if next(req.params) ~= nil then
    payload.params = req.params
  end
  local line = vim.json.encode(payload)
  self:_trace("> " .. line)
  local ok, err = pcall(impl.jobsend, self._job, line .. "\n")
  if not ok then
    if entry.timer then
      cancel_timer(entry.timer)
    end
    self._pending[id] = nil
    if entry.cb then
      vim.schedule(function()
        entry.cb(nil, "bridge unavailable: " .. tostring(err))
      end)
    end
  end
end

---@param event string
---@param handler fun(params: table?)
---@return fun()
function Bridge:on(event, handler)
  local list = self._handlers[event]
  if not list then
    list = {}
    self._handlers[event] = list
  end
  table.insert(list, handler)
  return function()
    for i, h in ipairs(list) do
      if h == handler then
        table.remove(list, i)
        break
      end
    end
  end
end

---@return boolean
function Bridge:is_ready()
  return self._ready and self._job ~= nil
end

---@return boolean
function Bridge:is_alive()
  return self._job ~= nil
end

---@return string
function Bridge:stderr()
  return self._stderr
end

---@param cb fun()?
---@return jove.bridge self
function Bridge:stop(cb)
  self._stopping = true
  if self._respawn_timer then
    cancel_timer(self._respawn_timer)
    self._respawn_timer = nil
  end
  if self._ready_timer then
    cancel_timer(self._ready_timer)
    self._ready_timer = nil
  end
  if not self._job then
    self:_fail_pending("bridge stopped")
    if cb then
      vim.schedule(cb)
    end
    return self
  end
  local job = self._job
  if cb then
    self._stop_cbs = self._stop_cbs or {}
    table.insert(self._stop_cbs, cb)
  end
  if self._ready then
    self:request("shutdown", {}, nil, { timeout_ms = SHUTDOWN_GRACE_MS })
  end
  vim.defer_fn(function()
    if self._job == job then
      impl.jobstop(job)
    end
  end, SHUTDOWN_GRACE_MS + 500)
  return self
end

---@param cb fun(ok: boolean, err: string?)?
---@return jove.bridge
function M.start(cb)
  return M.new():start(cb)
end

local VARIABLES_TIMEOUT_MS = 5000

---@param buf integer
---@return string?
local function language_of(buf)
  local state = require("jove.state")
  local entry = state.peek(buf)
  local k = entry and entry.kernel
  if k and type(k.language) == "string" and k.language ~= "" then
    return k.language
  end
  local json = entry and entry.json
  local ks = json and json.metadata and json.metadata.kernelspec
  if ks and type(ks.language) == "string" and ks.language ~= "" then
    return ks.language
  end
  return nil
end

---@param buf integer  Buffer handle (0 = current).
---@param cb fun(result: {variables: table[]?, unsupported: string?})?
function M.variables(buf, cb)
  buf = (buf == 0 or buf == nil) and vim.api.nvim_get_current_buf() or buf
  local respond = function(result)
    if cb then
      vim.schedule(function()
        cb(result)
      end)
    end
  end

  local language = language_of(buf)
  if language ~= nil and language ~= "python" then
    respond({ variables = nil, unsupported = language })
    return
  end

  local state = require("jove.state")
  local entry = state.peek(buf)
  local k = entry and entry.kernel
  if not (k and k.name and k.bridge and k.bridge:is_alive()) then
    respond({ variables = {} })
    return
  end

  k.bridge:request("variables", {}, function(result, err)
    if err or type(result) ~= "table" or type(result.variables) ~= "table" then
      vim.notify(
        ("[jove] variable inspector: request failed (%s)"):format(tostring(err or "bad reply")),
        vim.log.levels.WARN
      )
      respond({ variables = {} })
      return
    end
    respond(result)
  end, { timeout_ms = VARIABLES_TIMEOUT_MS })
end

---@private
function Bridge:_on_stdout(_, data)
  self._rbuf = self._rbuf .. table.concat(data, "\n")
  while true do
    local nl = self._rbuf:find("\n", 1, true)
    if not nl then
      break
    end
    local line = self._rbuf:sub(1, nl - 1)
    self._rbuf = self._rbuf:sub(nl + 1)
    self:_handle_line(line)
  end
end

---@private
---@param line string
function Bridge:_handle_line(line)
  if line == "" then
    return
  end
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" then
    self:_trace("< unparseable line: " .. line)
    self:_dispatch("protocol_error", { line = line })
    return
  end
  self:_trace("< " .. line)
  if type(msg.event) == "string" then
    if msg.event == "ready" then
      self._ready = true
      self._respawn_attempts = 0
      if self._ready_timer then
        cancel_timer(self._ready_timer)
        self._ready_timer = nil
      end
      self:_flush_queue()
    end
    self:_dispatch(msg.event, msg.params)
    return
  end
  if msg.id ~= nil then
    self:_resolve_response(msg.id, msg)
  end
end

---@private
---@param id integer
---@param msg table  -- decoded response: {id, result} or {id, error}
function Bridge:_resolve_response(id, msg)
  local entry = self._pending[id]
  if not entry then
    self:_trace("< response for unknown id " .. tostring(id))
    return
  end
  self._pending[id] = nil
  if entry.timer then
    cancel_timer(entry.timer)
    entry.timer = nil
  end
  vim.schedule(function()
    if not entry.cb then
      return
    end
    if msg.error ~= nil then
      entry.cb(nil, msg.error)
    else
      entry.cb(msg.result)
    end
  end)
end

---@private
---@param event string
---@param params table?
function Bridge:_dispatch(event, params)
  local handlers = self._handlers[event]
  if not handlers or #handlers == 0 then
    return
  end
  vim.schedule(function()
    for _, handler in ipairs(handlers) do
      local ok, err = pcall(handler, params)
      if not ok then
        vim.notify("[jove] bridge event handler error: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end)
end

---@private
function Bridge:_flush_queue()
  local queue = self._queue
  self._queue = {}
  for _, req in ipairs(queue) do
    self:_send(req)
  end
end

---@private
---@param reason string
function Bridge:_fail_pending(reason)
  local pending = self._pending
  self._pending = {}
  for _, entry in pairs(pending) do
    if entry.timer then
      cancel_timer(entry.timer)
      entry.timer = nil
    end
    if entry.cb then
      vim.schedule(function()
        entry.cb(nil, reason)
      end)
    end
  end
  local queue = self._queue
  self._queue = {}
  for _, req in ipairs(queue) do
    if req.cb then
      vim.schedule(function()
        req.cb(nil, reason)
      end)
    end
  end
end

---@private
function Bridge:_on_stderr(_, data)
  self._stderr = self._stderr .. table.concat(data, "\n")
  if #self._stderr > 65536 then
    self._stderr = self._stderr:sub(-65536)
  end
end

---@private
---@return string  -- "" when there is no stderr to show
function Bridge:_stderr_tail()
  local lines = vim.split(self._stderr, "\n", { plain = true })
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  if #lines == 0 then
    return ""
  end
  local tail = table.concat(lines, " | ", math.max(1, #lines - 4), #lines)
  if #tail > 200 then
    tail = "…" .. tail:sub(-199)
  end
  return " stderr: " .. tail
end

---@private
---@param code integer
function Bridge:_on_exit(_, code)
  self._job = nil
  self._ready = false
  if self._ready_timer then
    cancel_timer(self._ready_timer)
    self._ready_timer = nil
  end
  self:_fail_pending(("bridge exited (code %d)"):format(code))
  local stop_cbs = self._stop_cbs or {}
  self._stop_cbs = nil
  local expected = self._stopping or self._shutdown_sent
  local attempts = self._respawn_attempts
  vim.schedule(function()
    for _, cb in ipairs(stop_cbs) do
      pcall(cb)
    end
    self:_dispatch("dead", { code = code })
    if expected then
      return
    end
    if self._opts.respawn == false or attempts >= MAX_RESPAWNS then
      self._respawn_attempts = 0
      vim.notify(
        (
          "[jove] bridge exited unexpectedly (code %d) and won't restart; "
          .. "run :checkhealth jove%s"
        ):format(code, self:_stderr_tail()),
        vim.log.levels.ERROR
      )
      return
    end
    local delay = M.respawn_backoff_ms[attempts + 1] or M.respawn_backoff_ms[#M.respawn_backoff_ms]
    self._respawn_attempts = attempts + 1
    self:_trace(("unexpected exit (code %d); respawn in %dms"):format(code, delay))
    self._respawn_timer = vim.defer_fn(function()
      self._respawn_timer = nil
      if self._job or self._stopping or self._shutdown_sent then
        return
      end
      self:_spawn()
    end, delay)
  end)
end

---@private
---@param msg string
function Bridge:_trace(msg)
  if not (self._opts.trace or M.trace) then
    return
  end
  vim.notify("[jove][bridge] " .. msg, vim.log.levels.TRACE)
end

return M

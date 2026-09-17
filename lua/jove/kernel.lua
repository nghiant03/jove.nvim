-- kernel.lua: per-buffer kernel lifecycle over the Python stdio bridge.
-- One bridge process per buffer (one kernel per bridge).
-- Resolution order for the kernelspec: notebook metadata -> active
-- conda/venv name -> vim.ui.select picker.
local state = require("jove.state")
local bridge_mod = require("jove.bridge")

local M = {}

-- Buffer-local BufWipeout cleanup hooks live in their own augroup so a
-- replaced kernel can clear its predecessor's hook without touching others.
local wipe_group = vim.api.nvim_create_augroup("jove_kernel_wipeout", { clear = false })

---@param buf integer
---@return integer
local function norm_buf(buf)
  return buf == 0 and vim.api.nvim_get_current_buf() or buf
end

---@param err any
---@return string
local function describe_err(err)
  if type(err) == "table" then
    return err.message or err.code or vim.inspect(err)
  end
  return tostring(err)
end

---Report bridge or dependency failures with setup instructions.
---@param err any
local function notify_bridge_unavailable(err)
  vim.notify(
    (
      "[jove] kernel bridge unavailable: %s\n"
      .. "Install the Python deps: pip install jupyter_client ipykernel\n"
      .. "Then run :checkhealth jove. If your Python lives in a virtualenv or "
      .. "conda env, point `jove.bridge_python` at its interpreter."
    ):format(describe_err(err)),
    vim.log.levels.ERROR
  )
end

local function notify_no_kernel()
  vim.notify("[jove] No kernel running", vim.log.levels.INFO)
end

---Return the kernelspec.name from the buffer's cached JSON, if any.
---@param buf integer
---@return string?
local function kernelspec_name(buf)
  local entry = state.peek(buf)
  local json = entry and entry.json
  if type(json) ~= "table" then
    return nil
  end
  local ks = json.metadata and json.metadata.kernelspec
  if ks and type(ks.name) == "string" and ks.name ~= "" then
    return ks.name
  end
  return nil
end

---Best-effort guess of the active python environment name.
---@return string?
local function active_env_name()
  local conda = vim.env.CONDA_DEFAULT_ENV
  if conda and conda ~= "" then
    return conda
  end
  local venv = vim.env.VIRTUAL_ENV
  if venv and venv ~= "" then
    return vim.fs.basename(venv)
  end
  return nil
end

---Sorted kernelspec names for the picker.
---@param specs table<string, {display_name: string?, language: string?}>
---@return string[]
local function spec_names(specs)
  local names = {}
  for name in pairs(specs) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

---Pick a kernelspec: metadata -> env -> picker (metadata/env skipped when
---`force` is set, i.e. the user explicitly asked to choose).
---@param specs table<string, {display_name: string?, language: string?}>
---@param metadata_name string?
---@param force boolean
---@param cb fun(name: string?, spec: table?)
local function resolve_kernelspec(specs, metadata_name, force, cb)
  if not force then
    if metadata_name and specs[metadata_name] then
      cb(metadata_name, specs[metadata_name])
      return
    end
    local env = active_env_name()
    if env and specs[env] then
      cb(env, specs[env])
      return
    end
  end
  local names = spec_names(specs)
  if #names == 0 then
    cb(nil)
    return
  end
  -- A modal picker can't be shown without a UI (headless nvim, batch runs);
  -- blocking on it there would hang the process — treat as canceled instead.
  if #vim.api.nvim_list_uis() == 0 then
    cb(nil)
    return
  end
  vim.ui.select(names, {
    prompt = "Select kernel",
    format_item = function(name)
      local spec = specs[name] or {}
      return ("%s (%s)"):format(name, spec.display_name or name)
    end,
  }, function(choice)
    cb(choice, choice and specs[choice] or nil)
  end)
end

---Start a kernel on `entry.bridge` and drive `entry.status` from events.
---@param buf integer
---@param entry {bridge: jove.bridge, name: string?, language: string?, status: string}
---@param name string
---@param spec table?  -- kernelspec (carries `language`)
local function start_kernel(buf, entry, name, spec)
  entry.name = name
  -- Lowercased kernelspec language (e.g. "python"), consumed by the UI
  -- inspector; preserved across restarts when no fresh spec is known.
  if spec and type(spec.language) == "string" and spec.language ~= "" then
    entry.language = spec.language:lower()
  end
  entry.status = "starting"
  -- Kernel process spawn can be slow on cold caches; give it more than the
  -- default request timeout.
  entry.bridge:request("start_kernel", { kernelspec = name }, function(_, err)
    if err then
      -- Dispose the whole handle, not just the name: with a retained dead
      -- entry, init() would no-op ("kernel handle exists") and shutdown()
      -- would report "No kernel running" without cleaning up — leaving no
      -- way to recover short of replacing the kernel or wiping the buffer.
      entry.name = nil
      entry.status = "dead"
      local st = state.peek(buf)
      if st and st.kernel == entry then
        st.kernel = nil
      end
      entry.bridge:stop()
      vim.notify(
        ("[jove] failed to start kernel %q: %s"):format(name, describe_err(err)),
        vim.log.levels.ERROR
      )
    end
    -- On success, kernel_status events drive entry.status from here on.
  end, { timeout_ms = 30000 })
end

---Register a buffer-local BufWipeout hook that tears the kernel+bridge down
---when the buffer goes away (state.lua cannot do this: kernel requires state,
---so state must not require kernel). Buffer-local autocmds die with the
---buffer, and the predecessor's hook is cleared when a kernel is replaced,
---making this idempotent per buffer.
---@param buf integer
---@param entry {bridge: jove.bridge, name: string?, language: string?, status: string}
local function attach_wipeout(buf, entry)
  vim.api.nvim_clear_autocmds({ group = wipe_group, buffer = buf })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = wipe_group,
    buffer = buf,
    callback = function(ev)
      -- Drop the state slot first so late callbacks see a detached entry.
      local st = state.peek(ev.buf)
      if st and st.kernel == entry then
        st.kernel = nil
      end
      -- stop() sends `shutdown` (short grace) and falls back to jobstop,
      -- which kills the kernel with the bridge.
      entry.bridge:stop()
    end,
  })
end

---Initialize (bridge + kernel) for a buffer. No-op when a kernel handle
---already exists. `opts.force` shows the picker even if metadata/env match.
---@param buf integer
---@param opts {force: boolean?}?
function M.init(buf, opts)
  buf = norm_buf(buf)
  opts = opts or {}
  local st = state.get(buf)
  if st.kernel then
    return
  end

  local b = bridge_mod.new({ bridge_python = require("jove").config.bridge_python })
  local entry = { bridge = b, name = nil, language = nil, status = "starting", _last_name = nil }
  -- Reserve the slot up front so concurrent init() calls can't double-start;
  -- cleaned up on every failure path below.
  st.kernel = entry
  attach_wipeout(buf, entry)

  b:on("kernel_status", function(params)
    if type(params) == "table" and type(params.status) == "string" then
      entry.status = params.status
    end
  end)

  -- Bridge death: the kernel dies with it (one kernel per bridge). Clear the
  -- name so available() reports false and init() can be called again; keep
  -- the last kernelspec for a single bounded recovery attempt on respawn.
  b:on("dead", function()
    local was_running = entry.name
    entry.status = "dead"
    entry._last_name = entry.name or entry._last_name
    entry.name = nil
    if was_running and st.kernel == entry then
      vim.notify(
        ("[jove] kernel %q died with the bridge; restarting when the bridge recovers"):format(
          was_running
        ),
        vim.log.levels.INFO
      )
    end
  end)

  -- Bridge respawned and is ready again: restart the previous kernelspec
  -- (single attempt; start_kernel failure marks the entry dead + notifies).
  b:on("ready", function()
    if st.kernel ~= entry or entry.name or not entry._last_name then
      return
    end
    local last = entry._last_name
    entry._last_name = nil
    start_kernel(buf, entry, last)
  end)

  local function cleanup()
    st.kernel = nil
    b:stop()
  end

  b:start(function(ok, _err)
    if not ok then
      st.kernel = nil
    end
    -- Spawn failures were already notified by bridge.lua; nothing to queue.
  end)

  b:request("list_kernelspecs", {}, function(result, err)
    if st.kernel ~= entry then
      return -- buffer wiped or kernel replaced meanwhile
    end
    if not result or type(result.kernelspecs) ~= "table" then
      cleanup()
      notify_bridge_unavailable(err or "list_kernelspecs returned no kernelspecs")
      return
    end
    resolve_kernelspec(result.kernelspecs, kernelspec_name(buf), opts.force, function(name, spec)
      if st.kernel ~= entry then
        return
      end
      if not name then
        -- Picker canceled / no kernelspecs: drop the idle bridge.
        cleanup()
        return
      end
      start_kernel(buf, entry, name, spec)
    end)
  end)
end

---True when the buffer has a started kernel on a live bridge.
---@param buf integer
---@return boolean
function M.available(buf)
  local k = state.peek(norm_buf(buf))
  k = k and k.kernel
  return k ~= nil and k.name ~= nil and k.bridge ~= nil and k.bridge:is_alive()
end

---@param buf integer
function M.interrupt(buf)
  local st = state.get(norm_buf(buf))
  local k = st.kernel
  if not k or not k.name or not k.bridge:is_alive() then
    notify_no_kernel()
    return
  end
  k.bridge:request("interrupt", {}, function(_, err)
    if err then
      vim.notify("[jove] interrupt failed: " .. describe_err(err), vim.log.levels.ERROR)
    end
  end)
end

---@param buf integer
function M.restart(buf)
  local st = state.get(norm_buf(buf))
  local k = st.kernel
  if not k or not k.name or not k.bridge:is_alive() then
    notify_no_kernel()
    return
  end
  k.status = "restarting"
  -- Restart must outlast the sidecar's kernel-readiness probe (same as
  -- start_kernel's 30s) or it times out before the kernel is up.
  k.bridge:request("restart", {}, function(_, err)
    if err then
      vim.notify("[jove] restart failed: " .. describe_err(err), vim.log.levels.ERROR)
    end
  end, { timeout_ms = 30000 })
end

---Shut the kernel down and drop the handle. Bridge-side shutdown implies
---process exit, but the bridge is stopped explicitly too, so a
---missing/failed reply or a half-initialized entry can never leak a process.
---@param buf integer
---@param cb fun(err: string?)?
function M.shutdown(buf, cb)
  buf = norm_buf(buf)
  local st = state.get(buf)
  local k = st.kernel
  if not k then
    notify_no_kernel()
    if cb then
      vim.schedule(function()
        cb("No kernel running")
      end)
    end
    return
  end
  -- Dispose the slot unconditionally: entries without a running kernel
  -- (failed start, bridge dead) must still release their bridge so init()
  -- can recover and :JoveShutdownKernel stays the universal escape hatch.
  st.kernel = nil
  -- Shutdown also cancels any pending auto-restart (bridge-dead window):
  -- the user asked for the kernel to be gone.
  k._last_name = nil
  if k.name and k.bridge:is_alive() then
    k.bridge:request("shutdown", {}, function(_, err)
      -- Belt and braces: the bridge should exit 0 by itself after replying;
      -- stop() covers a wedged or already-dead process too.
      k.bridge:stop()
      if cb then
        cb(err and describe_err(err) or nil)
      end
    end)
  else
    k.bridge:stop()
    notify_no_kernel()
    if cb then
      vim.schedule(function()
        cb("No kernel running")
      end)
    end
  end
end

---Force the kernel picker, replacing any existing kernel (old one is shut
---down first).
---@param buf integer
function M.select(buf)
  buf = norm_buf(buf)
  local st = state.get(buf)
  local k = st.kernel
  if k then
    st.kernel = nil
    if k.bridge:is_alive() then
      k.bridge:request("shutdown", {}, nil)
    end
    k.bridge:stop()
  end
  M.init(buf, { force = true })
end

return M

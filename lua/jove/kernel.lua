-- Kernel lifecycle over the Python stdio bridge.
local state = require("jove.state")
local bridge_mod = require("jove.bridge")

local M = {}

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

---@param err any
local function notify_bridge_unavailable(err)
  vim.notify(
    (
      "[Jove] kernel bridge unavailable: %s\n"
      .. "Install the Python deps: pip install jupyter_client ipykernel\n"
      .. "Then run :checkhealth jove. If your Python lives in a virtualenv or "
      .. "conda env, point `jove.bridge_python` at its interpreter."
    ):format(describe_err(err)),
    vim.log.levels.ERROR
  )
end

local function notify_no_kernel()
  vim.notify("[Jove] No kernel running", vim.log.levels.INFO)
end

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

---@class jove.KernelEntry
---@field bridge jove.bridge
---@field name string?
---@field language string?
---@field status string
---@field _last_name string?

---@param buf integer
---@param entry jove.KernelEntry
---@param name string
---@param spec table?  -- kernelspec (carries `language`)
local function start_kernel(buf, entry, name, spec)
  entry.name = name
  if spec and type(spec.language) == "string" and spec.language ~= "" then
    entry.language = spec.language:lower()
  end
  entry.status = "starting"
  entry.bridge:request("start_kernel", { kernelspec = name }, function(_, err)
    if err then
      entry.name = nil
      entry.status = "dead"
      local st = state.peek(buf)
      if st and st.kernel == entry then
        st.kernel = nil
      end
      entry.bridge:stop()
      vim.notify(
        ("[Jove] failed to start kernel %q: %s"):format(name, describe_err(err)),
        vim.log.levels.ERROR
      )
    end
  end, { timeout_ms = 30000 })
end

---@param buf integer
---@param entry jove.KernelEntry
local function attach_wipeout(buf, entry)
  vim.api.nvim_clear_autocmds({ group = wipe_group, buffer = buf })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = wipe_group,
    buffer = buf,
    callback = function(ev)
      local st = state.peek(ev.buf)
      if st and st.kernel == entry then
        st.kernel = nil
      end
      entry.bridge:stop()
    end,
  })
end

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
  ---@type jove.KernelEntry
  local entry = { bridge = b, name = nil, language = nil, status = "starting", _last_name = nil }
  st.kernel = entry
  attach_wipeout(buf, entry)

  b:on("kernel_status", function(params)
    if type(params) == "table" and type(params.status) == "string" then
      entry.status = params.status
    end
  end)

  b:on("dead", function()
    local was_running = entry.name
    entry.status = "dead"
    entry._last_name = entry.name or entry._last_name
    entry.name = nil
    if was_running and st.kernel == entry then
      vim.notify(
        ("[Jove] kernel %q died with the bridge, restarting when the bridge recovers"):format(
          was_running
        ),
        vim.log.levels.INFO
      )
    end
  end)

  b:on("ready", function()
    if st.kernel ~= entry or entry.name then
      return
    end
    local last = entry._last_name
    if not last then
      return
    end
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
  end)

  b:request("list_kernelspecs", {}, function(result, err)
    if st.kernel ~= entry then
      return
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
        cleanup()
        return
      end
      start_kernel(buf, entry, name, spec)
    end)
  end)
end

---@param buf integer
---@return boolean
function M.available(buf)
  local st = state.peek(norm_buf(buf))
  local k = st and st.kernel
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
      vim.notify("[Jove] interrupt failed: " .. describe_err(err), vim.log.levels.ERROR)
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
  k.bridge:request("restart", {}, function(_, err)
    if err then
      vim.notify("[Jove] restart failed: " .. describe_err(err), vim.log.levels.ERROR)
    end
  end, { timeout_ms = 30000 })
end

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
  st.kernel = nil
  k._last_name = nil
  if k.name and k.bridge:is_alive() then
    k.bridge:request("shutdown", {}, function(_, err)
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

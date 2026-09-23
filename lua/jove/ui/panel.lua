-- Kernel and session status for the statusline and the sidebar kernel tab.
local state = require("jove.state")

local M = {}

---@param buf integer?
---@return integer
local function norm_buf(buf)
  if buf == nil or buf == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return buf
end

---@param path string
---@return string
local function short_path(path)
  if path:match("^/") or path:match("^%a:[/\\]") then
    return vim.fn.fnamemodify(path, ":t")
  end
  return path
end

---@param buf integer?
---@return string
function M.status(buf)
  buf = norm_buf(buf)
  local st = state.peek(buf)
  local k = st and st.kernel
  if not k or not k.name or not k.bridge or not k.bridge:is_alive() then
    return ""
  end
  local busy = k.status == "busy" or k.status == "starting" or k.status == "restarting"
  return ("⚡ %s · %s"):format(k.name, busy and "busy" or "idle")
end

---@param buf integer?
---@return {kernel: string?, status: string?, queue_len: integer}
function M.info(buf)
  buf = norm_buf(buf)
  local st = state.peek(buf)
  local k = st and st.kernel
  return {
    kernel = k and k.name or nil,
    status = k and k.status or nil,
    queue_len = require("jove.execute").queue_len(buf),
  }
end

---@class jove.ui.RunningKernel
---@field buf integer
---@field path string
---@field kernel string?
---@field status string?
---@field alive boolean

---@return jove.ui.RunningKernel[]
function M.running_kernels()
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local st = state.peek(buf)
    local k = st and st.kernel
    if k then
      local path = st.path
      if path == nil or path == "" then
        path = vim.api.nvim_buf_get_name(buf)
      end
      out[#out + 1] = {
        buf = buf,
        path = path,
        kernel = k.name,
        status = k.status,
        alive = (k.bridge and k.bridge:is_alive()) or false,
      }
    end
  end
  table.sort(out, function(a, b)
    return a.path < b.path
  end)
  return out
end

---@class jove.ui.Kernelspec
---@field name string
---@field display_name string
---@field language string?

---@param cb fun(specs: jove.ui.Kernelspec[]?, err: string?)
function M.installed_kernelspecs(cb)
  local bridge_mod = require("jove.bridge")

  local function normalize(result)
    local raw = {}
    if type(result) == "table" and type(result.kernelspecs) == "table" then
      raw = result.kernelspecs
    end
    local specs = {}
    for name, spec in pairs(raw) do
      specs[#specs + 1] = {
        name = spec.name or name,
        display_name = spec.display_name or spec.name or name,
        language = spec.language,
      }
    end
    table.sort(specs, function(a, b)
      return a.name < b.name
    end)
    return specs
  end

  local reusable
  local cur = state.peek(vim.api.nvim_get_current_buf())
  if cur and cur.kernel and cur.kernel.bridge and cur.kernel.bridge:is_alive() then
    reusable = cur.kernel.bridge
  else
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local st = state.peek(buf)
      local b = st and st.kernel and st.kernel.bridge
      if b and b:is_alive() then
        reusable = b
        break
      end
    end
  end

  if reusable then
    reusable:request("list_kernelspecs", {}, function(result, err)
      if err then
        cb(nil, tostring(err))
        return
      end
      cb(normalize(result))
    end)
    return
  end

  local temp = bridge_mod.new({ bridge_python = require("jove").config.bridge_python })
  local stopped = false
  local function stop_temp()
    if stopped then
      return
    end
    stopped = true
    temp:stop()
  end

  temp:start(function(ok, err)
    if not ok then
      cb(nil, tostring(err))
    end
  end)
  temp:request("list_kernelspecs", {}, function(result, err)
    stop_temp()
    if err then
      cb(nil, tostring(err))
      return
    end
    cb(normalize(result))
  end)
end

---Build the kernel info lines (session, running kernels, installed
---kernelspecs) for the sidebar kernel tab.
---@param buf integer
---@param specs jove.ui.Kernelspec[]?
---@param err string?
---@return string[]
function M.build_lines(buf, specs, err)
  local info = M.info(buf)
  local cur_st = state.peek(buf)
  local cur_kernel = cur_st and cur_st.kernel
  local cur_name = cur_kernel and cur_kernel.name
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    name = "(unnamed)"
  end

  local lines = {
    "jove kernel info",
    "",
    "session",
    string.rep("─", 16),
    ("buffer : %s"):format(short_path(name)),
    ("kernel : %s"):format(info.kernel or "(none)"),
    ("status : %s"):format(info.status or "(none)"),
    ("queued : %d"):format(info.queue_len or 0),
    "",
    "running kernels",
    string.rep("─", 16),
  }

  local running = M.running_kernels()
  if #running == 0 then
    lines[#lines + 1] = "(none)"
  else
    for _, r in ipairs(running) do
      local marker = r.buf == buf and "● " or "  "
      lines[#lines + 1] = ("%s%s · %s · %s"):format(
        marker,
        short_path(r.path),
        r.kernel or "(none)",
        r.status or "(none)"
      )
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "installed kernelspecs"
  lines[#lines + 1] = string.rep("─", 16)
  if err then
    lines[#lines + 1] = ("(unavailable: %s)"):format(err)
  elseif specs == nil then
    lines[#lines + 1] = "(loading…)"
  elseif #specs == 0 then
    lines[#lines + 1] = "(no kernelspecs installed)"
  else
    for _, spec in ipairs(specs) do
      local marker = spec.name == cur_name and "● " or "  "
      lines[#lines + 1] = ("%s%s  %s"):format(marker, spec.name, spec.display_name or spec.name)
    end
  end
  return lines
end

return M

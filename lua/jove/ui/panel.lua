-- ui/panel.lua: kernel/session status for the statusline (and a future float).
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

---Statusline component: "⚡ python3 · busy" while a kernel runs, "" when none.
---Busy covers busy/starting/restarting; idle/idle-ish statuses show idle.
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

---Session info table for a future float: kernel name/status + queue length.
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

return M

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

---Build (but do not open) a float buffer showing `M.info(buf)`. The caller
---opens it with `nvim_open_win(fbuf, true, float.opts)`; `q`/`<Esc>` close.
---Centered, ~80% of the editor width, sized to the content.
---@param buf integer?
---@return {buf: integer, lines: string[], opts: table}
function M.info_float(buf)
  buf = norm_buf(buf)
  local info = M.info(buf)
  local lines = {
    "jove kernel info",
    string.rep("─", 16),
    ("kernel : %s"):format(info.kernel or "(none)"),
    ("status : %s"):format(info.status or "(none)"),
    ("queued : %d"):format(info.queue_len or 0),
  }

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.bo[fbuf].buflisted = false
  vim.bo[fbuf].bufhidden = "wipe"

  local width = math.max(30, math.floor(vim.o.columns * 0.8))
  local height = math.max(3, #lines)
  local opts = {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    style = "minimal",
  }
  return { buf = fbuf, lines = lines, opts = opts }
end

return M

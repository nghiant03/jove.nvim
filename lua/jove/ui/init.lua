-- ui/init.lua: cell status rendering (gutter signs + running-cell spinner).
-- Reacts to execute.lua status transitions via M.on_status; attach() is
-- idempotent per buffer (keymaps.apply calls it from the FileType autocmd).
-- ok/error signs stay in place until the next run of that cell; error first
-- lines / output bodies are output.lua's business -- this module only does
-- status chrome.
local cell = require("jove.cell")

local execute = require("jove.execute")

local state = require("jove.state")

local chrome = require("jove.ui.chrome")

local M = {}

local ns = vim.api.nvim_create_namespace("jove_cell_status")

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧" }
local SPINNER_INTERVAL_MS = 120

-- Per-buffer rendering bookkeeping (extmark ids, spinner timer, unsub).
---@type table<integer, table>
local bufs = {}

---@param buf integer
---@return table
local function ensure(buf)
  local b = bufs[buf]
  if not b then
    b = { marks = {}, spinner = nil, spinner_row = nil, timer = nil, unsub = nil }
    bufs[buf] = b
  end
  return b
end

---@param b table
local function stop_spinner(buf, b)
  if b.timer then
    b.timer:stop()
    b.timer:close()
    b.timer = nil
  end
  if b.spinner then
    pcall(vim.api.nvim_buf_del_extmark, buf, ns, b.spinner)
    b.spinner = nil
    b.spinner_row = nil
  end
end

---Trailing elapsed suffix for the spinner text, e.g. " 0.4s". Empty when the
---`elapsed` option is off or the cell has no recorded elapsed_ms.
---@param buf integer
---@param hash string
---@return string
local function elapsed_suffix(buf, hash)
  local cfg = require("jove").config
  local ui = cfg.ui
  if type(ui) == "table" and ui.elapsed == false then
    return ""
  end
  local st = state.peek(buf)
  local meta = st and st.exec and st.exec.meta
  local m = meta and meta[hash]
  if m and type(m.elapsed_ms) == "number" then
    return (" %.1fs"):format(m.elapsed_ms / 1000)
  end
  return ""
end

---@param buf integer
---@param lnum integer  1-based cell start line
---@param hash string
local function start_spinner(buf, b, lnum, hash)
  stop_spinner(buf, b)
  local row = lnum - 1
  b.spinner = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
    virt_text = { { SPINNER_FRAMES[1] .. elapsed_suffix(buf, hash), "DiagnosticInfo" } },
    virt_text_pos = "eol",
  })
  b.spinner_row = row
  local i = 0
  local timer = vim.uv.new_timer()
  b.timer = timer
  timer:start(
    0,
    SPINNER_INTERVAL_MS,
    vim.schedule_wrap(function()
      -- Buffer wiped or spinner replaced mid-flight: stop the loop.
      if b.timer ~= timer or not vim.api.nvim_buf_is_valid(buf) then
        if b.timer == timer then
          b.timer = nil
        end
        timer:stop()
        timer:close()
        return
      end
      i = i + 1
      local frame = SPINNER_FRAMES[(i % #SPINNER_FRAMES) + 1]
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, b.spinner_row, 0, {
        id = b.spinner,
        virt_text = { { frame .. elapsed_suffix(buf, hash), "DiagnosticInfo" } },
        virt_text_pos = "eol",
      })
    end)
  )
end

---Whether cell headers are concealed (defensive config read).
---@return boolean
local function conceal_headers()
  local ok, jove = pcall(require, "jove")
  local ui = ok and type(jove) == "table" and jove.config and jove.config.ui
  return type(ui) == "table" and ui.conceal_headers ~= false or type(ui) ~= "table"
end

---Find the line the cell's status sign/spinner belongs on: the header line,
---or the first body line when headers are concealed (the header is not drawn
---and a sign on it would be invisible).
---@param buf integer
---@param hash string
---@return integer?
local function cell_lnum(buf, hash)
  for _, c in ipairs(cell.all(buf)) do
    if c.hash == hash then
      if conceal_headers() and c.header then
        local body = c.header + 1
        return body <= c.end_lnum and body or c.header
      end
      return c.start_lnum
    end
  end
  return nil
end

---Status transition handler (also callable directly; tests use this).
---@param buf integer
---@param hash string
---@param status "queued"|"running"|"ok"|"error"
function M.on_status(buf, hash, status)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local b = bufs[buf]
  if not b or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- Terminal statuses always stop the spinner, even if the cell can no
  -- longer be resolved below (edited away mid-run): a leaked 120ms timer
  -- would spin forever until the next resolvable status change.
  if status == "ok" or status == "error" then
    stop_spinner(buf, b)
  end

  local lnum = cell_lnum(buf, hash)
  if not lnum then
    -- Cell deleted/unresolvable: sweep its stale sign extmark (by id -- the
    -- line it lived on may be gone, so no lnum-based cleanup is possible).
    if b.marks[hash] then
      pcall(vim.api.nvim_buf_del_extmark, buf, ns, b.marks[hash])
      b.marks[hash] = nil
    end
    return
  end

  local sign = require("jove").config.signs[status]
  if sign then
    -- One extmark per cell hash, updated in place on transitions.
    local id = vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
      id = b.marks[hash],
      sign_text = sign .. " ",
      priority = 10,
    })
    b.marks[hash] = id
  end

  if status == "running" then
    start_spinner(buf, b, lnum, hash)
  end
end

---Start reacting to execute.lua status transitions for `buf`. Idempotent.
---@param buf integer
function M.attach(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local b = ensure(buf)
  -- Cell chrome (concealment, rules, active highlight) is idempotent on its
  -- own; attach it regardless of the status-subscription early return.
  chrome.attach(buf)
  if b.unsub then
    return
  end
  b.unsub = execute.on_status(buf, function(hash, status)
    M.on_status(buf, hash, status)
  end)
end

-- Drop bookkeeping (timers!) when a buffer goes away.
vim.api.nvim_create_autocmd("BufWipeout", {
  group = vim.api.nvim_create_augroup("jove_ui", { clear = false }),
  pattern = "*",
  callback = function(ev)
    local b = bufs[ev.buf]
    if b then
      stop_spinner(ev.buf, b)
      if b.unsub then
        pcall(b.unsub)
      end
      bufs[ev.buf] = nil
    end
    chrome.detach(ev.buf)
  end,
})

return M

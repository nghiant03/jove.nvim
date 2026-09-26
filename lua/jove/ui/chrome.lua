-- Cell header concealment, borders, and active-cell highlighting.

local cell = require("jove.cell")
local state = require("jove.state")
local execute = require("jove.execute")
local lang = require("jove.lang")

local M = {}

M.ns = vim.api.nvim_create_namespace("jove_cell_chrome")

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧" }
local SPINNER_INTERVAL_MS = 120

local spin_frame = 0

vim.api.nvim_set_hl(0, "JoveActiveCell", { link = "CursorLine", default = true })
vim.api.nvim_set_hl(0, "JoveCellRule", { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "JoveCellRuleCount", { link = "Special", default = true })
vim.api.nvim_set_hl(0, "JoveCellRuleElapsed", { link = "Number", default = true })
vim.api.nvim_set_hl(0, "JoveCellBorder", { link = "Comment", default = true })

---@class jove.ChromeBook
---@field rules integer[]   per-cell rule extmark ids
---@field active integer?   active-cell highlight extmark id
---@field group integer?    autocmd group for this buffer
---@field unsub fun()?      execute.on_status unsubscribe
---@field refresh_pending boolean? a vim.schedule() refresh is already queued
---@field spin_timer uv.uv_timer_t?  spinner animation timer (running cells)
---@field attached boolean

---@type table<integer, jove.ChromeBook>
local bufs = {}

---@return { conceal_headers: boolean, active_cell: boolean, exec_counts: boolean, elapsed: boolean, borders: boolean, border_hl: string|table? }
local function ui_conf()
  local ok, jove = pcall(require, "jove")
  local ui = ok and type(jove) == "table" and jove.config and jove.config.ui
  if type(ui) ~= "table" then
    ui = {}
  end
  return {
    conceal_headers = ui.conceal_headers ~= false,
    active_cell = ui.active_cell ~= false,
    exec_counts = ui.exec_counts ~= false,
    elapsed = ui.elapsed ~= false,
    borders = ui.borders ~= false,
    border_hl = ui.border_hl,
  }
end

---@param cfg string|table|nil
local function apply_border_hl(cfg)
  if cfg == nil then
    return
  end
  if type(cfg) == "string" then
    vim.api.nvim_set_hl(0, "JoveCellBorder", { link = cfg })
  else
    vim.api.nvim_set_hl(0, "JoveCellBorder", cfg)
  end
end

---@param buf integer
---@return integer
local function norm_buf(buf)
  return buf == 0 and vim.api.nvim_get_current_buf() or buf
end

---@param buf integer
---@return jove.ChromeBook
local function ensure(buf)
  local b = bufs[buf]
  if not b then
    b = {
      rules = {},
      active = nil,
      group = nil,
      unsub = nil,
      refresh_pending = false,
      spin_timer = nil,
      attached = false,
    }
    bufs[buf] = b
  end
  return b
end

---@param buf integer
---@param b jove.ChromeBook
local function clear_marks(buf, b)
  for _, id in ipairs(b.rules) do
    pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, id)
  end
  b.rules = {}
end

---@param c jove.Cell
---@return integer
local function body_start(c)
  return c.header and (c.header + 1) or c.start_lnum
end

---@param buf integer
---@param hash string
---@return string?
local function cell_status(buf, hash)
  local st = state.peek(buf)
  local exec = st and st.exec
  return exec and exec.status and exec.status[hash] or nil
end

---@param buf integer
---@param hash string
---@return table?
local function cell_meta(buf, hash)
  local st = state.peek(buf)
  local meta = st and st.exec and st.exec.meta
  return meta and meta[hash] or nil
end

---@param buf integer
---@param hash string
---@return number?  hrtime() start of the current run
local function cell_start_hr(buf, hash)
  local st = state.peek(buf)
  local start_hr = st and st.exec and st.exec.start_hr
  return start_hr and start_hr[hash] or nil
end

---@param status string?
---@return string
local function status_glyph(status)
  if status == "running" then
    return SPINNER_FRAMES[(spin_frame % #SPINNER_FRAMES) + 1]
  elseif status == "ok" then
    return "✓"
  elseif status == "error" then
    return "✗"
  end
  return "○"
end

---@param status string?
---@return string
local function status_hl(status)
  if status == "running" then
    return "DiagnosticInfo"
  elseif status == "ok" then
    return "DiagnosticOk"
  elseif status == "error" then
    return "DiagnosticError"
  end
  return "Comment"
end

---@param buf integer
---@return integer
local function win_width(buf)
  local wins = vim.fn.win_findbuf(buf)
  if #wins > 0 then
    local ok, w = pcall(vim.api.nvim_win_get_width, wins[1])
    if ok and type(w) == "number" and w > 0 then
      return w
    end
  end
  return vim.o.columns
end

---@param buf integer
---@param c jove.Cell
---@param cfg table
---@param cell_index integer  1-based index of the cell in the buffer
---@return table[] chunks
local function build_rule(buf, c, cfg, cell_index)
  local status = cell_status(buf, c.hash)
  local chunks = {
    { status_glyph(status) .. " ", status_hl(status) },
    { ("Cell %d "):format(cell_index), "JoveCellBorder" },
  }
  if c.kind == "markdown" then
    chunks[#chunks + 1] = { "── Markdown ", "JoveCellRule" }
  else
    local name = lang.for_buffer(buf).id
    chunks[#chunks + 1] =
      { ("── %s%s "):format(name:sub(1, 1):upper(), name:sub(2)), "JoveCellRule" }
    local meta = cell_meta(buf, c.hash)
    if cfg.exec_counts and meta and type(meta.count) == "number" then
      chunks[#chunks + 1] = { ("In [%d] "):format(meta.count), "JoveCellRuleCount" }
    end
    if cfg.elapsed then
      local start = status == "running" and cell_start_hr(buf, c.hash) or nil
      if start then
        chunks[#chunks + 1] =
          { ("┄┄ %.1fs "):format((vim.uv.hrtime() - start) / 1e9), "JoveCellRuleElapsed" }
      elseif meta and type(meta.elapsed_ms) == "number" then
        chunks[#chunks + 1] =
          { ("┄┄ %.1fs "):format(meta.elapsed_ms / 1000), "JoveCellRuleElapsed" }
      end
    end
  end

  local used = 0
  for _, chunk in ipairs(chunks) do
    used = used + vim.fn.strdisplaywidth(chunk[1])
  end
  local fill = win_width(buf) - used - 4
  local ruled = { { "╭─ ", "JoveCellBorder" } }
  for _, chunk in ipairs(chunks) do
    ruled[#ruled + 1] = chunk
  end
  if fill > 0 then
    ruled[#ruled + 1] = { string.rep("─", fill), "JoveCellBorder" }
  end
  ruled[#ruled + 1] = { "╮", "JoveCellBorder" }
  return ruled
end

---@param buf integer
---@return boolean
local function any_running(buf)
  local st = state.peek(buf)
  local status = st and st.exec and st.exec.status
  if type(status) ~= "table" then
    return false
  end
  for _, s in pairs(status) do
    if s == "running" then
      return true
    end
  end
  return false
end

---@param b jove.ChromeBook
local function stop_spinner(b)
  if b.spin_timer then
    b.spin_timer:stop()
    b.spin_timer:close()
    b.spin_timer = nil
  end
end

---@param buf integer
---@param b jove.ChromeBook
local function sync_spinner(buf, b)
  if not any_running(buf) then
    stop_spinner(b)
    return
  end
  if b.spin_timer then
    return
  end
  local timer = vim.uv.new_timer()
  b.spin_timer = timer
  timer:start(
    SPINNER_INTERVAL_MS,
    SPINNER_INTERVAL_MS,
    vim.schedule_wrap(function()
      if b.spin_timer ~= timer or not vim.api.nvim_buf_is_valid(buf) then
        if b.spin_timer == timer then
          b.spin_timer = nil
        end
        timer:stop()
        timer:close()
        return
      end
      if not any_running(buf) then
        stop_spinner(b)
        M.refresh(buf)
        return
      end
      spin_frame = spin_frame + 1
      M.refresh(buf)
    end)
  )
end

---@param buf integer
---@return integer?
local function cursor_lnum(buf)
  local wins = vim.fn.win_findbuf(buf)
  if #wins == 0 then
    return nil
  end
  local ok, pos = pcall(vim.api.nvim_win_get_cursor, wins[1])
  if not ok or type(pos) ~= "table" then
    return nil
  end
  return pos[1]
end

---@param buf integer
---@param b jove.ChromeBook
---@param cfg table
local function update_active(buf, b, cfg)
  if b.active then
    pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, b.active)
    b.active = nil
  end
  if not cfg.active_cell then
    return
  end
  local lnum = cursor_lnum(buf)
  if not lnum then
    return
  end
  local c = cell.at(buf, lnum)
  if not c then
    return
  end
  local first = body_start(c)
  if first > c.end_lnum then
    return
  end
  b.active = vim.api.nvim_buf_set_extmark(buf, M.ns, first - 1, 0, {
    end_row = c.end_lnum - 1,
    line_hl_group = "JoveActiveCell",
  })
end

---@param buf integer
function M.refresh(buf)
  buf = norm_buf(buf)
  if
    type(buf) ~= "number"
    or not vim.api.nvim_buf_is_valid(buf)
    or not vim.api.nvim_buf_is_loaded(buf)
  then
    return
  end
  if vim.in_fast_event() then
    vim.schedule(function()
      M.refresh(buf)
    end)
    return
  end

  local b = ensure(buf)
  local cfg = ui_conf()
  apply_border_hl(cfg.border_hl)
  clear_marks(buf, b)

  local cells = cell.all(buf)
  for i, c in ipairs(cells) do
    if c.header and cfg.conceal_headers then
      b.rules[#b.rules + 1] = vim.api.nvim_buf_set_extmark(buf, M.ns, c.header - 1, 0, {
        virt_text = build_rule(buf, c, cfg, i),
        virt_text_pos = "overlay",
        hl_mode = "combine",
      })
    else
      local bs = body_start(c)
      b.rules[#b.rules + 1] = vim.api.nvim_buf_set_extmark(buf, M.ns, bs - 1, 0, {
        virt_lines_above = true,
        virt_lines = { build_rule(buf, c, cfg, i) },
        hl_mode = "combine",
      })
    end

    if cfg.borders then
      local width = win_width(buf)
      local bottom
      if width < 3 then
        bottom = { { "╰╯", "JoveCellBorder" } }
      else
        bottom = {
          { "╰", "JoveCellBorder" },
          { string.rep("─", width - 2), "JoveCellBorder" },
          { "╯", "JoveCellBorder" },
        }
      end
      local out_cfg = require("jove").config.output or {}
      b.rules[#b.rules + 1] = vim.api.nvim_buf_set_extmark(buf, M.ns, c.end_lnum - 1, 0, {
        virt_lines_above = false,
        virt_lines = { bottom },
        right_gravity = out_cfg.inside_border == true,
        priority = 100,
      })
    end
  end

  update_active(buf, b, cfg)
end

---@param buf integer
function M.refresh_active(buf)
  buf = norm_buf(buf)
  local b = bufs[buf]
  if not b or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  update_active(buf, b, ui_conf())
end

---@param buf integer
function M.attach(buf)
  buf = norm_buf(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local b = ensure(buf)
  if b.attached then
    M.refresh(buf)
    return
  end
  b.attached = true
  sync_spinner(buf, b)

  local group = vim.api.nvim_create_augroup("jove_cell_chrome_" .. buf, { clear = true })
  b.group = group

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = group,
    buffer = buf,
    callback = function()
      M.refresh(buf)
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      if vim.api.nvim_buf_is_valid(buf) then
        M.refresh(buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter", "WinEnter" }, {
    group = group,
    buffer = buf,
    callback = function()
      M.refresh_active(buf)
    end,
  })

  b.unsub = execute.on_status(buf, function()
    sync_spinner(buf, b)
    if b.refresh_pending then
      return
    end
    b.refresh_pending = true
    vim.schedule(function()
      b.refresh_pending = false
      if bufs[buf] == b then
        M.refresh(buf)
      end
    end)
  end)

  M.refresh(buf)
end

---@param buf integer
function M.detach(buf)
  buf = norm_buf(buf)
  local b = bufs[buf]
  if not b then
    return
  end
  stop_spinner(b)
  if b.group then
    pcall(vim.api.nvim_del_augroup_by_id, b.group)
  end
  if b.unsub then
    pcall(b.unsub)
  end
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_clear_namespace, buf, M.ns, 0, -1)
  end
  bufs[buf] = nil
end

vim.api.nvim_create_autocmd("BufWipeout", {
  group = vim.api.nvim_create_augroup("jove_cell_chrome_wipeout", { clear = true }),
  pattern = "*",
  callback = function(ev)
    if bufs[ev.buf] then
      M.detach(ev.buf)
    end
  end,
})

return M

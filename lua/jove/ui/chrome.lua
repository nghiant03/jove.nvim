-- chrome.lua: cell chrome for jove buffers (PLAN.md Phase B).
--
-- Responsibilities:
--   * conceal jupytext-style front matter (`# ---` ... `# ---`) and cell
--     headers (`# %%`) with `conceal_lines = ""` extmarks;
--   * draw a per-cell rule (virt_lines) above each cell body carrying the
--     status glyph, execution count and elapsed time;
--   * highlight the body of the cell under the cursor (`JoveActiveCell`).
--
-- Everything is opt-in through `config.ui` (read defensively; a missing
-- `ui` table falls back to the documented defaults). The module never assumes
-- a kernel exists: buffers with no execute state still get rules with an
-- "unread" glyph and no count/elapsed.
local cell = require("jove.cell")
local state = require("jove.state")
local execute = require("jove.execute")

local M = {}

M.ns = vim.api.nvim_create_namespace("jove_cell_chrome")

-- Highlight groups (default links; users can override before setup()).
vim.api.nvim_set_hl(0, "JoveActiveCell", { link = "CursorLine", default = true })
vim.api.nvim_set_hl(0, "JoveCellRule", { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "JoveCellRuleCount", { link = "Special", default = true })
vim.api.nvim_set_hl(0, "JoveCellRuleElapsed", { link = "Number", default = true })

---@class jove.ChromeBook
---@field front integer?   front-matter conceal extmark id
---@field headers integer[] header conceal extmark ids
---@field rules integer[]   per-cell rule extmark ids
---@field active integer?   active-cell highlight extmark id
---@field group integer?    autocmd group for this buffer
---@field unsub fun()?      execute.on_status unsubscribe
---@field attached boolean

---@type table<integer, jove.ChromeBook>
local bufs = {}

---Read config.ui defensively, filling in the documented defaults.
---@return { conceal_headers: boolean, active_cell: boolean, exec_counts: boolean, elapsed: boolean }
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
  }
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
      front = nil,
      headers = {},
      rules = {},
      active = nil,
      group = nil,
      unsub = nil,
      attached = false,
    }
    bufs[buf] = b
  end
  return b
end

---@param buf integer
---@param b jove.ChromeBook
local function clear_marks(buf, b)
  if b.front then
    pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, b.front)
    b.front = nil
  end
  for _, id in ipairs(b.headers) do
    pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, id)
  end
  b.headers = {}
  for _, id in ipairs(b.rules) do
    pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, id)
  end
  b.rules = {}
end

---First body line of a cell (header excluded for header'd cells).
---@param c jove.Cell
---@return integer
local function body_start(c)
  return c.header and (c.header + 1) or c.start_lnum
end

---Locate `# ---` front matter; returns first/last lnum (1-based) or nil.
---@param lines string[]
---@return integer?, integer?
local function find_front(lines)
  if #lines == 0 or not lines[1]:match("^# %-%-%-%s*$") then
    return nil, nil
  end
  for i = 2, #lines do
    if lines[i]:match("^# %-%-%-%s*$") then
      return 1, i
    end
  end
  return nil, nil
end

---Cell execution status ("queued"|"running"|"ok"|"error") or nil.
---@param buf integer
---@param hash string
---@return string?
local function cell_status(buf, hash)
  local st = state.peek(buf)
  local exec = st and st.exec
  return exec and exec.status and exec.status[hash] or nil
end

---Execution metadata for a cell hash from the cross-lane contract:
---state.get(buf).exec.meta[hash] = { count = <int|nil>, elapsed_ms = <number|nil> }.
---@param buf integer
---@param hash string
---@return table?
local function cell_meta(buf, hash)
  local st = state.peek(buf)
  local meta = st and st.exec and st.exec.meta
  return meta and meta[hash] or nil
end

---@param status string?
---@return string
local function status_glyph(status)
  if status == "running" then
    return "⠋"
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

---Width to span for a buffer's rules (its window width, else global columns).
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

---Build one rule's virt_text chunks.
---@param buf integer
---@param c jove.Cell
---@param cfg table
---@return table[] chunks
local function build_rule(buf, c, cfg)
  local status = cell_status(buf, c.hash)
  local chunks = {
    { status_glyph(status) .. " ", status_hl(status) },
  }
  if c.kind == "markdown" then
    chunks[#chunks + 1] = { "── markdown ", "JoveCellRule" }
  else
    chunks[#chunks + 1] = { "── ", "JoveCellRule" }
    local meta = cell_meta(buf, c.hash)
    if cfg.exec_counts and meta and type(meta.count) == "number" then
      chunks[#chunks + 1] = { ("In [%d] "):format(meta.count), "JoveCellRuleCount" }
    end
    if cfg.elapsed and meta and type(meta.elapsed_ms) == "number" then
      chunks[#chunks + 1] =
        { ("┄┄ %.1fs "):format(meta.elapsed_ms / 1000), "JoveCellRuleElapsed" }
    end
  end

  local used = 0
  for _, chunk in ipairs(chunks) do
    used = used + vim.fn.strdisplaywidth(chunk[1])
  end
  local fill = win_width(buf) - used
  if fill > 1 then
    chunks[#chunks + 1] = { string.rep("─", fill), "JoveCellRule" }
  end
  return chunks
end

---Line number of the window cursor currently showing `buf` (nil if hidden).
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

---Re-set the active-cell highlight extmark for the cursor's cell.
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

---Recompute front matter, header concealment, rules and active highlight.
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
  clear_marks(buf, b)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  if cfg.conceal_headers then
    local first, last = find_front(lines)
    if first and last then
      b.front = vim.api.nvim_buf_set_extmark(buf, M.ns, first - 1, 0, {
        end_row = last - 1,
        end_col = 0,
        conceal_lines = "",
      })
    end
  end

  local cells = cell.all(buf)
  for _, c in ipairs(cells) do
    if c.header and cfg.conceal_headers then
      b.headers[#b.headers + 1] =
        vim.api.nvim_buf_set_extmark(buf, M.ns, c.header - 1, 0, { conceal_lines = "" })
    end
  end

  for _, c in ipairs(cells) do
    local bs = body_start(c)
    if bs <= c.end_lnum then
      b.rules[#b.rules + 1] = vim.api.nvim_buf_set_extmark(buf, M.ns, bs - 1, 0, {
        virt_lines_above = true,
        virt_lines = { build_rule(buf, c, cfg) },
        hl_mode = "combine",
      })
    end
  end

  update_active(buf, b, cfg)

  -- conceal_lines is a no-op at conceallevel 0; enable it unless the user has
  -- chosen a non-default level of their own.
  if cfg.conceal_headers then
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      local ok, lvl = pcall(vim.api.nvim_get_option_value, "conceallevel", { win = win })
      if ok and lvl == 0 then
        pcall(vim.api.nvim_set_option_value, "conceallevel", 2, { win = win })
      end
    end
  end
end

---Cheap path for cursor moves: only re-set the active-cell highlight.
---@param buf integer
function M.refresh_active(buf)
  buf = norm_buf(buf)
  local b = bufs[buf]
  if not b or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  update_active(buf, b, ui_conf())
end

---Start rendering chrome for `buf`. Idempotent.
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

  local group = vim.api.nvim_create_augroup("jove_cell_chrome_" .. buf, { clear = true })
  b.group = group

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = group,
    buffer = buf,
    callback = function()
      M.refresh(buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter", "WinEnter" }, {
    group = group,
    buffer = buf,
    callback = function()
      M.refresh_active(buf)
    end,
  })

  -- Execution status changes recompute glyph/count/elapsed immediately.
  b.unsub = execute.on_status(buf, function()
    M.refresh(buf)
  end)

  M.refresh(buf)
end

---Stop rendering chrome for `buf` and drop its extmarks/autocmds.
---@param buf integer
function M.detach(buf)
  buf = norm_buf(buf)
  local b = bufs[buf]
  if not b then
    return
  end
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

-- Drop bookkeeping when a buffer goes away.
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

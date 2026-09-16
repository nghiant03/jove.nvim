-- Variable-inspector sidebar.
--
-- `:JoveVariables` toggles a right-hand split listing the running kernel's
-- user-namespace variables as `name  type  value`. The data comes from the
-- bridge's `variables` method (see lua/jove/bridge.lua + python
-- jove_bridge/session.py); this module is presentation + interaction only.
--
-- Auto-refresh (config.variables.auto_refresh) subscribes to the per-cell
-- status callback already exposed by lua/jove/execute.lua (M.on_status) and
-- re-queries once a cell reaches a terminal state.
local state = require("jove.state")

local M = {}

---@class jove.vars.Session
---@field win integer
---@field fbuf integer
---@field vars table[]
---@field unsupported string?
---@field unsub fun()?

---@type table<integer, jove.vars.Session>
local sessions = {}

---@param buf integer?
---@return integer
local function norm_buf(buf)
  if buf == nil or buf == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return buf
end

---@return {width: integer, auto_refresh: boolean}
local function config()
  local ok, jove = pcall(require, "jove")
  local c = ok and jove.config and jove.config.variables
  if type(c) ~= "table" then
    return { width = 32, auto_refresh = true }
  end
  return {
    width = type(c.width) == "number" and c.width or 32,
    auto_refresh = c.auto_refresh ~= false,
  }
end

---Truncate a string to at most `max` display cells, appending an ellipsis.
---@param s string
---@param max integer
---@return string
local function truncate(s, max)
  if max <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(s) <= max then
    return s
  end
  local i = #s
  while i > 0 and vim.fn.strdisplaywidth(s:sub(1, i)) + 1 > max do
    i = i - 1
  end
  return s:sub(1, i) .. "…"
end

---@param s string
---@param width integer
---@return string
local function pad(s, width)
  local n = width - vim.fn.strdisplaywidth(s)
  return s .. string.rep(" ", math.max(0, n))
end

---Collapse row-breaking whitespace so a value never spans multiple sidebar rows.
---@param s string
---@return string
local function flatten(s)
  local out = s:gsub("[%s]+", " ")
  return out
end

---Format variable records into sidebar lines.
---@param vars table[]  { {name, type, value, size}, ... }
---@param width integer  Target display width.
---@return string[]
function M.format(vars, width)
  width = math.max(16, width or 32)
  if type(vars) ~= "table" or #vars == 0 then
    return { "[no variables]" }
  end
  local name_w, type_w = 4, 4
  for _, v in ipairs(vars) do
    name_w = math.max(name_w, vim.fn.strdisplaywidth(tostring(v.name or "")))
    type_w = math.max(type_w, vim.fn.strdisplaywidth(tostring(v.type or "")))
  end
  name_w = math.min(name_w, math.max(6, math.floor(width * 0.4)))
  type_w = math.min(type_w, math.max(4, math.floor(width * 0.3)))
  local value_w = math.max(1, width - name_w - type_w - 4)
  local lines = {}
  for _, v in ipairs(vars) do
    local value = flatten(tostring(v.value or ""))
    lines[#lines + 1] = ("%s  %s  %s"):format(
      pad(truncate(tostring(v.name or ""), name_w), name_w),
      pad(truncate(tostring(v.type or ""), type_w), type_w),
      truncate(value, value_w)
    )
  end
  return lines
end

---@param buf integer
---@return jove.vars.Session?
local function get(buf)
  local s = sessions[buf]
  if s and vim.api.nvim_win_is_valid(s.win) then
    return s
  end
  return nil
end

---@param buf integer
local function render(buf)
  local s = get(buf)
  if not s or not vim.api.nvim_buf_is_valid(s.fbuf) then
    return
  end
  local lines
  if s.unsupported then
    lines = { ("[variables unsupported for %s]"):format(s.unsupported) }
  else
    local width = vim.api.nvim_win_is_valid(s.win) and vim.api.nvim_win_get_width(s.win) or 32
    lines = M.format(s.vars, width)
  end
  vim.api.nvim_buf_set_lines(s.fbuf, 0, -1, false, lines)
end

---@param buf integer
---@return boolean
function M.is_open(buf)
  return get(norm_buf(buf)) ~= nil
end

---Toggle the sidebar for `buf`.
---@param buf integer?
function M.toggle(buf)
  buf = norm_buf(buf)
  if get(buf) then
    M.close(buf)
  else
    M.open(buf)
  end
end

---Open (and populate) the sidebar. No-op when already open.
---@param buf integer?
---@return integer? win
function M.open(buf)
  buf = norm_buf(buf)
  if get(buf) then
    return sessions[buf].win
  end
  if not state.peek(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    vim.notify("[jove] variable inspector: not a notebook buffer", vim.log.levels.WARN)
    return nil
  end

  local c = config()
  local width = math.max(20, math.floor(c.width))
  local height = math.max(5, vim.o.lines - 2)
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[fbuf].buflisted = false
  vim.bo[fbuf].bufhidden = "wipe"
  vim.bo[fbuf].filetype = "jove-vars"

  local ok, win = pcall(vim.api.nvim_open_win, fbuf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = 0,
    col = math.max(0, vim.o.columns - width),
    style = "minimal",
    border = "single",
  })
  if not ok then
    pcall(vim.api.nvim_buf_delete, fbuf, { force = true })
    vim.notify("[jove] could not open variable inspector: " .. tostring(win), vim.log.levels.ERROR)
    return nil
  end

  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winfixwidth = true
  vim.wo[win].cursorline = true
  vim.wo[win].foldcolumn = "0"

  sessions[buf] = { win = win, fbuf = fbuf, vars = {}, unsupported = nil, unsub = nil }

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = fbuf, nowait = true, silent = true, desc = desc })
  end
  map("q", function()
    M.close(buf)
  end, "Jove: Close Variable Inspector")
  map("<Esc>", function()
    M.close(buf)
  end, "Jove: Close Variable Inspector")
  map("r", function()
    M.refresh(buf)
  end, "Jove: Refresh Variables")
  map("<CR>", function()
    M.inspect(buf)
  end, "Jove: Inspect Variable")

  -- Keep the session table from leaking when the scratch buffer goes away.
  -- Unsubscribe the status listener before clearing: the same listener is
  -- installed again on every reopen and would otherwise stack up, with each
  -- duplicate firing `M.refresh(buf)` on every status transition.
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = fbuf,
    once = true,
    callback = function()
      local s = sessions[buf]
      if s and s.unsub then
        pcall(s.unsub)
      end
      sessions[buf] = nil
    end,
  })

  if c.auto_refresh then
    local ok_x, execute = pcall(require, "jove.execute")
    if ok_x and type(execute.on_status) == "function" then
      sessions[buf].unsub = execute.on_status(buf, function(_, status)
        if status == "ok" or status == "error" then
          M.refresh(buf)
        end
      end)
    end
  end

  M.refresh(buf)
  return win
end

---Close the sidebar and drop its session + status subscription.
---@param buf integer?
function M.close(buf)
  buf = norm_buf(buf)
  local s = sessions[buf]
  if not s then
    return
  end
  sessions[buf] = nil
  if s.unsub then
    pcall(s.unsub)
  end
  if vim.api.nvim_win_is_valid(s.win) then
    pcall(vim.api.nvim_win_close, s.win, true)
  end
  if vim.api.nvim_buf_is_valid(s.fbuf) then
    pcall(vim.api.nvim_buf_delete, s.fbuf, { force = true })
  end
end

---Re-query the bridge and re-render (no-op when the sidebar is closed).
---@param buf integer?
function M.refresh(buf)
  buf = norm_buf(buf)
  local s = get(buf)
  if not s then
    return
  end
  M._variables(buf, function(result)
    if not get(buf) then
      return -- closed while the request was in flight
    end
    if type(result) ~= "table" then
      result = {}
    end
    s.unsupported = result.unsupported
    s.vars = type(result.variables) == "table" and result.variables or {}
    render(buf)
  end)
end

---Variable name under the cursor, or nil.
---@param buf integer
---@return string?
local function current_name(buf)
  local s = get(buf)
  if not s then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(s.win)[1]
  local v = s.vars[lnum]
  return v and v.name or nil
end

---Open a small float showing `text` (used for inspect details / fallback).
---@param text string
---@return integer? win
function M.show_float(text)
  local lines = vim.split(text, "\n", { plain = true })
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.bo[fbuf].bufhidden = "wipe"
  vim.bo[fbuf].buflisted = false
  local width = math.max(20, math.floor(vim.o.columns * 0.6))
  local height = math.max(3, math.min(#lines, math.floor(vim.o.lines * 0.6)))
  local win = vim.api.nvim_open_win(fbuf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    style = "minimal",
  })
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  vim.keymap.set(
    "n",
    "q",
    close,
    { buffer = fbuf, nowait = true, silent = true, desc = "Jove: Close Float" }
  )
  vim.keymap.set(
    "n",
    "<Esc>",
    close,
    { buffer = fbuf, nowait = true, silent = true, desc = "Jove: Close Float" }
  )
  return win
end

---Inspect the variable under the cursor (`<CR>`): ask the bridge, else use the
---cached repr.
---@param buf integer?
function M.inspect(buf)
  buf = norm_buf(buf)
  local s = get(buf)
  if not s then
    return
  end
  local name = current_name(buf)
  if not name then
    return
  end
  local cached
  for _, v in ipairs(s.vars) do
    if v.name == name then
      cached = v
      break
    end
  end

  local entry = state.peek(buf)
  local k = entry and entry.kernel
  if k and k.name and k.bridge and k.bridge:is_alive() then
    k.bridge:request(
      "inspect",
      { code = name, cursor_pos = #name, detail_level = 1 },
      function(result, err)
        local text
        if not err and type(result) == "table" and type(result.mime) == "table" then
          text = result.mime["text/plain"]
        end
        if type(text) ~= "string" or text == "" then
          text = cached and (cached.name .. " = " .. tostring(cached.value)) or nil
        end
        if text then
          M.show_float(text)
        else
          vim.notify("[jove] no details for " .. name, vim.log.levels.INFO)
        end
      end,
      { timeout_ms = 5000 }
    )
  elseif cached then
    M.show_float(cached.name .. " = " .. tostring(cached.value))
  end
end

-- Test seam: overridable so specs don't need a live bridge. Production reads
-- the orchestration helper in lua/jove/bridge.lua.
M._variables = function(buf, cb)
  require("jove.bridge").variables(buf, cb)
end

return M

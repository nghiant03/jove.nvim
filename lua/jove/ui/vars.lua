-- Variable-inspector data and formatting for the tabbed sidebar
-- (`jove.ui.sidebar` owns the window).

local ansi = require("jove.ansi")
local state = require("jove.state")

local M = {}

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

---@param s string
---@return string
local function flatten(s)
  local out = s:gsub("[%s]+", " ")
  return out
end

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

---Fetch the variable list through the bridge seam.
---@param buf integer
---@param cb fun(result: table?)
function M.fetch(buf, cb)
  M._variables(buf, cb)
end

---Apply ANSI highlight spans (byte offsets over the whole plain text) to the
---float buffer, line by line.
---@param fbuf integer
---@param lines string[]
---@param spans jove.AnsiSpan[]
local function apply_spans(fbuf, lines, spans)
  if #spans == 0 then
    return
  end
  local ns = vim.api.nvim_create_namespace("jove_vars_float")
  local starts = {}
  local off = 0
  for i, line in ipairs(lines) do
    starts[i] = off
    off = off + #line + 1
  end
  local li = 1
  for _, span in ipairs(spans) do
    local s, e, hl = span[1], span[2], span[3]
    while li < #lines and starts[li] + #lines[li] < s do
      li = li + 1
    end
    local lj = li
    while lj <= #lines and starts[lj] < e do
      local col_s = math.max(s - starts[lj], 0)
      local col_e = math.min(e - starts[lj], #lines[lj])
      if col_e > col_s then
        vim.api.nvim_buf_set_extmark(fbuf, ns, lj - 1, col_s, { end_col = col_e, hl_group = hl })
      end
      lj = lj + 1
    end
  end
end

---@param text string
---@return integer? win
function M.show_float(text)
  local plain, spans = ansi.parse(text)
  local lines = vim.split(plain, "\n", { plain = true })
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.bo[fbuf].bufhidden = "wipe"
  vim.bo[fbuf].buflisted = false
  local width = math.max(20, math.floor(vim.o.columns * 0.6))
  local height = math.max(3, math.min(#lines, math.floor(vim.o.lines * 0.6)))
  local win = require("jove.ui.win").open(fbuf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    style = "minimal",
  }, width)
  if not win then
    pcall(vim.api.nvim_buf_delete, fbuf, { force = true })
    return nil
  end
  apply_spans(fbuf, lines, spans)
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

---Show details for one variable in a float.
---@param buf integer
---@param name string
---@param cached table?  vars entry ({name, type, value, ...}) used as fallback text
function M.inspect_var(buf, name, cached)
  if name == "" then
    return
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

M._variables = function(buf, cb)
  require("jove.bridge").variables(buf, cb)
end

return M

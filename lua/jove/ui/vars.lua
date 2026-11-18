-- Variable-inspector data and formatting for the tabbed sidebar

local ansi = require("jove.ansi")
local kernel = require("jove.kernel")

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
  -- Wide characters can take two columns; trim whole characters to leave room for the ellipsis.
  local i = max - 1
  local prefix = vim.fn.strcharpart(s, 0, i, true)
  while i > 0 and vim.fn.strdisplaywidth(prefix) + 1 > max do
    i = i - 1
    prefix = vim.fn.strcharpart(s, 0, i, true)
  end
  return prefix .. "…"
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
---@return string[] lines, table[] spans, integer items_offset
function M.format(vars, width)
  width = math.max(16, width or 32)
  if type(vars) ~= "table" or #vars == 0 then
    local msg = "No variables in scope"
    return { msg }, { { 1, 0, #msg, "JoveSidebarMuted" } }, 1
  end
  local name_w, type_w = 4, 4
  for _, v in ipairs(vars) do
    name_w = math.max(name_w, vim.fn.strdisplaywidth(flatten(tostring(v.name or ""))))
    type_w = math.max(type_w, vim.fn.strdisplaywidth(flatten(tostring(v.type or ""))))
  end
  name_w = math.min(name_w, math.max(6, math.floor(width * 0.4)))
  type_w = math.min(type_w, math.max(4, math.floor(width * 0.3)))
  local value_w = math.max(1, width - name_w - type_w - 4)
  local header = ("%s  %s  %s"):format(pad("Name", name_w), pad("Type", type_w), "Value")
  local lines = { truncate(header, width) }
  local spans = { { 1, 0, #lines[1], "JoveSidebarMuted" } }
  for i, v in ipairs(vars) do
    local name = truncate(flatten(tostring(v.name or "")), name_w)
    local ty = truncate(flatten(tostring(v.type or "")), type_w)
    local value = truncate(flatten(tostring(v.value or "")), value_w)
    local name_col = pad(name, name_w) .. "  "
    lines[#lines + 1] = name_col .. pad(ty, type_w) .. "  " .. value
    local row = i + 1
    if #name > 0 then
      spans[#spans + 1] = { row, 0, #name, "JoveSidebarVarName" }
    end
    if #ty > 0 then
      spans[#spans + 1] = { row, #name_col, #name_col + #ty, "JoveSidebarVarType" }
    end
  end
  return lines, spans, 1
end

---@param buf integer
---@param cb fun(result: table?, err: string?)
function M.fetch(buf, cb)
  M._variables(buf, cb)
end

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
  local win_ui = require("jove.ui.win")
  local size = win_ui.mode("inspect") == "hsplit" and height or width
  local win = win_ui.open(fbuf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    style = "minimal",
  }, size, "inspect")
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
    { buffer = fbuf, nowait = true, silent = true, desc = "Jove: Close Variable Details" }
  )
  vim.keymap.set(
    "n",
    "<Esc>",
    close,
    { buffer = fbuf, nowait = true, silent = true, desc = "Jove: Close Variable Details" }
  )
  return win
end

---@param buf integer
---@param name string
---@param cached table?  vars entry ({name, type, value, ...}) used as fallback text
---@param is_current (fun(): boolean)?  Ignore replies after the requesting view closes.
function M.inspect_var(buf, name, cached, is_current)
  if name == "" then
    return
  end
  local k = kernel.running(buf)
  if k then
    local generation = k.generation
    k.bridge:request(
      "inspect",
      { code = name, cursor_pos = vim.fn.strchars(name), detail_level = 1 },
      function(result, err)
        if
          (is_current and not is_current())
          or kernel.running(buf) ~= k
          or k.generation ~= generation
        then
          return
        end
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
          vim.notify("[Jove] no details for " .. name, vim.log.levels.INFO)
        end
      end,
      { timeout_ms = 5000 }
    )
  elseif cached then
    M.show_float(cached.name .. " = " .. tostring(cached.value))
  end
end

M._variables = function(buf, cb)
  kernel.variables(buf, cb)
end

return M

-- ANSI escape sequence handling: stripping, carriage-return folding, and
-- mapping SGR styling to highlight spans for buffer rendering.

local M = {}

local CSI = "\27%[[0-?]*[ -/]*[@-~]"
local OSC_ST = "\27%].-\27\\"
local OSC_BEL = "\27%][^\7]*\7"

---Remove all ANSI escape sequences (CSI, OSC, lone ESC) and carriage returns.
---@param s any
---@return any
function M.strip(s)
  if type(s) ~= "string" then
    return s
  end
  return (s:gsub(OSC_ST, ""):gsub(OSC_BEL, ""):gsub(CSI, ""):gsub("\27", ""):gsub("\r", ""))
end

---Concatenate terminal-style text honoring carriage returns: "\r" restarts
---the current line, dropping everything since the last "\n" (Jupyter classic
---semantics, what tqdm-style progress bars rely on).
---@param existing string  text accumulated so far (may end mid-line)
---@param new string       incoming text
---@return string
function M.cr_concat(existing, new)
  if not new:find("\r", 1, true) then
    return existing .. new
  end
  local acc = existing
  for i, seg in ipairs(vim.split(new, "\r", { plain = true, trimempty = false })) do
    if i > 1 then
      local nl = acc:find("\n[^\n]*$")
      acc = nl and acc:sub(1, nl) or ""
    end
    acc = acc .. seg
  end
  return acc
end

---@class jove.AnsiAttrs
---@field fg string?           "#rrggbb"
---@field bg string?           "#rrggbb"
---@field bold boolean?
---@field italic boolean?
---@field underline boolean?
---@field strikethrough boolean?
---@field reverse boolean?

---@class jove.AnsiState
---@field attrs jove.AnsiAttrs  SGR attributes still in effect
---@field pending string        tail of an escape sequence split across inputs

---@alias jove.AnsiSpan { [1]: integer, [2]: integer, [3]: string }
-- Span of styled text: 0-indexed byte range [start, end) in the plain text,
-- plus the highlight group to apply.

-- xterm default palette for the 16 basic colors; `g:terminal_color_N` wins.
local BASIC16 = {
  "#000000",
  "#cd0000",
  "#00cd00",
  "#cdcd00",
  "#0000ee",
  "#cd00cd",
  "#00cdcd",
  "#e5e5e5",
  "#7f7f7f",
  "#ff0000",
  "#00ff00",
  "#ffff00",
  "#5c5cff",
  "#ff00ff",
  "#00ffff",
  "#ffffff",
}

local CUBE = { 0, 95, 135, 175, 215, 255 }

---@param n integer  0-15
---@return string
local function color16(n)
  local term = vim.g["terminal_color_" .. n]
  if type(term) == "string" and term:match("^#%x%x%x%x%x%x$") then
    return term
  end
  return BASIC16[n + 1]
end

---@param n integer  0-255
---@return string
local function color256(n)
  if n < 16 then
    return color16(n)
  end
  if n < 232 then
    local c = n - 16
    local r = CUBE[math.floor(c / 36) + 1]
    local g = CUBE[math.floor((c % 36) / 6) + 1]
    local b = CUBE[(c % 6) + 1]
    return string.format("#%02x%02x%02x", r, g, b)
  end
  local v = 8 + (n - 232) * 10
  return string.format("#%02x%02x%02x", v, v, v)
end

local hl_cache = {}
local hl_count = 0

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("jove_ansi", { clear = true }),
  callback = function()
    hl_cache = {}
  end,
})

---Resolve a set of SGR attributes to a (cached) highlight group.
---@param attrs jove.AnsiAttrs
---@return string
local function hl_for(attrs)
  local key = table.concat({
    attrs.fg or "-",
    attrs.bg or "-",
    attrs.bold and "b" or "",
    attrs.italic and "i" or "",
    attrs.underline and "u" or "",
    attrs.strikethrough and "s" or "",
    attrs.reverse and "r" or "",
  }, ",")
  local name = hl_cache[key]
  if not name then
    hl_count = hl_count + 1
    name = "JoveAnsi" .. hl_count
    vim.api.nvim_set_hl(0, name, {
      fg = attrs.fg,
      bg = attrs.bg,
      bold = attrs.bold or nil,
      italic = attrs.italic or nil,
      underline = attrs.underline or nil,
      strikethrough = attrs.strikethrough or nil,
      reverse = attrs.reverse or nil,
    })
    hl_cache[key] = name
  end
  return name
end

---Apply one SGR parameter list (e.g. "1;38;5;34") to the attribute set.
---@param attrs jove.AnsiAttrs
---@param params_str string
local function apply_sgr(attrs, params_str)
  local params = {}
  for p in (params_str:gsub(":", ";") .. ";"):gmatch("(.-);") do
    params[#params + 1] = tonumber(p) or 0
  end
  local i = 1
  while i <= #params do
    local p = params[i]
    if p == 0 then
      for k in pairs(attrs) do
        attrs[k] = nil
      end
    elseif p == 1 then
      attrs.bold = true
    elseif p == 3 then
      attrs.italic = true
    elseif p == 4 then
      attrs.underline = true
    elseif p == 7 then
      attrs.reverse = true
    elseif p == 9 then
      attrs.strikethrough = true
    elseif p == 22 then
      attrs.bold = nil
    elseif p == 23 then
      attrs.italic = nil
    elseif p == 24 then
      attrs.underline = nil
    elseif p == 27 then
      attrs.reverse = nil
    elseif p == 29 then
      attrs.strikethrough = nil
    elseif p == 39 then
      attrs.fg = nil
    elseif p == 49 then
      attrs.bg = nil
    elseif p >= 30 and p <= 37 then
      attrs.fg = color16(p - 30)
    elseif p >= 40 and p <= 47 then
      attrs.bg = color16(p - 40)
    elseif p >= 90 and p <= 97 then
      attrs.fg = color16(p - 90 + 8)
    elseif p >= 100 and p <= 107 then
      attrs.bg = color16(p - 100 + 8)
    elseif p == 38 or p == 48 then
      local target = p == 38 and "fg" or "bg"
      local mode = params[i + 1]
      if mode == 5 and params[i + 2] then
        attrs[target] = color256(params[i + 2])
        i = i + 2
      elseif mode == 2 and params[i + 4] then
        attrs[target] = string.format("#%02x%02x%02x", params[i + 2], params[i + 3], params[i + 4])
        i = i + 4
      end
    end
    i = i + 1
  end
end

---Parse terminal text: strip escape sequences and map SGR styling to
---highlight spans. Stateless by default; pass the returned state back in to
---continue a stream whose escape sequence or style spans several inputs.
---Non-SGR sequences (cursor movement, OSC, ...) are dropped like `strip`.
---@param text string
---@param state jove.AnsiState?
---@return string plain
---@return jove.AnsiSpan[] spans
---@return jove.AnsiState state
function M.parse(text, state)
  state = state or { attrs = {}, pending = "" }
  local input = (state.pending or "") .. text
  state.pending = ""
  local attrs = state.attrs

  local function has_style()
    return next(attrs) ~= nil
  end

  if not input:find("\27", 1, true) then
    if has_style() and #input > 0 then
      return input, { { 0, #input, hl_for(attrs) } }, state
    end
    return input, {}, state
  end

  local parts = {}
  local spans = {}
  local plain_len = 0
  local run_start = has_style() and 0 or nil
  local pos = 1
  local n = #input

  local function close_run()
    if run_start and plain_len > run_start then
      spans[#spans + 1] = { run_start, plain_len, hl_for(attrs) }
    end
    run_start = nil
  end

  while pos <= n do
    local esc = input:find("\27", pos, true)
    if not esc then
      local tail = input:sub(pos)
      parts[#parts + 1] = tail
      plain_len = plain_len + #tail
      break
    end
    if esc > pos then
      local seg = input:sub(pos, esc - 1)
      parts[#parts + 1] = seg
      plain_len = plain_len + #seg
    end
    if esc == n then
      state.pending = "\27"
      break
    end
    local c2 = input:sub(esc + 1, esc + 1)
    if c2 == "[" then
      local s, e, params, final = input:find("^%[([0-?]*[ -/]*)([@-~])", esc + 1)
      if s then
        if final == "m" then
          close_run()
          apply_sgr(attrs, params)
          if has_style() then
            run_start = plain_len
          end
        end
        pos = e + 1
      elseif input:sub(esc + 1):match("^%[[0-?]*[ -/]*$") then
        state.pending = input:sub(esc)
        break
      else
        pos = esc + 1
      end
    elseif c2 == "]" then
      local st = input:find("\27\\", esc + 2, true)
      local bel = input:find("\7", esc + 2, true)
      local stop
      if st and bel then
        stop = st < bel and st + 1 or bel
      elseif st then
        stop = st + 1
      elseif bel then
        stop = bel
      end
      if stop then
        pos = stop + 1
      else
        state.pending = input:sub(esc)
        break
      end
    elseif c2:match("[@-_]") then
      pos = esc + 2
    else
      pos = esc + 1
    end
  end

  close_run()
  return table.concat(parts), spans, state
end

return M

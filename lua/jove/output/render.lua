-- Pure output rendering pipeline: mime chunks -> decorated virt_lines.
-- No buffer state here; placement lives in jove.output.
local ansi = require("jove.ansi")

local M = {}

vim.api.nvim_set_hl(0, "JoveOutputBorder", { link = "DiagnosticInfo", default = true })
vim.api.nvim_set_hl(0, "JoveOutputHeader", { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "JoveOutputGuide", { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "JoveOutputGuideError", { link = "DiagnosticError", default = true })
vim.api.nvim_set_hl(0, "JoveOutput", { default = true })

local OPEN_CMD = ":Jove open-output"

---@param text string
---@param spans jove.AnsiSpan[]
---@param base_hl string?
---@return table[] lines  each line is a list of { text, hl_group? }
local function split_segments(text, spans, base_hl)
  local out = {}
  local offset = 0
  local span_idx = 1
  for _, l in ipairs(vim.split(text, "\n", { plain = true, trimempty = false })) do
    local line_end = offset + #l
    while span_idx <= #spans and spans[span_idx][2] <= offset do
      span_idx = span_idx + 1
    end
    local segs = {}
    local pos = 0
    local si = span_idx
    while si <= #spans do
      local s = spans[si]
      if s[1] >= line_end then
        break
      end
      local a = math.max(s[1] - offset, 0)
      local b = math.min(s[2] - offset, #l)
      if a > pos then
        segs[#segs + 1] = { l:sub(pos + 1, a), base_hl }
      end
      segs[#segs + 1] = { l:sub(a + 1, b), s[3] }
      pos = b
      si = si + 1
    end
    if pos < #l or #segs == 0 then
      segs[#segs + 1] = { l:sub(pos + 1), base_hl }
    end
    out[#out + 1] = segs
    offset = line_end + 1
  end
  return out
end

---@param chunks table[]
---@return table[] lines    virt_lines entries: { { text, hl_group? } }
---@return table[] images    { { chunk = <image chunk>, index = <int> } }
function M.build_lines(chunks)
  local lines, images = {}, {}
  local ansi_state
  for _, chunk in ipairs(chunks) do
    if chunk.kind == "image" then
      local index = #lines + 1
      images[#images + 1] = { chunk = chunk, index = index }
      local text = ("[image: %s]"):format(chunk.mime)
      if type(chunk.fallback) == "string" then
        text = chunk.fallback:match("^[^\n]*") or text
      end
      lines[#lines + 1] = { { text, "Comment" } }
    else
      local text, spans
      text, spans, ansi_state = ansi.parse(chunk.text or "", ansi_state)
      for i, segs in ipairs(split_segments(text, spans, chunk.hl_group)) do
        if i == 1 and chunk.continues and #lines > 0 then
          local last_line = lines[#lines]
          for _, seg in ipairs(segs) do
            local tail = last_line[#last_line]
            if tail and tail[2] == seg[2] then
              tail[1] = tail[1] .. seg[1]
            else
              last_line[#last_line + 1] = seg
            end
          end
        else
          lines[#lines + 1] = segs
        end
      end
    end
  end
  return lines, images
end

---@param lines table[]
---@param max integer
---@return table[] shown
function M.truncate(lines, max)
  if #lines <= max then
    return lines
  end
  local extra = #lines - max
  local shown = {}
  for i = 1, max do
    shown[i] = lines[i]
  end
  shown[#shown + 1] = { { ("… +%d lines · %s"):format(extra, OPEN_CMD), "Comment" } }
  return shown
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

---@param cfg string|table|nil
local function apply_output_hl(cfg)
  if cfg == nil then
    return
  end
  if type(cfg) == "string" then
    vim.api.nvim_set_hl(0, "JoveOutput", { link = cfg })
  else
    vim.api.nvim_set_hl(0, "JoveOutput", cfg)
  end
end

--- Wrap one content line with the guide rail and the output background.
--- `guide` is inserted verbatim when truthy; pass nil to omit the rail.
---@param line table[]  virt_line chunks: { text, hl_group? }
---@param guide string?
---@param guide_hl string
---@param out_cfg table
---@return table[] new_line
local function wrap_line(line, guide, guide_hl, out_cfg)
  local new_line = {}
  if guide then
    new_line[#new_line + 1] = { guide, guide_hl }
  end
  for _, chunk in ipairs(line) do
    local text, hl = chunk[1], chunk[2]
    if out_cfg.hl ~= nil and hl == nil then
      hl = "JoveOutput"
    end
    new_line[#new_line + 1] = { text, hl }
  end
  return new_line
end

--- Pad a line to the full width with the output background hl.
---@param new_line table[]
---@param width integer
local function pad_line(new_line, width)
  local used = 0
  for _, chunk in ipairs(new_line) do
    used = used + vim.fn.strdisplaywidth(chunk[1])
  end
  if width - used > 0 then
    new_line[#new_line + 1] = { string.rep(" ", width - used), "JoveOutput" }
  end
end

---@param ctx { count: integer? }
---@return string label
local function out_label(ctx)
  return type(ctx.count) == "number" and ("Out[%d] "):format(ctx.count) or "Out "
end

--- Flat style with a "└─ Out[n]" header line, no enclosing box.
---@param shown table[]
---@param ctx { count: integer?, has_error: boolean }
---@param out_cfg table
---@param width integer
---@param guide string?
---@param guide_hl string
---@return table[] decorated
local function decorate_inside_border(shown, ctx, out_cfg, width, guide, guide_hl)
  local decorated = {}
  if out_cfg.header ~= false then
    local label = out_label(ctx)
    local fill = width - vim.fn.strdisplaywidth("└─ ") - vim.fn.strdisplaywidth(label)
    local header = {
      { "└─ ", "JoveOutputHeader" },
      { label, "JoveOutputHeader" },
    }
    if fill > 0 then
      header[#header + 1] = { string.rep("─", fill), "JoveOutputHeader" }
    end
    decorated[#decorated + 1] = header
  end
  for _, line in ipairs(shown) do
    local new_line = wrap_line(line, guide, guide_hl, out_cfg)
    if out_cfg.hl ~= nil then
      pad_line(new_line, width)
    end
    decorated[#decorated + 1] = new_line
  end
  return decorated
end

---@param guide string?
---@return string?  nil when the guide is absent or empty
local function nonempty_guide(guide)
  return (guide and guide ~= "") and guide or nil
end

--- Flat style: guide rail only, no box.
---@param shown table[]
---@param out_cfg table
---@param guide string?
---@param guide_hl string
---@return table[] decorated
local function decorate_plain(shown, out_cfg, guide, guide_hl)
  guide = nonempty_guide(guide)
  local decorated = {}
  for _, line in ipairs(shown) do
    decorated[#decorated + 1] = wrap_line(line, guide, guide_hl, out_cfg)
  end
  return decorated
end

--- Boxed style: "┌─ Out[n] ─┐" top border and "└───┘" bottom border.
---@param shown table[]
---@param ctx { count: integer?, has_error: boolean }
---@param out_cfg table
---@param width integer
---@param guide string?
---@param guide_hl string
---@return table[] decorated
local function decorate_boxed(shown, ctx, out_cfg, width, guide, guide_hl)
  guide = nonempty_guide(guide)
  local decorated = {}

  local prefix = "┌─ "
  local label = out_label(ctx)
  local header_used = vim.fn.strdisplaywidth(prefix) + vim.fn.strdisplaywidth(label)
  local header_fill = math.max(0, width - header_used - 1)
  local top = {
    { prefix, "JoveOutputBorder" },
    { label, "JoveOutputBorder" },
  }
  if header_fill > 0 then
    top[#top + 1] = { string.rep("─", header_fill), "JoveOutputBorder" }
  end
  top[#top + 1] = { "┐", "JoveOutputBorder" }
  decorated[#decorated + 1] = top

  for _, line in ipairs(shown) do
    local new_line = wrap_line(line, guide, guide_hl, out_cfg)
    pad_line(new_line, width)
    decorated[#decorated + 1] = new_line
  end

  local bottom = { { "└", "JoveOutputBorder" } }
  if width > 2 then
    bottom[#bottom + 1] = { string.rep("─", width - 2), "JoveOutputBorder" }
  end
  bottom[#bottom + 1] = { "┘", "JoveOutputBorder" }
  decorated[#decorated + 1] = bottom

  return decorated
end

---@param buf integer
---@param shown table[]  truncated virt_lines from `truncate`
---@param ctx { count: integer?, has_error: boolean }
---@return table[] decorated
function M.decorate(buf, shown, ctx)
  if #shown == 0 then
    return shown
  end
  local cfg = require("jove").config
  local out_cfg = (cfg and cfg.output) or {}
  local width = win_width(buf)
  local guide = out_cfg.guide == nil and "▎ " or out_cfg.guide
  local guide_hl = ctx.has_error and "JoveOutputGuideError" or "JoveOutputGuide"
  apply_output_hl(out_cfg.hl)

  if out_cfg.inside_border then
    return decorate_inside_border(shown, ctx, out_cfg, width, guide, guide_hl)
  end
  if out_cfg.header == false then
    return decorate_plain(shown, out_cfg, guide, guide_hl)
  end
  return decorate_boxed(shown, ctx, out_cfg, width, guide, guide_hl)
end

return M

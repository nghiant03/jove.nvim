-- Normalize an output event's mime bundle.

local ansi = require("jove.ansi")

local M = {}

---@param html string
---@return string
local function html_to_text(html)
  local t = html:gsub("<%s*br%s*/?>", "\n"):gsub("<[^>]+>", "")
  t =
    t:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&amp;", "&")
  return (t:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param s string
---@return string
local function html_cell_text(s)
  s = s:gsub("<[bB][rR]%s*/?>", " ")
  s = s:gsub("<[^>]*>", "")
  s = s:gsub("&#[xX](%x+);", function(hex)
    return vim.fn.nr2char(tonumber(hex, 16))
  end)
  s = s:gsub("&#(%d+);", function(dec)
    return vim.fn.nr2char(tonumber(dec))
  end)
  s = s:gsub("&nbsp;", " ")
  s = s:gsub("&quot;", '"')
  s = s:gsub("&lt;", "<")
  s = s:gsub("&gt;", ">")
  s = s:gsub("&apos;", "'")
  s = s:gsub("&amp;", "&")
  s = s:gsub("%s+", " ")
  s = s:gsub("^ ", ""):gsub(" $", "")
  return s
end

---@param html string
---@return string
local function strip_style_blocks(html)
  local out = html
  while true do
    local lower = out:lower()
    local s = lower:find("<style[%s>]", 1) or lower:find("<style/", 1)
    if not s then
      return out
    end
    local e = lower:find("</style>", s, true)
    if not e then
      return out:sub(1, s - 1)
    end
    out = out:sub(1, s - 1) .. out:sub(e + 8)
  end
end

---@param html string
---@return string?
local function extract_table(html)
  local lower = html:lower()
  local s = lower:find("<table[%s>]", 1)
  if not s then
    return nil
  end
  local gt = lower:find(">", s, true)
  if not gt then
    return nil
  end
  local e = lower:find("</table>", gt, true)
  if not e then
    return nil
  end
  return html:sub(gt + 1, e - 1)
end

---@param row string
---@return {cells: string[], header: boolean}
local function parse_cells(row)
  local cells = {}
  local lower = row:lower()
  local pos = 1
  local is_header = false
  while true do
    local ths = lower:find("<th[%s/>]", pos)
    local tds = lower:find("<td[%s/>]", pos)
    local s, closer
    if ths and (not tds or ths < tds) then
      s, closer = ths, "</th"
      is_header = true
    elseif tds then
      s, closer = tds, "</td"
    else
      break
    end
    local gt = lower:find(">", s, true)
    if not gt then
      break
    end
    if lower:sub(s, gt):find("/", 1, true) then
      cells[#cells + 1] = ""
      pos = gt + 1
    else
      local ce = lower:find(closer, gt, true)
      if not ce then
        cells[#cells + 1] = html_cell_text(row:sub(gt + 1))
        break
      end
      cells[#cells + 1] = html_cell_text(row:sub(gt + 1, ce - 1))
      local cgt = lower:find(">", ce, true)
      pos = (cgt or ce) + 1
    end
  end
  return { cells = cells, header = is_header }
end

---@param tbl string
---@return {cells: string[], header: boolean}[]
local function parse_rows(tbl)
  local rows = {}
  local lower = tbl:lower()
  local pos = 1
  while true do
    local s = lower:find("<tr[%s/>]", pos)
    if not s then
      break
    end
    local gt = lower:find(">", s, true)
    if not gt then
      break
    end
    local close = lower:find("</tr>", gt, true)
    local row_html, next_pos
    if close then
      row_html = tbl:sub(gt + 1, close - 1)
      next_pos = close + 5
    else
      row_html = tbl:sub(gt + 1)
      next_pos = #tbl + 1
    end
    rows[#rows + 1] = parse_cells(row_html)
    pos = next_pos
  end
  return rows
end

---@param html string
---@return string[]?
function M.html_table(html)
  if type(html) ~= "string" then
    return nil
  end
  local cleaned = strip_style_blocks(html)
  local tbl = extract_table(cleaned)
  if not tbl then
    return nil
  end
  local rows = parse_rows(tbl)
  if #rows == 0 then
    return nil
  end

  local ncols = 0
  for _, r in ipairs(rows) do
    ncols = math.max(ncols, #r.cells)
  end
  if ncols == 0 then
    return nil
  end

  local widths = {}
  for c = 1, ncols do
    widths[c] = 0
  end
  for _, r in ipairs(rows) do
    for c = 1, ncols do
      local txt = r.cells[c] or ""
      widths[c] = math.max(widths[c], vim.fn.strdisplaywidth(txt))
    end
  end

  local function format_row(r)
    local parts = {}
    for c = 1, ncols do
      local txt = r.cells[c] or ""
      parts[c] = txt .. string.rep(" ", widths[c] - vim.fn.strdisplaywidth(txt))
    end
    return (table.concat(parts, "  "):gsub("%s+$", ""))
  end

  local lines = {}
  for _, r in ipairs(rows) do
    lines[#lines + 1] = format_row(r)
    if r.header then
      local sep = {}
      for c = 1, ncols do
        sep[c] = string.rep("─", widths[c])
      end
      lines[#lines + 1] = table.concat(sep, "  ")
    end
  end
  return lines
end

---@param mime string
---@return integer
local function sort_class(mime)
  if mime == "text/plain" then
    return 1
  elseif mime:sub(1, 5) == "text/" then
    return 2
  elseif mime == "application/json" then
    return 3
  elseif mime == "image/png" then
    return 4
  elseif mime == "image/jpeg" then
    return 5
  elseif mime == "image/svg+xml" then
    return 6
  end
  return 7
end

---@param params table
---@return table[]
function M.render_error(params)
  local chunks = {}
  if type(params.ename) == "string" then
    local first = params.ename
    if type(params.evalue) == "string" and params.evalue ~= "" then
      first = ("%s: %s"):format(params.ename, params.evalue)
    end
    chunks[#chunks + 1] =
      { kind = "text", mime = "text/plain", text = first, hl_group = "ErrorMsg" }
  end

  local lines = {}
  for _, line in ipairs(params.traceback or {}) do
    lines[#lines + 1] = ansi.strip(line)
  end
  if #lines == 0 and type(params.mime) == "table" then
    local raw = params.mime["text/plain"]
    if type(raw) == "string" then
      lines[#lines + 1] = ansi.strip(raw)
    end
  end
  if #lines > 0 then
    chunks[#chunks + 1] = {
      kind = "text",
      mime = "text/plain",
      text = table.concat(lines, "\n"),
      hl_group = "ErrorMsg",
    }
  end
  if #chunks == 0 then
    chunks[1] = {
      kind = "note",
      mime = "text/plain",
      text = "[error with no details]",
      hl_group = "ErrorMsg",
    }
  end
  return chunks
end

---@param params table?  `output` event params
---@return table[] chunks
function M.render(params)
  params = params or {}
  if params.kind == "error" then
    return M.render_error(params)
  end

  local bundle = params.mime or {}
  local keys = {}
  for mime in pairs(bundle) do
    keys[#keys + 1] = mime
  end
  table.sort(keys, function(a, b)
    local ca, cb = sort_class(a), sort_class(b)
    if ca ~= cb then
      return ca < cb
    end
    return a < b
  end)

  local chunks = {}
  local has_image = type(bundle["image/png"]) == "string" or type(bundle["image/jpeg"]) == "string"
  local plain_fallback
  for _, mime in ipairs(keys) do
    local value = bundle[mime]
    local class = sort_class(mime)
    if type(value) ~= "string" then
      chunks[#chunks + 1] = {
        kind = "note",
        mime = mime,
        text = ("[%s: non-text payload]"):format(mime),
        hl_group = "Comment",
      }
    elseif mime == "text/html" then
      local table_lines = M.html_table(value)
      chunks[#chunks + 1] = {
        kind = "text",
        mime = mime,
        text = table_lines and table.concat(table_lines, "\n") or html_to_text(value),
      }
    elseif mime == "image/png" or mime == "image/jpeg" then
      chunks[#chunks + 1] = { kind = "image", mime = mime, data = value }
    elseif mime == "image/svg+xml" then
      chunks[#chunks + 1] = {
        kind = "note",
        mime = mime,
        text = "[svg image: no inline renderer]",
        hl_group = "Comment",
      }
    elseif class == 7 then
      chunks[#chunks + 1] = {
        kind = "note",
        mime = mime,
        text = ("[unsupported mime %s]"):format(mime),
        hl_group = "Comment",
      }
    elseif mime == "text/plain" and has_image then
      plain_fallback = value
    else
      chunks[#chunks + 1] = { kind = "text", mime = mime, text = value }
    end
  end
  if plain_fallback then
    for _, chunk in ipairs(chunks) do
      if chunk.kind == "image" then
        chunk.fallback = plain_fallback
        break
      end
    end
  end
  return chunks
end

return M

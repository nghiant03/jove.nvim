-- mime.lua: normalize an output event's mime bundle (see PROTOCOL.md `output`
-- params) into an ordered, renderable chunk list for lua/jove/output.lua.
--
-- A chunk is a plain table:
--   { kind = "text",  mime = <str>, text = <str>, hl_group = <str>? }
--   { kind = "note",  mime = <str>, text = <str>, hl_group = <str>? }  (fallbacks)
--   { kind = "image", mime = <str>, data = <base64 str> }              (decode deferred)
--
-- Ordering: text/plain first, then other text/* mimes, application/json, then
-- images (image/png, image/jpeg), then svg (text note), then everything else
-- as an "[unsupported mime <x>]" note.
local M = {}

-- ANSI CSI sequence: ESC [ <params 0-?> <intermediates " "/".."/"> <final @-~>.
local CSI = "\27%[[0-?]*[ -/]*[@-~]"
-- ANSI OSC sequences (e.g. window-title writes in tracebacks), terminated
-- either by BEL (\7) or by ST (ESC \).
local OSC_ST = "\27%].-\27\\"
local OSC_BEL = "\27%][^\7]*\7"

---Strip ANSI escape sequences (OSC incl. BEL/ST terminators, CSI, lone ESC,
---stray CR) from a string. Used for error tracebacks; plain streams are kept
---raw.
---@param s any
---@return any
function M.strip_ansi(s)
  if type(s) ~= "string" then
    return s
  end
  return (s:gsub(OSC_ST, ""):gsub(OSC_BEL, ""):gsub(CSI, ""):gsub("\27", ""):gsub("\r", ""))
end

---Naive text/html fallback: break on <br>, drop tags, decode a handful of
---entities. Good enough for a plain-text preview of simple HTML output.
---@param html string
---@return string
local function html_to_text(html)
  local t = html:gsub("<%s*br%s*/?>", "\n"):gsub("<[^>]+>", "")
  t =
    t:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&amp;", "&")
  return (t:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- -------------------------------------------------------------------------
-- Phase C: HTML table -> aligned plain-text renderer.
--
-- pandas' `DataFrame.style` (and plain `df.to_html()`) emit a full HTML
-- document with an injected <style> block; the naive tag-stripper in
-- html_to_text() turns that into an unreadable wall of CSS. The parser below
-- pulls out the first <table>, reads its <tr>/<th>/<td> cells, and renders
-- them as fixed-width columns so the output stays readable inline.
-- -------------------------------------------------------------------------

-- Maximum number of table body rows rendered inline before an ellipsis row.
local HTML_TABLE_MAX_ROWS = 20

---Collapse an HTML fragment to a single cell string: <br> -> space, drop
---tags, decode entities, squeeze whitespace.
---@param s string
---@return string
local function html_cell_text(s)
  s = s:gsub("<[bB][rR]%s*/?>", " ")
  s = s:gsub("<[^>]*>", "")
  -- Numeric references first, then named ones; &amp; last so "&amp;lt;"
  -- decodes to "&lt;" rather than "<".
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

---Remove every <style>...</style> block (pandas injects the whole table CSS
---there). Unterminated style blocks are dropped to end-of-string.
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

---Body of the first <table> (between the opening tag and </table>), or nil.
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

---Parse the <tr>/<th>/<td> cells of one row. Returns { cells, header }.
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
      -- Self-closing cell (<td/>): empty.
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

---Parse all <tr> rows of a table body.
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
      next_pos = close + 5 -- skip "</tr>"
    else
      row_html = tbl:sub(gt + 1)
      next_pos = #tbl + 1
    end
    rows[#rows + 1] = parse_cells(row_html)
    pos = next_pos
  end
  return rows
end

---Render the first HTML table in `html` as padded, aligned text lines.
---Returns nil when there is no parseable table (caller falls back to the
---naive html_to_text tag-stripper).
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

  -- Column widths by display width (CJK/emoji aware).
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
  local emitted = 0
  for _, r in ipairs(rows) do
    if emitted >= HTML_TABLE_MAX_ROWS then
      break
    end
    lines[#lines + 1] = format_row(r)
    emitted = emitted + 1
    if r.header then
      local sep = {}
      for c = 1, ncols do
        sep[c] = string.rep("─", widths[c])
      end
      lines[#lines + 1] = table.concat(sep, "  ")
    end
  end
  if #rows > HTML_TABLE_MAX_ROWS then
    lines[#lines + 1] = "..."
  end
  return lines
end

---Sort class of a mime within the render order (lower sorts first).
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

---Chunks for a `kind = "error"` event: `ename: evalue` first, then the
---ANSI-stripped traceback, all with an error highlight.
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
    lines[#lines + 1] = M.strip_ansi(line)
  end
  if #lines == 0 and type(params.mime) == "table" then
    local raw = params.mime["text/plain"]
    if type(raw) == "string" then
      lines[#lines + 1] = M.strip_ansi(raw)
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

---Normalize one output event's params into an ordered chunk list.
---@param params table?  `output` event params (PROTOCOL.md)
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
      -- Prefer the table renderer (pandas/DataFrame.style etc.); fall back
      -- to the naive tag-stripper for non-tabular HTML.
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
    else
      -- text/plain, other text/*, application/json: raw text (JSON is
      -- highlighted by treesitter in the float, not re-encoded here).
      chunks[#chunks + 1] = { kind = "text", mime = mime, text = value }
    end
  end
  return chunks
end

return M

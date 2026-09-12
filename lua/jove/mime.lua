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
      chunks[#chunks + 1] = { kind = "text", mime = mime, text = html_to_text(value) }
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

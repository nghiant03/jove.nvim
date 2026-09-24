-- Cell parser and cell model for buffers.

local state = require("jove.state")

local M = {}

---@class jove.Cell
---@field start_lnum integer  1-based, inclusive
---@field end_lnum integer    1-based, inclusive (last cell reaches buffer end)
---@field kind "code"|"markdown"
---@field hash string         identity key: sha256 hex of the normalized body, with a `#n` suffix for the n-th duplicate (see module comment)
---@field header integer?     lnum of the `# %%` header; nil for the synthetic pre-header cell

---@param line string
---@param comment string  comment leader of the buffer language ("#", "//", ...)
---@return boolean
local function is_header(line, comment)
  local prefix = comment .. " %%"
  return line == prefix or line:sub(1, #prefix + 1) == prefix .. " "
end

---@param line string
---@return "code"|"markdown"
local function header_kind(line)
  if line:find("[markdown]", 1, true) then
    return "markdown"
  end
  return "code"
end

---@param lines string[]  body lines (already sliced, header excluded)
---@return string
local function normalize_body(lines)
  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
  end
  return table.concat(lines, "\n")
end

---@param sha string
---@param n integer  1-based occurrence index of `sha`
---@return string
function M.dup_key(sha, n)
  return n == 1 and sha or (sha .. "#" .. n)
end

---@param lines string[]
---@param comment string  comment leader of the buffer language ("#", "//", ...)
---@return jove.Cell[]
local function parse_cells(lines, comment)
  local cells = {}
  local cur = nil -- cell currently being built
  local counts = {} -- sha -> occurrences so far (duplicate suffixing)

  ---@param end_lnum integer
  local function finish(end_lnum)
    local body_start = cur.header and cur.header + 1 or cur.start_lnum
    local body = {}
    for i = body_start, end_lnum do
      body[#body + 1] = lines[i]
    end
    local sha = vim.fn.sha256(normalize_body(body))
    counts[sha] = (counts[sha] or 0) + 1
    cells[#cells + 1] = {
      start_lnum = cur.start_lnum,
      end_lnum = end_lnum,
      kind = cur.kind,
      hash = M.dup_key(sha, counts[sha]),
      header = cur.header,
    }
  end

  for i, line in ipairs(lines) do
    if is_header(line, comment) then
      if cur then
        finish(i - 1)
      end
      cur = { start_lnum = i, kind = header_kind(line), header = i }
    elseif not cur then
      cur = { start_lnum = 1, kind = "code", header = nil }
    end
  end
  if cur then
    finish(#lines)
  end
  return cells
end

---@param source string|string[]?
---@return string
function M.hash_source(source)
  local lines
  if type(source) == "table" then
    lines = vim.split(table.concat(source, ""), "\n", { plain = true, trimempty = false })
  else
    lines = vim.split(tostring(source), "\n", { plain = true, trimempty = false })
  end
  return vim.fn.sha256(normalize_body(lines))
end

---@param buf integer
---@return jove.Cell[]
function M.all(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local entry = state.get(buf)
  local lang = require("jove.lang").get(entry.lang)
  local tick = vim.b[buf].changedtick
  local cache = entry.cells
  if cache and cache.tick == tick and cache.lang == lang.id then
    return cache.list
  end
  local list = parse_cells(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lang.comment)
  entry.cells = { list = list, tick = tick, lang = lang.id }
  return list
end

---@param cells jove.Cell[]
---@param lnum integer
---@return integer?
local function index_at(cells, lnum)
  local lo, hi = 1, #cells
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local c = cells[mid]
    if lnum < c.start_lnum then
      hi = mid - 1
    elseif lnum > c.end_lnum then
      lo = mid + 1
    else
      return mid
    end
  end
  return nil
end

---@param buf integer
---@param lnum integer  1-based
---@return jove.Cell?
function M.at(buf, lnum)
  local cells = M.all(buf)
  local idx = index_at(cells, lnum)
  return idx and cells[idx] or nil
end

---@param buf integer
---@param lnum integer
---@return integer?
function M.next(buf, lnum)
  local cells = M.all(buf)
  local idx = index_at(cells, lnum) or 0
  for i = idx + 1, #cells do
    if cells[i].header then
      return cells[i].start_lnum
    end
  end
  return nil
end

---@param buf integer
---@param lnum integer
---@return integer?
function M.prev(buf, lnum)
  local cells = M.all(buf)
  local idx = index_at(cells, lnum)
  if not idx then
    return nil
  end
  local c = cells[idx]
  if c.header and c.start_lnum < lnum then
    return c.start_lnum
  end
  for i = idx - 1, 1, -1 do
    if cells[i].header then
      return cells[i].start_lnum
    end
  end
  return nil
end

---@param buf integer
---@param lnum integer
---@return integer?, integer?
function M.range(buf, lnum)
  local c = M.at(buf, lnum)
  if not c then
    return nil, nil
  end
  return c.start_lnum, c.end_lnum
end

---@param kind "i"|"a"
---@param count integer?  Defaults to vim.v.count (1 when unset).
function M.textobj(kind, count)
  if count == nil then
    count = vim.v.count > 1 and vim.v.count or 1
  end
  local buf = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local c = M.at(buf, lnum)
  if not c then
    return
  end

  local cells = M.all(buf)
  local idx = index_at(cells, lnum) --[[@as integer]]
  local end_lnum = cells[math.min(idx + count - 1, #cells)].end_lnum
  local start_lnum = (kind == "i" and c.header) and c.header + 1 or c.start_lnum
  if start_lnum > end_lnum then
    return
  end

  if vim.api.nvim_get_mode().mode:match("^[vV\22]") then
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes(
        ("<Esc>%dGV%dG"):format(start_lnum, end_lnum),
        true,
        false,
        true
      ),
      "m",
      false
    )
  else
    vim.api.nvim_win_set_cursor(0, { start_lnum, 0 })
    vim.cmd(("normal! V%dG"):format(end_lnum))
  end
end

return M

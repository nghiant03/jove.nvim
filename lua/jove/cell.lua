-- cell.lua: single-pass cell parser + per-buffer cached cell model for
-- py:percent buffers.
--
-- A cell is a block of lines opened by a jupytext `# %%` header line (either
-- exactly `# %%` or `# %% ...`, e.g. `# %% [markdown]`). Lines before the
-- first header belong to a synthetic first cell starting at line 1; the last cell extends
-- to the end of the buffer. Synthetic cells have no `header` line and kind
-- "code".
--
-- Cell identity: `hash` is the sha256 hex digest (vim.fn.sha256) of the
-- normalized cell body. Normalization: the header line is excluded; each body
-- line has its trailing whitespace stripped; trailing empty lines are dropped;
-- the rest is joined with "\n". Jupytext's py:percent round-trip loses
-- jupytext cell ids, so persist.lua matches cells to outputs by content hash.
--
-- Cache: the parsed list is stored per buffer in state.get(buf).cells =
--   { list = <cell list>, tick = <vim.b[buf].changedtick at parse time> }
-- and validated in O(1) by comparing changedtick -- any buffer edit bumps
-- changedtick and forces a re-parse on next access. No autocmds needed.
local state = require("jove.state")

local M = {}

---@class jove.Cell
---@field start_lnum integer  1-based, inclusive
---@field end_lnum integer    1-based, inclusive (last cell reaches buffer end)
---@field kind "code"|"markdown"
---@field hash string         sha256 hex of the normalized body (identity key, see module comment)
---@field header integer?     lnum of the `# %%` header; nil for the synthetic pre-header cell

---@param line string
---@return boolean
local function is_header(line)
  -- `# %%` exactly, or `# %% ` with a tag/body after it (e.g. `# %% [markdown]`).
  -- Plain prefix check: a pattern like "^# %% " would match only one `%`
  -- (percent-space is itself an escape sequence in Lua patterns).
  return line == "# %%" or line:sub(1, 5) == "# %% "
end

---@param line string
---@return "code"|"markdown"
local function header_kind(line)
  if line:find("[markdown]", 1, true) then
    return "markdown"
  end
  return "code"
end

---Normalize a cell body: strip trailing whitespace per line, drop trailing
---empty lines, join the rest with "\n".
---@param lines string[]  body lines (already sliced, header excluded)
---@return string
local function normalize_body(lines)
  for i = 1, #lines do
    lines[i] = lines[i]:gsub("%s+$", "")
  end
  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
  end
  return table.concat(lines, "\n")
end

---Single pass over the buffer lines producing the cell list.
---@param lines string[]
---@return jove.Cell[]
local function parse_cells(lines)
  local cells = {}
  local cur = nil -- cell currently being built

  ---@param end_lnum integer
  local function finish(end_lnum)
    local body_start = cur.header and cur.header + 1 or cur.start_lnum
    local body = {}
    for i = body_start, end_lnum do
      body[#body + 1] = lines[i]
    end
    cells[#cells + 1] = {
      start_lnum = cur.start_lnum,
      end_lnum = end_lnum,
      kind = cur.kind,
      hash = vim.fn.sha256(normalize_body(body)),
      header = cur.header,
    }
  end

  for i, line in ipairs(lines) do
    if is_header(line) then
      if cur then
        finish(i - 1)
      end
      cur = { start_lnum = i, kind = header_kind(line), header = i }
    elseif not cur then
      -- Content before the first header: synthetic first cell from line 1.
      cur = { start_lnum = 1, kind = "code", header = nil }
    end
  end
  if cur then
    finish(#lines)
  end
  return cells
end

---Content hash for a cell source taken from .ipynb JSON (string or list of
---lines), using the same normalize+sha256 logic as parsing. Public because
---persist.lua matches .ipynb JSON cells to session outputs by hash: when
---jupytext round-trips the source verbatim, this hash equals the `hash` the
---buffer's parsed cells carry (and the bridge cell keys execute.lua sends).
---@param source string|string[]?
---@return string
function M.hash_source(source)
  local lines
  if type(source) == "table" then
    lines = {}
    for _, l in ipairs(source) do
      lines[#lines + 1] = type(l) == "string" and l or tostring(l)
    end
  else
    lines = vim.split(tostring(source), "\n", { plain = true, trimempty = false })
  end
  return vim.fn.sha256(normalize_body(lines))
end

---All cells for a buffer, from cache or freshly parsed.
---The returned list is the cached table; treat it as read-only.
---@param buf integer
---@return jove.Cell[]
function M.all(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local entry = state.get(buf)
  local tick = vim.b[buf].changedtick
  local cache = entry.cells
  if cache and cache.tick == tick then
    return cache.list
  end
  local list = parse_cells(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  entry.cells = { list = list, tick = tick }
  return list
end

---Binary-search the index of the cell containing `lnum`.
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

---Cell containing `lnum`. Lines before the first header map to the synthetic
---first cell; nil only when `lnum` is outside the buffer.
---@param buf integer
---@param lnum integer  1-based
---@return jove.Cell?
function M.at(buf, lnum)
  local cells = M.all(buf)
  local idx = index_at(cells, lnum)
  return idx and cells[idx] or nil
end

---Header lnum of the first cell starting after `lnum`; nil at/after the last
---header.
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

---Header lnum of the previous cell relative to `lnum`: strictly below a cell's
---header that cell's own header; on a header (or in the synthetic pre-header
---cell) the header of the cell before it; nil when there is none.
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

---Inclusive, 1-based line range of the cell containing `lnum`; nil outside the buffer.
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

---Apply the built-in `ic`/`ac` cell text-object around the cursor.
---kind "i" selects the cell body (the `# %%` header line excluded); "a" the
---whole cell including the header. Selection is linewise. In operator-pending
---mode the pending operator applies to the selection once the mapping function
---returns; in visual mode the active selection is replaced by the cell range.
---With count N > 1 the selection extends through N-1 following cells (for "i"
---the intermediate headers are kept, since the selection must be contiguous).
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
    return -- empty body (header-only cell): leave the selection untouched
  end

  if vim.api.nvim_get_mode().mode:match("^[vV\22]") then
    -- Visual mode: leave the active selection, then reselect linewise over
    -- [start, end]. Keys are queued (no "x" flag) so they run right after the
    -- mapping function returns.
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
    -- Operator-pending: select linewise; the pending operator applies to the
    -- selection once this mapping function returns.
    vim.api.nvim_win_set_cursor(0, { start_lnum, 0 })
    vim.cmd(("normal! V%dG"):format(end_lnum))
  end
end

return M

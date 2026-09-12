-- output.lua: per-cell output store + extmark render engine (Phase 5).
--
-- Store shape (the `outputs` slot reserved in lua/jove/state.lua):
--   state.get(buf).outputs = {
--     [cell_hash] = {
--       chunks = <chunk list from mime.lua, accumulated across events>,
--       raw    = <list of raw output event params>,
--       hidden = <bool, per-cell fold state>,
--       extmark_id = <int?, virt_lines extmark below the cell end>,
--     },
--   }
--
-- Rendering: one extmark per cell at the cell's end_lnum with `virt_lines`
-- (so it moves with the text and dies with the buffer). Lines are truncated to
-- `config.output.max_lines` with an "open in float" trailer. Cell identity is
-- re-verified on every push/render so edits that change a cell's hash never
-- make outputs drift into a different cell.
local state = require("jove.state")
local cell = require("jove.cell")
local mime = require("jove.mime")
local image = require("jove.ui.image")

local M = {}

M.ns = vim.api.nvim_create_namespace("jove-output")

-- Wired by plugin/jove.lua as :JoveOpenOutput; used in the truncation trailer.
local OPEN_CMD = ":JoveOpenOutput"

---Run `fn` now, or on the next scheduler turn when inside a fast event, so
---push/clear are safe to call straight from bridge event context.
---@param fn fun()
local function safe(fn)
  if vim.in_fast_event() then
    vim.schedule(fn)
  else
    fn()
  end
end

---Find the cell with `hash` in `buf` (nil when the hash no longer exists).
---@param buf integer
---@param hash string
---@return jove.Cell?
local function find_cell(buf, hash)
  for _, c in ipairs(cell.all(buf)) do
    if c.hash == hash then
      return c
    end
  end
  return nil
end

---Get (creating on demand) the store entry for a cell hash.
---@param st jove.BufferState
---@param cell_hash string
---@return table entry, table store
local function get_entry(st, cell_hash)
  local store = st.outputs or {}
  local entry = store[cell_hash]
  if not entry then
    entry = { chunks = {}, raw = {}, hidden = false, extmark_id = nil }
    store[cell_hash] = entry
  end
  st.outputs = store
  return entry, store
end

---Render chunks to virt_lines. Image chunks render as a placeholder text
---line; their index within `lines` is returned alongside for the image layer.
---@param chunks table[]
---@return table[] lines    virt_lines entries: { { text, hl_group? } }
---@return table[] images    { { chunk = <image chunk>, index = <int> } }
local function build_lines(chunks)
  local lines, images = {}, {}
  for _, chunk in ipairs(chunks) do
    if chunk.kind == "image" then
      local index = #lines + 1
      images[#images + 1] = { chunk = chunk, index = index }
      -- The placeholder doubles as the anchor line: a successful snacks
      -- placement covers it, a failed one (API drift) still shows the text.
      lines[#lines + 1] = { { ("[image: %s]"):format(chunk.mime), "Comment" } }
    else
      for _, l in ipairs(vim.split(chunk.text or "", "\n", { plain = true, trimempty = false })) do
        lines[#lines + 1] = { { l, chunk.hl_group } }
      end
    end
  end
  return lines, images
end

---Truncate `lines` to `max` with a trailer pointing at the float.
---@param lines table[]
---@param max integer
---@return table[] shown
local function truncate(lines, max)
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

---(Re)render one cell's extmark. Skips silently when the hash is unknown to
---the current buffer contents (edited away) or the cell is toggled hidden.
---@param buf integer
---@param cell_hash string
local function render_cell(buf, cell_hash)
  local st = state.peek(buf)
  local entry = st and st.outputs and st.outputs[cell_hash]
  if not entry then
    return
  end

  -- Drop the previous rendering first so re-renders never duplicate.
  image.clear(buf, cell_hash)
  if entry.extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, entry.extmark_id)
    entry.extmark_id = nil
  end

  -- Invalidation guard: if the cell was edited (hash gone) we keep the stored
  -- output but do not render it anywhere.
  local c = find_cell(buf, cell_hash)
  if not c or entry.hidden or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end

  local lines, images = build_lines(entry.chunks)
  local cfg = require("jove").config
  local max = math.max(1, (cfg.output and cfg.output.max_lines) or 50)
  local shown = truncate(lines, max)

  entry.extmark_id = vim.api.nvim_buf_set_extmark(buf, M.ns, c.end_lnum - 1, 0, {
    virt_lines = shown,
    virt_lines_above = false,
  })

  -- Real image placement (no-op without snacks.image; placeholder stays then).
  if #images > 0 then
    local visible = {}
    for _, e in ipairs(images) do
      if e.index <= max then
        visible[#visible + 1] = e
      end
    end
    if #visible > 0 then
      pcall(image.render, buf, cell_hash, visible, { base_row = c.end_lnum })
    end
  end
end

---Append one output event to a cell's store and re-render it incrementally.
---Silent no-op when the buffer is not jove-managed (no state entry) or wiped.
---@param buf integer
---@param cell_hash string
---@param params table  `output` event params (PROTOCOL.md)
function M.push(buf, cell_hash, params)
  safe(function()
    buf = (buf == 0 or buf == nil) and vim.api.nvim_get_current_buf() or buf
    if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local st = state.peek(buf)
    if not st then
      return -- not a jove-managed buffer
    end
    local entry = get_entry(st, cell_hash)
    -- A session event means the cell actually ran: any disk provenance ends
    -- here (persist.merge_into may now rewrite this cell's outputs).
    entry.from_disk = nil
    entry.raw[#entry.raw + 1] = params
    vim.list_extend(entry.chunks, mime.render(params))
    render_cell(buf, cell_hash)
  end)
end

---Drop one cell's store + extmark, or the whole buffer's outputs.
---@param buf integer
---@param cell_hash string?
function M.clear(buf, cell_hash)
  safe(function()
    buf = (buf == 0 or buf == nil) and vim.api.nvim_get_current_buf() or buf
    local st = state.peek(buf)
    if not st or not st.outputs then
      return
    end
    if cell_hash then
      local entry = st.outputs[cell_hash]
      if entry then
        if entry.extmark_id then
          pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, entry.extmark_id)
        end
        image.clear(buf, cell_hash)
        st.outputs[cell_hash] = nil
      end
    else
      for hash, entry in pairs(st.outputs) do
        if entry.extmark_id then
          pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, entry.extmark_id)
        end
        image.clear(buf, hash)
      end
      st.outputs = nil
    end
  end)
end

---Per-cell fold: show/hide the rendered virt_lines of the cell at `lnum`.
---@param buf integer
---@param lnum integer?  Defaults to the cursor line of the current window.
function M.toggle(buf, lnum)
  safe(function()
    buf = (buf == 0 or buf == nil) and vim.api.nvim_get_current_buf() or buf
    if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local st = state.peek(buf)
    if not st or not st.outputs then
      return
    end
    lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
    local c = cell.at(buf, lnum)
    if not c or not st.outputs[c.hash] then
      return
    end
    local entry = st.outputs[c.hash]
    entry.hidden = not entry.hidden
    render_cell(buf, c.hash) -- hidden renders as "no extmark"
  end)
end

---Scrollable float with the cell's full (untruncated) outputs. `q`/`<Esc>`
---close; treesitter-highlighted when the jove buffer's filetype has a parser.
---@param buf integer
---@param lnum integer?  Defaults to the cursor line of the current window.
---@return integer? win
function M.open_float(buf, lnum)
  buf = (buf == 0 or buf == nil) and vim.api.nvim_get_current_buf() or buf
  local st = state.peek(buf)
  if not st or not st.outputs or not vim.api.nvim_buf_is_loaded(buf) then
    return nil
  end
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local c = cell.at(buf, lnum)
  if not c then
    return nil
  end
  local entry = st.outputs[c.hash]
  if not entry or #entry.chunks == 0 then
    return nil
  end

  local lines, images = build_lines(entry.chunks) -- untruncated
  local plain = {}
  for i, line in ipairs(lines) do
    plain[i] = line[1][1]
  end

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, plain)
  vim.bo[fbuf].buflisted = false
  vim.bo[fbuf].bufhidden = "wipe"
  for i, line in ipairs(lines) do
    if line[1][2] then
      vim.api.nvim_buf_set_extmark(fbuf, M.ns, i - 1, 0, { line_hl_group = line[1][2] })
    end
  end

  -- Treesitter highlighting when the source filetype maps to a parser.
  local ft = vim.bo[buf].filetype
  if ft ~= "" then
    vim.bo[fbuf].filetype = ft
    pcall(function()
      local lang = vim.treesitter.language.get_lang(ft)
      if lang then
        vim.treesitter.start(fbuf, lang)
      end
    end)
  end

  local width = math.max(20, math.floor(vim.o.columns * 0.8))
  local height = math.max(5, math.floor(vim.o.lines * 0.8))
  local win = vim.api.nvim_open_win(fbuf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
  })
  vim.wo[win].wrap = false
  vim.wo[win].scrolloff = 2

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set("n", "q", close, { buffer = fbuf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = fbuf, nowait = true, silent = true })

  if #images > 0 then
    pcall(image.render, fbuf, c.hash, images, { base_row = 0 })
  end
  return win
end

---Bulk attach stored outputs keyed by cell hash (Phase III persistence).
---@param buf integer
---@param outputs_by_hash table<string, table[]>  hash → list of output event params
function M.import(buf, outputs_by_hash)
  safe(function()
    buf = (buf == 0 or buf == nil) and vim.api.nvim_get_current_buf() or buf
    if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local st = state.peek(buf)
    if not st then
      return
    end
    for hash, events in pairs(outputs_by_hash or {}) do
      local entry = get_entry(st, hash)
      -- Provenance: entries created here hold DISK content transiting the
      -- store (persist.import), not session results — persist.merge_into
      -- must not rewrite them or null their execution_count.
      entry.from_disk = true
      for _, params in ipairs(events or {}) do
        entry.raw[#entry.raw + 1] = params
        vim.list_extend(entry.chunks, mime.render(params))
      end
      render_cell(buf, hash)
    end
  end)
end

return M

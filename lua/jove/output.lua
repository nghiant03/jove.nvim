-- Per-cell output storage and extmark rendering.
--
-- Store shape (the `outputs` slot reserved in lua/jove/state.lua):
--   state.get(buf).outputs = {
--     [cell_hash] = {
--       chunks = <chunk list from mime.lua, accumulated across events>,
--       raw    = <list of raw output event params>,
--       hidden = <bool, per-cell fold state>,
--       extmark_id = <int?, virt_lines extmark below the cell end>,
--       bytes  = <int, approximate payload bytes accumulated>,
--       truncated = <bool, true once config.output.max_bytes was hit>,
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

-- Highlight priority only; chrome uses a left-gravity bottom-border mark
-- so it sorts before the right-gravity outside output at the same position.
local RENDER_PRIORITY = 200

-- Highlight groups (default links; users can override before setup()).
-- `JoveCellBorder` (chrome.lua) surrounds the code body; `JoveOutputBorder`
-- is the distinct group for the Output block's frame, so the two can be
-- themed independently and never visually merge.
vim.api.nvim_set_hl(0, "JoveOutputBorder", { link = "DiagnosticInfo", default = true })
vim.api.nvim_set_hl(0, "JoveOutputHeader", { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "JoveOutputGuide", { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "JoveOutputGuideError", { link = "DiagnosticError", default = true })
vim.api.nvim_set_hl(0, "JoveOutput", { default = true })

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

---Mark the buffer modified: outputs and execution counts are notebook
---content, so a session change means there is unsaved notebook state even
---when the buffer text is untouched. This drives :q warnings and lets :w
---reach BufWriteCmd (which merges outputs into the .ipynb).
---@param buf integer
function M.mark_dirty(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    local st = state.peek(buf)
    if st then
      st.content_rev = (st.content_rev or 0) + 1
    end
    vim.bo[buf].modified = true
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
    entry =
      { chunks = {}, raw = {}, hidden = false, extmark_id = nil, bytes = 0, truncated = false }
    store[cell_hash] = entry
  end
  st.outputs = store
  return entry, store
end

---Append rendered chunks to an entry, bounding memory and re-render cost:
---
--- * stream events coalesce into the previous stream text chunk (same
---   mime/highlight), so a stream arriving in many small events stays one
---   growing chunk — terminal/Jupyter semantics — instead of an
---   ever-lengthening chunk list; error/result/note chunks never merge, so
---   event boundaries with distinct styling survive;
--- * once the accumulated payload exceeds `config.output.max_bytes` the tail
---   is dropped and a marker is appended (displayed inline and persisted with
---   the cell's outputs, so the saved notebook records the truncation).
---@param entry table
---@param params table       raw output event (kept in entry.raw for persist)
---@param new_chunks table[] mime.render(params)
local function append_output(entry, params, new_chunks)
  if entry.truncated then
    return
  end
  local cfg = require("jove").config
  local max_bytes = math.max(1024, (cfg and cfg.output and cfg.output.max_bytes) or 1048576)
  -- Account for retained raw data too, including unsupported MIME bundles
  -- and zero-length events (whose tables still consume memory).
  local size = #vim.json.encode(params)
  entry.bytes = (entry.bytes or 0) + size
  if entry.bytes > max_bytes then
    entry.truncated = true
    local text = ("… output truncated: jove output.max_bytes (%d) reached …"):format(max_bytes)
    entry.chunks[#entry.chunks + 1] =
      { kind = "note", mime = "text/plain", text = text, hl_group = "Comment" }
    -- Persist the marker as a stderr stream so the .ipynb shows the tail was
    -- dropped rather than silently losing it.
    entry.raw[#entry.raw + 1] =
      { kind = "stream", name = "stderr", mime = { ["text/plain"] = text } }
    return
  end
  local previous = entry.raw[#entry.raw]
  local can_merge = params.kind == "stream"
    and previous
    and previous.kind == "stream"
    and (previous.name or "stdout") == (params.name or "stdout")
  entry.raw[#entry.raw + 1] = params
  for _, chunk in ipairs(new_chunks) do
    local last = entry.chunks[#entry.chunks]
    if
      can_merge
      and last
      and last.kind == "text"
      and chunk.kind == "text"
      and last.mime == chunk.mime
      and last.hl_group == chunk.hl_group
    then
      if #last.text + #chunk.text <= 4096 then
        last.text = last.text .. chunk.text
      else
        -- Keep concatenation work bounded without inserting a visual newline
        -- at an internal storage-block boundary.
        chunk.continues = true
        entry.chunks[#entry.chunks + 1] = chunk
      end
    else
      entry.chunks[#entry.chunks + 1] = chunk
    end
  end
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
      for i, l in ipairs(vim.split(chunk.text or "", "\n", { plain = true, trimempty = false })) do
        if i == 1 and chunk.continues and #lines > 0 then
          local last = lines[#lines][1]
          last[1] = last[1] .. l
        else
          lines[#lines + 1] = { { l, chunk.hl_group } }
        end
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

---Width to span for a buffer's output rules (its window width, else columns).
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

---Apply `cfg.output.hl` to the `JoveOutput` highlight group.
--- string → `{ link = hl }`; table → passed straight to nvim_set_hl;
--- nil → no-op (default group at module load is respected).
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

---Decorate truncated inline output lines for the outside-border (default)
---layout: a self-contained `┌─ Out[n] ──┐ │ … │ └───┘` box rendered below the
---code cell border, top frame at row `c.end_lnum - 1` virt_lines_above =
---false so it sits visually below the cell's bottom `╰──╯` corner. The frame
---uses `JoveOutputBorder` (distinct from `JoveCellBorder`) so the two boxes
---stay visually independent while sharing the same horizontal row.
---`header = false` skips the frame entirely and falls back to the legacy
---content-with-rail layout for users who want minimal chrome.
---@param buf integer
---@param shown table[]  truncated virt_lines from `truncate`
---@param ctx { count: integer?, has_error: boolean }
---@return table[] decorated
local function decorate(buf, shown, ctx)
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
    local decorated = {}
    if out_cfg.header ~= false then
      local label = type(ctx.count) == "number" and ("Out[%d] "):format(ctx.count) or "Out "
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
      if out_cfg.hl ~= nil then
        local used = 0
        for _, chunk in ipairs(new_line) do
          used = used + vim.fn.strdisplaywidth(chunk[1])
        end
        if width - used > 0 then
          new_line[#new_line + 1] = { string.rep(" ", width - used), "JoveOutput" }
        end
      end
      decorated[#decorated + 1] = new_line
    end
    return decorated
  end

  -- Outside-border (box) layout. `header = false` opts out of the frame
  -- altogether and falls back to plain content + guide rail.
  if out_cfg.header == false then
    local decorated = {}
    for _, line in ipairs(shown) do
      local new_line = {}
      if guide and guide ~= "" then
        new_line[#new_line + 1] = { guide, guide_hl }
      end
      for _, chunk in ipairs(line) do
        local text, hl = chunk[1], chunk[2]
        if out_cfg.hl ~= nil and hl == nil then
          hl = "JoveOutput"
        end
        new_line[#new_line + 1] = { text, hl }
      end
      decorated[#decorated + 1] = new_line
    end
    return decorated
  end

  local decorated = {}

  local prefix = "┌─ "
  local label = type(ctx.count) == "number" and ("Out[%d] "):format(ctx.count) or "Out "
  local header_used = vim.fn.strdisplaywidth(prefix) + vim.fn.strdisplaywidth(label)
  local header_fill = math.max(0, width - header_used - 1) -- reserve 1 col for ┐
  local top = {
    { prefix, "JoveOutputBorder" },
    { label, "JoveOutputBorder" },
  }
  if header_fill > 0 then
    top[#top + 1] = { string.rep("─", header_fill), "JoveOutputBorder" }
  end
  top[#top + 1] = { "┐", "JoveOutputBorder" }
  decorated[#decorated + 1] = top

  -- Pad to the window width even without a background highlight so the
  -- right rail aligns with the frame corners.
  for _, line in ipairs(shown) do
    local new_line = {}
    new_line[#new_line + 1] = { "│", "JoveOutputBorder" }
    if guide and guide ~= "" then
      new_line[#new_line + 1] = { guide, guide_hl }
    end
    for _, chunk in ipairs(line) do
      local text, hl = chunk[1], chunk[2]
      if out_cfg.hl ~= nil and hl == nil then
        hl = "JoveOutput"
      end
      new_line[#new_line + 1] = { text, hl }
    end
    local used = 1 -- from the left rail
    for _, chunk in ipairs(new_line) do
      used = used + vim.fn.strdisplaywidth(chunk[1])
    end
    if width - used - 1 > 0 then -- reserve 1 col for the right rail
      new_line[#new_line + 1] = { string.rep(" ", width - used - 1), "JoveOutput" }
    end
    new_line[#new_line + 1] = { "│", "JoveOutputBorder" }
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
  local out_cfg = (cfg and cfg.output) or {}
  local max = math.max(1, out_cfg.max_lines or 50)
  local shown = truncate(lines, max)

  local has_error = false
  for _, line in ipairs(lines) do
    for _, chunk in ipairs(line) do
      if chunk[2] == "ErrorMsg" then
        has_error = true
        break
      end
    end
    if has_error then
      break
    end
  end
  local meta = require("jove.execute").meta(buf, cell_hash)
  local decorated = decorate(buf, shown, {
    count = meta and meta.count or nil,
    has_error = has_error,
  })
  -- A header line shifts every content line (and thus any image placeholder)
  -- down by one: keep the image layer's base_row offsets in sync.
  local header_offset = (#shown > 0 and out_cfg.header ~= false) and 1 or 0

  entry.extmark_id = vim.api.nvim_buf_set_extmark(buf, M.ns, c.end_lnum - 1, 0, {
    virt_lines = decorated,
    virt_lines_above = false,
    right_gravity = not out_cfg.inside_border,
    priority = (not out_cfg.inside_border) and RENDER_PRIORITY or nil,
  })

  -- Real image placement (no-op without snacks.image; placeholder stays then).
  if #images > 0 then
    local visible = {}
    for _, e in ipairs(images) do
      if e.index <= max then
        visible[#visible + 1] = { chunk = e.chunk, index = e.index + header_offset }
      end
    end
    if #visible > 0 then
      pcall(image.render, buf, cell_hash, visible, { base_row = c.end_lnum })
    end
  end
end

---Public wrapper: re-render one cell's inline output. Used when metadata (the
---execution count shown in the header) arrives after the output itself, e.g.
---print-only cells whose count comes with the execute reply.
---@param buf integer
---@param cell_hash string
function M.refresh_cell(buf, cell_hash)
  safe(function()
    buf = (buf == 0 or buf == nil) and vim.api.nvim_get_current_buf() or buf
    if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    render_cell(buf, cell_hash)
  end)
end

---Append one output event to a cell's store and re-render it incrementally.
---Silent no-op when the buffer is not jove-managed (no state entry) or wiped.
---@param buf integer
---@param cell_hash string
---@param params table  `output` event params (PROTOCOL.md)
function M.push(buf, cell_hash, params, opts)
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
    if entry.truncated then
      return
    end
    append_output(entry, params, mime.render(params))
    M.mark_dirty(buf)
    if opts and opts.defer then
      if not entry.render_pending then
        entry.render_pending = true
        vim.defer_fn(function()
          entry.render_pending = nil
          local current = state.peek(buf)
          if current and current.outputs and current.outputs[cell_hash] == entry then
            render_cell(buf, cell_hash)
          end
        end, 16)
      end
    else
      render_cell(buf, cell_hash)
    end
  end)
end

---Drop one cell's store + extmark, or the whole buffer's outputs.
---Clearing is a notebook-content change: the buffer is marked modified so the
---deletion reaches disk on save (persist.lua tombstones cleared cells).
---`opts.skip_dirty` is for internal resets where disk state replaces the
---session state (persist.import), i.e. not a user-visible change.
---@param buf integer
---@param cell_hash string?
---@param opts {skip_dirty: boolean?}?
function M.clear(buf, cell_hash, opts)
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
        if not (opts and opts.skip_dirty) then
          M.mark_dirty(buf)
        end
      end
    else
      for hash, entry in pairs(st.outputs) do
        if entry.extmark_id then
          pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, entry.extmark_id)
        end
        image.clear(buf, hash)
      end
      st.outputs = nil
      if not (opts and opts.skip_dirty) then
        M.mark_dirty(buf)
      end
    end
  end)
end

---Clear outputs of the cell under the cursor (no-op outside cells).
---@param buf integer
function M.clear_at_cursor(buf)
  local c = require("jove.cell").at(buf, vim.fn.line("."))
  if c then
    M.clear(buf, c.hash)
  end
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
  vim.keymap.set(
    "n",
    "q",
    close,
    { buffer = fbuf, nowait = true, silent = true, desc = "Jove: Close Output Float" }
  )
  vim.keymap.set(
    "n",
    "<Esc>",
    close,
    { buffer = fbuf, nowait = true, silent = true, desc = "Jove: Close Output Float" }
  )

  if #images > 0 then
    pcall(image.render, fbuf, c.hash, images, { base_row = 0 })
  end
  return win
end

---Attach stored outputs keyed by cell hash.
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
      -- Imported outputs are already on disk. Preserve their execution counts
      -- by excluding them from session-output merges.
      entry.from_disk = true
      for _, params in ipairs(events or {}) do
        append_output(entry, params, mime.render(params))
      end
      render_cell(buf, hash)
    end
  end)
end

return M

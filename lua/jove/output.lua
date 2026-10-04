-- Output storage and extmark placement; the pure rendering pipeline
-- (chunks -> decorated virt_lines) lives in jove.output.render.
local state = require("jove.state")
local cell = require("jove.cell")
local mime = require("jove.mime")
local ansi = require("jove.ansi")
local image = require("jove.ui.image")
local render = require("jove.output.render")

local M = {}

M.ns = vim.api.nvim_create_namespace("jove-output")

local RENDER_PRIORITY = 200

---@class jove.OutputEntry
---@field chunks table[]              rendered mime chunks (see mime.render)
---@field raw table[]                 raw output events (kept for persist)
---@field hidden boolean
---@field extmark_id integer?
---@field extmark_id_below integer?
---@field bytes integer               approximate payload size, for output.max_bytes
---@field truncated boolean           payload cap reached; further output is dropped
---@field render_pending boolean?     a deferred render_cell is scheduled
---@field from_disk boolean?          imported from the .ipynb rather than produced this session

---@param fn fun()
local function safe(fn)
  if vim.in_fast_event() then
    vim.schedule(fn)
  else
    fn()
  end
end

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

---@param st jove.BufferState
---@param cell_hash string
---@return jove.OutputEntry entry, table<string, jove.OutputEntry> store
local function get_entry(st, cell_hash)
  local store = st.outputs or {}
  local entry = store[cell_hash]
  if not entry then
    entry = {
      chunks = {},
      raw = {},
      hidden = false,
      extmark_id = nil,
      extmark_id_below = nil,
      bytes = 0,
      truncated = false,
    }
    store[cell_hash] = entry
  end
  st.outputs = store
  return entry, store
end

---@param entry table
---@param params table       raw output event (kept in entry.raw for persist)
---@param new_chunks table[] mime.render(params)
local function append_output(entry, params, new_chunks)
  if entry.truncated then
    return
  end
  local cfg = require("jove").config
  local max_bytes = math.max(1024, (cfg and cfg.output and cfg.output.max_bytes) or 1048576)
  local size = #vim.json.encode(params)
  entry.bytes = (entry.bytes or 0) + size
  if entry.bytes > max_bytes then
    entry.truncated = true
    local text = ("… output truncated: jove output.max_bytes (%d) reached …"):format(max_bytes)
    entry.chunks[#entry.chunks + 1] =
      { kind = "note", mime = "text/plain", text = text, hl_group = "Comment" }
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
        last.text = ansi.cr_concat(last.text, chunk.text)
      else
        chunk.continues = true
        chunk.text = ansi.cr_concat("", chunk.text)
        entry.chunks[#entry.chunks + 1] = chunk
      end
    else
      if chunk.kind == "text" then
        chunk.text = ansi.cr_concat("", chunk.text)
      end
      entry.chunks[#entry.chunks + 1] = chunk
    end
  end
end

---@param buf integer
---@param row integer  0-indexed
---@return integer
local function next_unconcealed_row(buf, row)
  local chrome_ns = vim.api.nvim_create_namespace("jove_cell_chrome")
  local line_count = vim.api.nvim_buf_line_count(buf)
  while row < line_count do
    local marks = vim.api.nvim_buf_get_extmarks(
      buf,
      chrome_ns,
      { row, 0 },
      { row, -1 },
      { details = true }
    )
    local concealed = false
    for _, m in ipairs(marks) do
      if m[4] and m[4].conceal_lines then
        concealed = true
        break
      end
    end
    if not concealed then
      return row
    end
    row = row + 1
  end
  return row
end

---@param buf integer
---@param c jove.Cell
---@param out_cfg table
---@return integer
local function image_col(buf, c, out_cfg)
  local anchor = vim.api.nvim_buf_get_lines(buf, c.end_lnum - 1, c.end_lnum, false)[1]
  if anchor and anchor:find("%S") then
    return 0
  end
  local guide = out_cfg.guide == nil and "▎ " or out_cfg.guide
  if guide and guide ~= "" then
    return vim.fn.strdisplaywidth(guide)
  end
  return 0
end

--- Remove a cell's extmarks and inline images.
---@param buf integer
---@param cell_hash string
---@param entry jove.OutputEntry
local function clear_render(buf, cell_hash, entry)
  image.clear(buf, cell_hash)
  if entry.extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, entry.extmark_id)
    entry.extmark_id = nil
  end
  if entry.extmark_id_below then
    pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, entry.extmark_id_below)
    entry.extmark_id_below = nil
  end
end

---@param lines table[]
---@return boolean
local function has_error_line(lines)
  for _, line in ipairs(lines) do
    for _, chunk in ipairs(line) do
      if chunk[2] == "ErrorMsg" then
        return true
      end
    end
  end
  return false
end

--- Place image chunks inline; returns the first replaced line index (which
--- splits the output into above/below extmarks) and the set of decorated-line
--- indices the images replaced.
---@param buf integer
---@param c jove.Cell
---@param cell_hash string
---@param images table[]
---@param max integer
---@param header_offset integer
---@param out_cfg table
---@return integer? split_at
---@return table<integer, boolean> drop
local function place_images(buf, c, cell_hash, images, max, header_offset, out_cfg)
  local drop = {}
  if #images == 0 then
    return nil, drop
  end
  local visible = {}
  for _, e in ipairs(images) do
    if e.index <= max then
      visible[#visible + 1] = {
        chunk = e.chunk,
        index = e.index + header_offset,
        row = c.end_lnum,
        col = image_col(buf, c, out_cfg),
      }
    end
  end
  local split_at
  if #visible > 0 then
    local ok, placed_idx = pcall(image.render, buf, cell_hash, visible)
    if ok and placed_idx then
      for _, e in ipairs(visible) do
        if placed_idx[e.index] then
          drop[e.index] = true
          split_at = math.min(split_at or e.index, e.index)
        end
      end
    end
  end
  return split_at, drop
end

--- Split decorated lines around the first inline image.
---@param decorated table[]
---@param split_at integer?
---@param drop table<integer, boolean>
---@return table[] top
---@return table[]? bottom
local function split_around_images(decorated, split_at, drop)
  if not split_at then
    return decorated, nil
  end
  local top, bottom = {}, {}
  for i, line in ipairs(decorated) do
    if not drop[i] then
      if i < split_at then
        top[#top + 1] = line
      else
        bottom[#bottom + 1] = line
      end
    end
  end
  return top, bottom
end

---@param buf integer
---@param c jove.Cell
---@param entry jove.OutputEntry
---@param top table[]
---@param bottom table[]?
---@param out_cfg table
local function place_extmarks(buf, c, entry, top, bottom, out_cfg)
  if #top > 0 then
    entry.extmark_id = vim.api.nvim_buf_set_extmark(buf, M.ns, c.end_lnum - 1, 0, {
      virt_lines = top,
      virt_lines_above = false,
      right_gravity = not out_cfg.inside_border,
      priority = (not out_cfg.inside_border) and RENDER_PRIORITY or nil,
    })
  end
  if bottom and #bottom > 0 then
    entry.extmark_id_below =
      vim.api.nvim_buf_set_extmark(buf, M.ns, next_unconcealed_row(buf, c.end_lnum), 0, {
        virt_lines = bottom,
        virt_lines_above = true,
        right_gravity = false,
        priority = (not out_cfg.inside_border) and RENDER_PRIORITY or nil,
      })
  end
end

---@param buf integer
---@param cell_hash string
local function render_cell(buf, cell_hash)
  local st = state.peek(buf)
  local entry = st and st.outputs and st.outputs[cell_hash]
  if not entry then
    return
  end

  clear_render(buf, cell_hash, entry)
  local c = find_cell(buf, cell_hash)
  if not c or entry.hidden or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end

  local lines, images = render.build_lines(entry.chunks)
  local cfg = require("jove").config
  local out_cfg = (cfg and cfg.output) or {}
  local max = math.max(1, out_cfg.max_lines or 50)
  local shown = render.truncate(lines, max)
  local meta = require("jove.execute").meta(buf, cell_hash)
  local decorated = render.decorate(buf, shown, {
    count = meta and meta.count or nil,
    has_error = has_error_line(lines),
  })
  local header_offset = (#shown > 0 and out_cfg.header ~= false) and 1 or 0

  local split_at, drop = place_images(buf, c, cell_hash, images, max, header_offset, out_cfg)
  local top, bottom = split_around_images(decorated, split_at, drop)
  place_extmarks(buf, c, entry, top, bottom, out_cfg)
end

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

---@param buf integer
---@param cell_hash string
---@param params table  `output` event params
function M.push(buf, cell_hash, params, opts)
  safe(function()
    buf = (buf == 0 or buf == nil) and vim.api.nvim_get_current_buf() or buf
    if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local st = state.peek(buf)
    if not st then
      return
    end
    local entry = get_entry(st, cell_hash)
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
        clear_render(buf, cell_hash, entry)
        st.outputs[cell_hash] = nil
        if not (opts and opts.skip_dirty) then
          M.mark_dirty(buf)
        end
      end
    else
      for hash, entry in pairs(st.outputs) do
        clear_render(buf, hash, entry)
      end
      st.outputs = nil
      if not (opts and opts.skip_dirty) then
        M.mark_dirty(buf)
      end
    end
  end)
end

---@param buf integer
function M.clear_at_cursor(buf)
  local c = require("jove.cell").at(buf, vim.fn.line("."))
  if c then
    M.clear(buf, c.hash)
  end
end

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
    render_cell(buf, c.hash)
  end)
end

--- Build the scratch buffer holding plain output text with hl extmarks.
---@param lines table[]  virt_lines from render.build_lines
---@param ft string      filetype of the notebook buffer (for treesitter)
---@return integer fbuf
local function build_float_buf(lines, ft)
  local plain = {}
  for i, line in ipairs(lines) do
    local parts = {}
    for _, seg in ipairs(line) do
      parts[#parts + 1] = seg[1]
    end
    plain[i] = table.concat(parts)
  end

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, plain)
  vim.bo[fbuf].buflisted = false
  vim.bo[fbuf].bufhidden = "wipe"
  for i, line in ipairs(lines) do
    local col = 0
    for _, seg in ipairs(line) do
      if seg[2] and #seg[1] > 0 then
        vim.api.nvim_buf_set_extmark(fbuf, M.ns, i - 1, col, {
          end_col = col + #seg[1],
          hl_group = seg[2],
        })
      end
      col = col + #seg[1]
    end
  end

  if ft ~= "" then
    vim.bo[fbuf].filetype = ft
    pcall(function()
      local lang = vim.treesitter.language.get_lang(ft)
      if lang then
        vim.treesitter.start(fbuf, lang)
      end
    end)
  end
  return fbuf
end

---@param fbuf integer
---@return integer? win
local function open_float_win(fbuf)
  local width = math.max(20, math.floor(vim.o.columns * 0.8))
  local height = math.max(5, math.floor(vim.o.lines * 0.8))
  local win_ui = require("jove.ui.win")
  local size = win_ui.mode("output") == "hsplit" and math.floor(vim.o.lines * 0.4)
    or math.floor(vim.o.columns * 0.5)
  local win = win_ui.open(fbuf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
  }, size, "output")
  if not win then
    return nil
  end
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
    { buffer = fbuf, nowait = true, silent = true, desc = "Jove: Close Output Viewer" }
  )
  vim.keymap.set(
    "n",
    "<Esc>",
    close,
    { buffer = fbuf, nowait = true, silent = true, desc = "Jove: Close Output Viewer" }
  )
  return win
end

---@param buf integer
---@param lnum integer?
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

  local lines, images = render.build_lines(entry.chunks)
  local fbuf = build_float_buf(lines, vim.bo[buf].filetype)
  local win = open_float_win(fbuf)
  if not win then
    pcall(vim.api.nvim_buf_delete, fbuf, { force = true })
    return nil
  end

  if #images > 0 then
    pcall(image.render, fbuf, c.hash, images, { base_row = 0 })
  end
  return win
end

--- Latest text/html payload in an output entry, if any.
---@param entry jove.OutputEntry
---@return string?
local function find_html(entry)
  for i = #entry.raw, 1, -1 do
    local bundle = entry.raw[i].mime
    if type(bundle) == "table" and type(bundle["text/html"]) == "string" then
      return bundle["text/html"]
    end
  end
  return nil
end

--- Open the current cell's latest text/html output in an interactive
--- terminal-browser webview (requires terminal-browser + kitty graphics).
---@param buf integer
---@param lnum integer?
function M.open_webview(buf, lnum)
  buf = (buf == 0 or buf == nil) and vim.api.nvim_get_current_buf() or buf
  local st = state.peek(buf)
  if not st or not st.outputs or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local c = cell.at(buf, lnum)
  if not c then
    return
  end
  local entry = st.outputs[c.hash]
  if not entry then
    vim.notify("[Jove] no output in this cell", vim.log.levels.INFO)
    return
  end
  local html = find_html(entry)
  if not html then
    vim.notify("[Jove] no text/html output in this cell", vim.log.levels.INFO)
    return
  end
  local session, err = require("jove.webview").open_html(html)
  if not session then
    vim.notify(err or "[Jove] webview failed to open", vim.log.levels.WARN)
  end
end

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
      entry.from_disk = true
      for _, params in ipairs(events or {}) do
        append_output(entry, params, mime.render(params))
      end
      render_cell(buf, hash)
    end
  end)
end

return M

-- Output storage and extmark rendering.

local state = require("jove.state")
local cell = require("jove.cell")
local mime = require("jove.mime")
local image = require("jove.ui.image")

local M = {}

M.ns = vim.api.nvim_create_namespace("jove-output")

local RENDER_PRIORITY = 200

vim.api.nvim_set_hl(0, "JoveOutputBorder", { link = "DiagnosticInfo", default = true })
vim.api.nvim_set_hl(0, "JoveOutputHeader", { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "JoveOutputGuide", { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "JoveOutputGuideError", { link = "DiagnosticError", default = true })
vim.api.nvim_set_hl(0, "JoveOutput", { default = true })

local OPEN_CMD = ":JoveOpenOutput"

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
---@return table entry, table store
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
        last.text = last.text .. chunk.text
      else
        chunk.continues = true
        entry.chunks[#entry.chunks + 1] = chunk
      end
    else
      entry.chunks[#entry.chunks + 1] = chunk
    end
  end
end

---@param chunks table[]
---@return table[] lines    virt_lines entries: { { text, hl_group? } }
---@return table[] images    { { chunk = <image chunk>, index = <int> } }
local function build_lines(chunks)
  local lines, images = {}, {}
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
    local used = 0
    for _, chunk in ipairs(new_line) do
      used = used + vim.fn.strdisplaywidth(chunk[1])
    end
    if width - used > 0 then
      new_line[#new_line + 1] = { string.rep(" ", width - used), "JoveOutput" }
    end
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
  if entry.extmark_id_below then
    pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, entry.extmark_id_below)
    entry.extmark_id_below = nil
  end

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
  local header_offset = (#shown > 0 and out_cfg.header ~= false) and 1 or 0

  local split_at
  local drop = {}
  if #images > 0 then
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
  end

  local top, bottom = decorated, nil
  if split_at then
    top, bottom = {}, {}
    for i, line in ipairs(decorated) do
      if not drop[i] then
        if i < split_at then
          top[#top + 1] = line
        else
          bottom[#bottom + 1] = line
        end
      end
    end
  end

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
        if entry.extmark_id then
          pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, entry.extmark_id)
        end
        if entry.extmark_id_below then
          pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, entry.extmark_id_below)
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
        if entry.extmark_id_below then
          pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, entry.extmark_id_below)
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

  local lines, images = build_lines(entry.chunks)
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
  local win_ui = require("jove.ui.win")
  local size = win_ui.mode() == "hsplit" and math.floor(vim.o.lines * 0.4)
    or math.floor(vim.o.columns * 0.5)
  local win = win_ui.open(fbuf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
  }, size)
  if not win then
    pcall(vim.api.nvim_buf_delete, fbuf, { force = true })
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

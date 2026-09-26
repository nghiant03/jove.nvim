-- Combined sidebar pane

local state = require("jove.state")

local M = {}

local ns = vim.api.nvim_create_namespace("jove_sidebar")

vim.api.nvim_set_hl(0, "JoveSidebarTab", { link = "TabLine", default = true })
vim.api.nvim_set_hl(0, "JoveSidebarTabActive", { link = "TabLineSel", default = true })
vim.api.nvim_set_hl(0, "JoveSidebarTabKey", { link = "Special", default = true })
vim.api.nvim_set_hl(0, "JoveSidebarHeader", { link = "Title", default = true })
vim.api.nvim_set_hl(0, "JoveSidebarMuted", { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "JoveSidebarVarName", { link = "Identifier", default = true })
vim.api.nvim_set_hl(0, "JoveSidebarVarType", { link = "Type", default = true })
vim.api.nvim_set_hl(0, "JoveSidebarActive", { link = "DiagnosticOk", default = true })

---@class jove.sidebar.Tab
---@field id string
---@field key string
---@field name string

---@type jove.sidebar.Tab[]
M.tabs = {
  { id = "vars", key = "1", name = "Variables" },
  { id = "kernel", key = "2", name = "Kernel" },
  { id = "toc", key = "3", name = "TOC" },
}

local HEADER_LINES = 2

---@class jove.sidebar.Session
---@field win integer
---@field fbuf integer
---@field tab string
---@field vars table[]
---@field vars_unsupported string?
---@field kernel_specs jove.ui.Kernelspec[]?
---@field kernel_err string?
---@field kernel_requested boolean
---@field toc jove.TocEntry[]
---@field items_offset integer  Leading content lines that are not items.
---@field unsub fun()?

---@type table<integer, jove.sidebar.Session>
local sessions = {}
M._sessions = sessions

---@type table<integer, string>
local last_tab = {}

---@param cb fun(specs: jove.ui.Kernelspec[]?, err: string?)
M._kernelspecs = function(cb)
  require("jove.ui.panel").installed_kernelspecs(cb)
end

---@param buf integer?
---@return integer
local function norm_buf(buf)
  if buf == nil or buf == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return buf
end

---@return number
local function pane_share()
  local ok, jove = pcall(require, "jove")
  local c = ok and jove.config and jove.config.variables
  local size = type(c) == "table" and type(c.size) == "number" and c.size or 0.25
  return math.min(math.max(size, 0.05), 0.9)
end

---@return integer
local function pane_width()
  return math.max(20, math.floor(vim.o.columns * pane_share()))
end

---@return boolean
local function auto_refresh()
  local ok, jove = pcall(require, "jove")
  local c = ok and jove.config and jove.config.variables
  return type(c) ~= "table" or c.auto_refresh ~= false
end

---@param buf integer
---@return jove.sidebar.Session?
local function get(buf)
  local s = sessions[buf]
  if s and vim.api.nvim_win_is_valid(s.win) and vim.api.nvim_buf_is_valid(s.fbuf) then
    return s
  end
  return nil
end

---@param s jove.sidebar.Session
---@return string text, table[] spans  {start_col, end_col, hl_group} on line 0
local function build_tab_bar(s)
  local parts = {}
  local spans = {}
  local col = 0
  for i, t in ipairs(M.tabs) do
    if i > 1 then
      parts[#parts + 1] = " "
      col = col + 1
    end
    local text = (" %s %s "):format(t.key, t.name)
    local active = t.id == s.tab
    spans[#spans + 1] = { col, col + #text, active and "JoveSidebarTabActive" or "JoveSidebarTab" }
    if not active then
      spans[#spans + 1] = { col + 1, col + 1 + #t.key, "JoveSidebarTabKey" }
    end
    parts[#parts + 1] = text
    col = col + #text
  end
  return table.concat(parts), spans
end

---@param buf integer
---@param s jove.sidebar.Session
---@param width integer
---@return string[] lines, table[] spans, integer items_offset
local function content_lines(buf, s, width)
  if s.tab == "vars" then
    if s.vars_unsupported then
      local msg = ("Variable inspection is unavailable for %s kernels"):format(s.vars_unsupported)
      return { msg }, { { 1, 0, #msg, "JoveSidebarMuted" } }, 1
    end
    return require("jove.ui.vars").format(s.vars, width)
  end
  if s.tab == "kernel" then
    local lines, spans = require("jove.ui.panel").build_lines(buf, s.kernel_specs, s.kernel_err)
    return lines, spans, 0
  end
  if #s.toc == 0 then
    local msg = "No markdown headings"
    return { msg }, { { 1, 0, #msg, "JoveSidebarMuted" } }, 1
  end
  local lines, spans = {}, {}
  for i, h in ipairs(s.toc) do
    lines[#lines + 1] = string.rep("  ", math.max(0, h.level - 1)) .. h.title
    if h.level <= 1 then
      spans[#spans + 1] = { i, 0, #lines[i], "JoveSidebarHeader" }
    end
  end
  return lines, spans, 0
end

---@param buf integer
local function render(buf)
  local s = get(buf)
  if not s then
    return
  end
  local width = vim.api.nvim_win_get_width(s.win)
  local bar, spans = build_tab_bar(s)
  local rule = string.rep("─", math.max(1, width - 1))
  local body, body_spans, items_offset = content_lines(buf, s, width)
  local lines = { bar, rule }
  vim.list_extend(lines, body)
  s.items_offset = items_offset
  vim.bo[s.fbuf].modifiable = true
  vim.api.nvim_buf_set_lines(s.fbuf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(s.fbuf, ns, 0, -1)
  for _, span in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(s.fbuf, ns, 0, span[1], {
      end_col = span[2],
      hl_group = span[3],
    })
  end
  vim.api.nvim_buf_set_extmark(s.fbuf, ns, 1, 0, { end_col = #rule, hl_group = "JoveSidebarMuted" })
  for _, span in ipairs(body_spans) do
    vim.api.nvim_buf_set_extmark(s.fbuf, ns, span[1] + HEADER_LINES - 1, span[2], {
      end_col = span[3],
      hl_group = span[4],
    })
  end
  vim.bo[s.fbuf].modifiable = false
end

---@param buf integer
local function refresh_vars(buf)
  local s = sessions[buf]
  if not s then
    return
  end
  require("jove.ui.vars").fetch(buf, function(result)
    local sess = sessions[buf]
    if not sess then
      return
    end
    if type(result) ~= "table" then
      result = {}
    end
    sess.vars_unsupported = result.unsupported
    sess.vars = type(result.variables) == "table" and result.variables or {}
    if sess.tab == "vars" then
      render(buf)
    end
  end)
end

---@param buf integer
local function refresh_kernel(buf)
  local s = sessions[buf]
  if not s then
    return
  end
  if not s.kernel_requested then
    s.kernel_requested = true
    M._kernelspecs(function(specs, err)
      local sess = sessions[buf]
      if not sess then
        return
      end
      sess.kernel_specs = specs
      sess.kernel_err = err
      if sess.tab == "kernel" then
        render(buf)
      end
    end)
  end
  if s.tab == "kernel" then
    render(buf)
  end
end

---@param buf integer
local function refresh_toc(buf)
  local s = sessions[buf]
  if not s then
    return
  end
  if vim.api.nvim_buf_is_valid(buf) then
    s.toc = require("jove.toc").headings(buf)
  end
  if s.tab == "toc" then
    render(buf)
  end
end

---@param buf integer
---@param tab string
local function refresh_tab(buf, tab)
  if tab == "vars" then
    refresh_vars(buf)
  elseif tab == "kernel" then
    refresh_kernel(buf)
  else
    refresh_toc(buf)
  end
end

---@param buf integer?
---@return boolean
function M.is_open(buf)
  return get(norm_buf(buf)) ~= nil
end

---@param buf integer?
---@return string? tab
function M.current_tab(buf)
  local s = get(norm_buf(buf))
  return s and s.tab or nil
end

---@param buf integer?
---@param tab string?
function M.switch(buf, tab)
  buf = norm_buf(buf)
  local s = get(buf)
  if not s then
    return
  end
  s.tab = tab or "vars"
  render(buf)
  refresh_tab(buf, s.tab)
end

---@param buf integer?
---@param tab string?
function M.toggle(buf, tab)
  buf = norm_buf(buf)
  local s = get(buf)
  if s then
    if tab == nil or s.tab == tab then
      M.close(buf)
    else
      M.switch(buf, tab)
    end
    return
  end
  M.open(buf, tab)
end

---@param buf integer?
function M.close(buf)
  buf = norm_buf(buf)
  local s = sessions[buf]
  if not s then
    return
  end
  last_tab[buf] = s.tab
  sessions[buf] = nil
  if s.unsub then
    pcall(s.unsub)
  end
  if vim.api.nvim_win_is_valid(s.win) then
    pcall(vim.api.nvim_win_close, s.win, true)
  end
  if vim.api.nvim_buf_is_valid(s.fbuf) then
    pcall(vim.api.nvim_buf_delete, s.fbuf, { force = true })
  end
end

---@param buf integer?
function M.activate(buf)
  buf = norm_buf(buf)
  local s = get(buf)
  if not s then
    return
  end
  local idx = vim.api.nvim_win_get_cursor(s.win)[1] - HEADER_LINES - (s.items_offset or 0)
  if idx < 1 then
    return
  end
  if s.tab == "vars" then
    local v = s.vars[idx]
    if v then
      require("jove.ui.vars").inspect_var(buf, tostring(v.name or ""), v)
    end
  elseif s.tab == "toc" then
    local h = s.toc[idx]
    if h then
      require("jove.toc").jump(buf, h.lnum)
    end
  end
end

---@param buf integer?
function M.refresh(buf)
  buf = norm_buf(buf)
  local s = get(buf)
  if not s then
    return
  end
  refresh_tab(buf, s.tab)
end

---@param buf integer?
---@param tab string?
---@return integer? win
function M.open(buf, tab)
  buf = norm_buf(buf)
  tab = tab or last_tab[buf] or "vars"
  local existing = get(buf)
  if existing then
    M.switch(buf, tab)
    return existing.win
  end
  if sessions[buf] then
    M.close(buf)
  end
  if not state.peek(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    vim.notify("[Jove] not a notebook buffer, could not open sidebar", vim.log.levels.WARN)
    return nil
  end

  local win_mod = require("jove.ui.win")
  local width = pane_width()
  local height = math.max(5, vim.o.lines - 2)
  local size = win_mod.mode() == "hsplit" and math.max(5, math.floor(vim.o.lines * pane_share()))
    or width
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[fbuf].buftype = "nofile"
  vim.bo[fbuf].buflisted = false
  vim.bo[fbuf].bufhidden = "wipe"
  vim.bo[fbuf].swapfile = false
  vim.bo[fbuf].modifiable = false
  vim.bo[fbuf].filetype = "jove-sidebar"

  local win, err = win_mod.open(fbuf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = 0,
    col = math.max(0, vim.o.columns - width),
    style = "minimal",
    border = "single",
  }, size)
  if not win then
    pcall(vim.api.nvim_buf_delete, fbuf, { force = true })
    vim.notify("[Jove] could not open sidebar: " .. tostring(err), vim.log.levels.ERROR)
    return nil
  end

  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].list = false
  vim.wo[win].spell = false
  vim.wo[win].winfixwidth = true
  vim.wo[win].cursorline = true
  vim.wo[win].cursorlineopt = "line"

  sessions[buf] = {
    win = win,
    fbuf = fbuf,
    tab = tab,
    vars = {},
    vars_unsupported = nil,
    kernel_specs = nil,
    kernel_err = nil,
    kernel_requested = false,
    toc = {},
    items_offset = 0,
    unsub = nil,
  }

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = fbuf, nowait = true, silent = true, desc = desc })
  end
  map("q", function()
    M.close(buf)
  end, "Jove: Close Sidebar")
  map("<Esc>", function()
    M.close(buf)
  end, "Jove: Close Sidebar")
  for _, t in ipairs(M.tabs) do
    map(t.key, function()
      M.switch(buf, t.id)
    end, ("Jove: Sidebar %s Tab"):format(t.name))
  end
  map("r", function()
    M.refresh(buf)
  end, "Jove: Refresh Sidebar Tab")
  map("<CR>", function()
    M.activate(buf)
  end, "Jove: Sidebar Context Action")

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = fbuf,
    once = true,
    callback = function()
      local s = sessions[buf]
      if s then
        last_tab[buf] = s.tab
        if s.unsub then
          pcall(s.unsub)
        end
      end
      sessions[buf] = nil
    end,
  })

  if auto_refresh() then
    local ok_x, execute = pcall(require, "jove.execute")
    if ok_x and type(execute.on_status) == "function" then
      sessions[buf].unsub = execute.on_status(buf, function(_, status)
        if status == "ok" or status == "error" then
          refresh_vars(buf)
        end
      end)
    end
  end

  render(buf)
  refresh_tab(buf, tab)
  return win
end

return M

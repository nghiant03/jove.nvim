-- Embedded interactive webview via terminal-browser (https://github.com/zenbu-labs/terminal-browser).
--
-- terminal-browser is a real Chromium (Electron offscreen rendering) that draws
-- pixels into the terminal through the kitty graphics protocol. It supports
-- embedding: the host (us) prints kitty unicode placeholder cells, the browser
-- streams frames into them, and input is forwarded as JSON-lines over a unix
-- socket (PIXEL_EMBED). This module is the host: it owns a float full of
-- placeholder cells, a pipe server, and the browser child process.

local M = {}

local impl = {
  jobstart = vim.fn.jobstart,
  jobstop = vim.fn.jobstop,
  executable = vim.fn.executable,
}

M._impl = impl
M._Session = nil -- assigned after Session is declared (test seam)

--- Kitty unicode placeholder base char; each cell is
--- PLACEHOLDER .. row_diacritic .. col_diacritic with fg = image id (RGB).
local PLACEHOLDER = vim.fn.nr2char(0x10EEEE)

-- stylua: ignore
local DIACRITICS = vim.split("0305,030D,030E,0310,0312,033D,033E,033F,0346,034A,034B,034C,0350,0351,0352,0357,035B,0363,0364,0365,0366,0367,0368,0369,036A,036B,036C,036D,036E,036F,0483,0484,0485,0486,0487,0592,0593,0594,0595,0597,0598,0599,059C,059D,059E,059F,05A0,05A1,05A8,05A9,05AB,05AC,05AF,05C4,0610,0611,0612,0613,0614,0615,0616,0617,0657,0658,0659,065A,065B,065D,065E,06D6,06D7,06D8,06D9,06DA,06DB,06DC,06DF,06E0,06E1,06E2,06E4,06E7,06E8,06EB,06EC,0730,0732,0733,0735,0736,073A,073D,073F,0740,0741,0743,0745,0747,0749,074A,07EB,07EC,07ED,07EE,07EF,07F0,07F1,07F3,0816,0817,0818,0819,081B,081C,081D,081E,081F,0820,0821,0822,0823,0825,0826,0827,0829,082A,082B,082C,082D,0951,0953,0954,0F82,0F83,0F86,0F87,135D,135E,135F,17DD,193A,1A17,1A75,1A76,1A77,1A78,1A79,1A7A,1A7B,1A7C,1B6B,1B6D,1B6E,1B6F,1B70,1B71,1B72,1B73,1CD0,1CD1,1CD2,1CDA,1CDB,1CE0,1DC1,1DC3,1DC4,1DC5,1DC6,1DC7,1DC8,1DC9,1DCB,1DCC,1DD1,1DD2,1DD3,1DD4,1DD5,1DD6,1DD7,1DD8,1DD9,1DDA,1DDB,1DDC,1DDD,1DDE,1DDF,1DE0,1DE1,1DE2,1DE3,1DE4,1DE5,1DE6,1DFE,20D0,20D1,20D4,20D5,20D6,20D7,20DB,20DC,20E1,20E7,20E9,20F0,2CEF,2CF0,2CF1,2DE0,2DE1,2DE2,2DE3,2DE4,2DE5,2DE6,2DE7,2DE8,2DE9,2DEA,2DEB,2DEC,2DED,2DEE,2DEF,2DF0,2DF1,2DF2,2DF3,2DF4,2DF5,2DF6,2DF7,2DF8,2DF9,2DFA,2DFB,2DFC,2DFD,2DFE,2DFF,A66F,A67C,A67D,A6F0,A6F1,A8E0,A8E1,A8E2,A8E3,A8E4,A8E5,A8E6,A8E7,A8E8,A8E9,A8EA,A8EB,A8EC,A8ED,A8EE,A8EF,A8F0,A8F1,AAB0,AAB2,AAB3,AAB7,AAB8,AABE,AABF,AAC1,FE20,FE21,FE22,FE23,FE24,FE25,FE26,10A0F,10A38,1D185,1D186,1D187,1D188,1D189,1D1AA,1D1AB,1D1AC,1D1AD,1D242,1D243,1D244", ",")

---@type table<integer, string>
local dia_cache = {}
setmetatable(dia_cache, {
  __index = function(t, k)
    t[k] = vim.fn.nr2char(tonumber(DIACRITICS[k], 16))
    return t[k]
  end,
})

local MAX_CELLS = #DIACRITICS

--- Image id base; each session increments. Must fit in 24 bits (fg RGB).
local next_image_id = 0x6A0000

---@return integer
local function alloc_image_id()
  next_image_id = next_image_id + 1
  if next_image_id > 0x6AFFFF then
    next_image_id = 0x6A0001
  end
  return next_image_id
end

--- Cell size in pixels via TIOCGWINSZ (same trick snacks.image uses).
---@return integer, integer
function impl.cell_pixels()
  local ok, ffi = pcall(require, "ffi")
  if ok then
    local sysname = vim.uv.os_uname().sysname
    local TIOCGWINSZ = sysname == "Darwin" and 0x40087468 or 0x5413
    local ok2, w, h = pcall(function()
      ffi.cdef([[
        struct jove_winsize { unsigned short row, col, xpixel, ypixel; };
        int ioctl(int, int, ...);
      ]])
      local sz = ffi.new("struct jove_winsize")
      if ffi.C.ioctl(1, TIOCGWINSZ, sz) ~= 0 or sz.col == 0 or sz.row == 0 then
        return nil, nil
      end
      if sz.xpixel == 0 or sz.ypixel == 0 then
        return nil, nil
      end
      return math.floor(sz.xpixel / sz.col), math.floor(sz.ypixel / sz.row)
    end)
    if ok2 and w and h and w > 0 and h > 0 then
      return w, h
    end
  end
  return 10, 20
end

---@return boolean
function impl.terminal_supports_kitty()
  local ok, snacks = pcall(require, "snacks.image")
  if ok and type(snacks) == "table" and type(snacks.supports_terminal) == "function" then
    local ok2, supported = pcall(snacks.supports_terminal)
    if ok2 then
      return supported and true or false
    end
  end
  local term = (vim.env.TERM or "") .. " " .. (vim.env.TERM_PROGRAM or "")
  if term:lower():find("kitty") or term:lower():find("ghostty") or term:lower():find("wezterm") then
    return true
  end
  return vim.env.KITTY_WINDOW_ID ~= nil or vim.env.GHOSTTY_RESOURCES_DIR ~= nil
end

---@return string?
function impl.tty_name()
  local ok, link = pcall(vim.uv.fs_readlink, "/proc/self/fd/0")
  if ok and type(link) == "string" and link:match("^/dev/") then
    return link
  end
  return "/dev/tty"
end

---@return boolean
function M.available()
  local cfg = require("jove").config
  local wv = cfg and cfg.webview
  if not wv or wv.enabled == false then
    return false
  end
  if vim.uv.os_uname().sysname:find("Windows", 1, true) then
    return false
  end
  return impl.executable(wv.cmd or "terminal-browser") == 1 and impl.terminal_supports_kitty()
end

---@class jove.Webview
---@field buf integer?
---@field win integer?
---@field job integer?
---@field server any?       uv pipe server
---@field conn any?         accepted uv pipe client
---@field sock_path string?
---@field image_id integer
---@field grid { imageId: integer, cols: integer, rows: integer }?
---@field cell integer[]    { width_px, height_px }
---@field title string
---@field closed boolean
---@field interact boolean  key passthrough mode
---@field group integer?
---@field _rbuf string
---@field _stderr string
local Session = {}
Session.__index = Session
M._Session = Session

---@param msg table
function Session:send(msg)
  if self.conn and not self.conn:is_closing() then
    self.conn:write(vim.json.encode(msg) .. "\n")
  end
end

---@param kind string  "init" | "size"
---@return table
function Session:size_message(kind)
  local cols = vim.api.nvim_win_get_width(self.win)
  local rows = vim.api.nvim_win_get_height(self.win)
  return {
    type = kind,
    cols = cols,
    rows = rows,
    width = cols * self.cell[1],
    height = rows * self.cell[2],
    cell = { self.cell[1], self.cell[2] },
  }
end

--- Fill the float buffer with kitty placeholder cells for the current grid.
function Session:render_placeholders()
  local grid = self.grid
  if not grid or not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  local cols = math.min(grid.cols, vim.api.nvim_win_get_width(self.win), MAX_CELLS)
  local rows = math.min(grid.rows, vim.api.nvim_win_get_height(self.win), MAX_CELLS)
  local lines = {}
  for row = 1, rows do
    local parts = {}
    for col = 1, cols do
      parts[col] = PLACEHOLDER .. dia_cache[row] .. dia_cache[col]
    end
    lines[row] = table.concat(parts)
  end
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
  local hl = ("JoveWebview%x"):format(grid.imageId)
  vim.api.nvim_set_hl(0, hl, {
    fg = ("#%06x"):format(grid.imageId),
  })
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.wo[self.win].winhighlight = "Normal:"
      .. hl
      .. ",NormalFloat:"
      .. hl
      .. ",EndOfBuffer:"
      .. hl
  end
end

---@param msg table
function Session:handle(msg)
  if msg.type == "join" then
    local init = self:size_message("init")
    init.imageId = self.image_id
    init.transport = "inline"
    init.focused = true
    self:send(init)
  elseif msg.type == "placed" then
    self.grid = msg --[[@as any]]
    self:render_placeholders()
  elseif msg.type == "title" then
    self.title = type(msg.text) == "string" and msg.text or self.title
    self:update_winbar()
  end
end

function Session:update_winbar()
  if not self.win or not vim.api.nvim_win_is_valid(self.win) then
    return
  end
  local hint = self.interact and " INTERACT (<Esc> release) " or " i interact, q close "
  vim.wo[self.win].winbar = (" %s —%s"):format(self.title, hint)
end

--- Forward one named key to the browser.
---@param name string
---@param text string?
---@param mods { shift: boolean?, alt: boolean?, ctrl: boolean?, super: boolean? }?
function Session:send_key(name, text, mods)
  self:send({
    type = "key",
    key = name,
    kind = "press",
    mods = {
      shift = not not (mods and mods.shift),
      alt = not not (mods and mods.alt),
      ctrl = not not (mods and mods.ctrl),
      super = false,
    },
    text = text,
  })
end

---@param kind string  down|up|move|scrollup|scrolldown
---@param button string  left|middle|right|none
function Session:send_mouse(kind, button)
  if not self.win or not vim.api.nvim_win_is_valid(self.win) then
    return
  end
  local pos = self:mouse_pos()
  if pos.winid ~= self.win then
    return
  end
  local x = (pos.wincol - 1) * self.cell[1] + math.floor(self.cell[1] / 2)
  local y = (pos.winrow - 1) * self.cell[2] + math.floor(self.cell[2] / 2)
  self:send({
    type = "mouse",
    kind = kind,
    button = button,
    mods = { shift = false, alt = false, ctrl = false, super = false },
    x = x,
    y = y,
  })
end

--- Mouse position; separate method so tests can stub it.
---@return table  see vim.fn.getmousepos()
function Session:mouse_pos()
  return vim.fn.getmousepos()
end

local SPECIAL_KEYS = {
  ["<CR>"] = "enter",
  ["<BS>"] = "backspace",
  ["<Tab>"] = "tab",
  ["<Del>"] = "delete",
  ["<Up>"] = "up",
  ["<Down>"] = "down",
  ["<Left>"] = "left",
  ["<Right>"] = "right",
  ["<Home>"] = "home",
  ["<End>"] = "end",
  ["<PageUp>"] = "pageup",
  ["<PageDown>"] = "pagedown",
}

--- Enter key passthrough mode: printable keys and specials go to the browser,
--- <Esc> returns to normal mode.
function Session:enter_interact()
  if self.interact or not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  self.interact = true
  local opts = { buffer = self.buf, nowait = true, silent = true }
  vim.keymap.set("n", "<Esc>", function()
    self:exit_interact()
  end, opts)
  for lhs, name in pairs(SPECIAL_KEYS) do
    vim.keymap.set("n", lhs, function()
      self:send_key(name)
    end, opts)
  end
  for byte = 32, 126 do
    local ch = string.char(byte)
    local lhs = ch == " " and "<Space>" or ch == "<" and "<lt>" or ch == "\\" and "<Bslash>" or ch
    vim.keymap.set("n", lhs, function()
      self:send_key(ch:lower(), ch, { shift = ch:match("%u") ~= nil })
    end, opts)
  end
  self:update_winbar()
end

function Session:exit_interact()
  if not self.interact then
    return
  end
  self.interact = false
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    local function del(lhs)
      pcall(vim.keymap.del, "n", lhs, { buffer = self.buf })
    end
    del("<Esc>")
    for lhs in pairs(SPECIAL_KEYS) do
      del(lhs)
    end
    for byte = 32, 126 do
      local ch = string.char(byte)
      del(ch == " " and "<Space>" or ch == "<" and "<lt>" or ch == "\\" and "<Bslash>" or ch)
    end
  end
  self:update_winbar()
end

function Session:close()
  if self.closed then
    return
  end
  self.closed = true
  if self.group then
    pcall(vim.api.nvim_del_augroup_by_id, self.group)
    self.group = nil
  end
  if self.conn and not self.conn:is_closing() then
    self.conn:close()
  end
  self.conn = nil
  if self.server and not self.server:is_closing() then
    self.server:close()
  end
  self.server = nil
  if self.job then
    pcall(impl.jobstop, self.job)
    self.job = nil
  end
  if self.sock_path then
    pcall(vim.uv.fs_unlink, self.sock_path)
    self.sock_path = nil
  end
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  self.win = nil
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end
  self.buf = nil
end

---@param session jove.Webview
---@param chunk string?
local function on_socket_data(session, chunk)
  if not chunk then
    vim.schedule(function()
      session:close()
    end)
    return
  end
  session._rbuf = session._rbuf .. chunk
  while true do
    local nl = session._rbuf:find("\n", 1, true)
    if not nl then
      return
    end
    local line = session._rbuf:sub(1, nl - 1)
    session._rbuf = session._rbuf:sub(nl + 1)
    local ok, msg = pcall(vim.json.decode, line)
    if ok and type(msg) == "table" then
      vim.schedule(function()
        if not session.closed then
          session:handle(msg)
        end
      end)
    end
  end
end

---@param session jove.Webview
local function on_win_resized(session)
  vim.schedule(function()
    if session.closed or not session.win or not vim.api.nvim_win_is_valid(session.win) then
      return
    end
    session.grid = nil
    session:send(session:size_message("size"))
  end)
end

---@param url string
---@param opts { width: number?, height: number? }?  fractions of the editor (0-1)
---@return jove.Webview? session, string? err
function M.open(url, opts)
  opts = opts or {}
  local cfg = require("jove").config
  local wv = (cfg and cfg.webview) or {}
  local cmd = wv.cmd or "terminal-browser"
  if impl.executable(cmd) ~= 1 then
    return nil,
      ("jove: %q not found on PATH; install terminal-browser (https://terminal-browser.sh)"):format(
        cmd
      )
  end
  if not impl.terminal_supports_kitty() then
    return nil,
      "jove: webview requires a terminal with kitty graphics support (kitty, ghostty, wezterm)"
  end

  local self = setmetatable({}, Session)
  self.image_id = alloc_image_id()
  self.cell = { impl.cell_pixels() }
  self.title = url
  self.closed = false
  self.interact = false
  self._rbuf = ""
  self._stderr = ""

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  self.buf = buf

  local width_frac = tonumber(opts.width or wv.width) or 0.8
  local height_frac = tonumber(opts.height or wv.height) or 0.8
  local width = math.max(10, math.min(math.floor(vim.o.columns * width_frac), MAX_CELLS))
  local height = math.max(3, math.min(math.floor(vim.o.lines * height_frac), MAX_CELLS))
  local ok, win = pcall(vim.api.nvim_open_win, buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    style = "minimal",
  })
  if not ok then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return nil, tostring(win)
  end
  self.win = win
  self:update_winbar()

  -- Pipe server the browser connects to (PIXEL_EMBED).
  local sock_path = vim.fn.tempname()
  local server = vim.uv.new_pipe(false)
  local ok_bind, bind_err = pcall(function()
    server:bind(sock_path)
    server:listen(8, function(listen_err)
      if listen_err then
        return
      end
      local client = vim.uv.new_pipe(false)
      server:accept(client)
      if self.conn and not self.conn:is_closing() then
        self.conn:close()
      end
      self.conn = client
      self._rbuf = ""
      client:read_start(function(read_err, chunk)
        if read_err then
          return
        end
        on_socket_data(self, chunk)
      end)
    end)
  end)
  if not ok_bind then
    pcall(vim.uv.fs_unlink, sock_path)
    self:close()
    return nil, ("jove: webview socket failed: %s"):format(tostring(bind_err))
  end
  self.server = server
  self.sock_path = sock_path

  -- Window-local input forwarding.
  local mopts = { buffer = buf, nowait = true, silent = true }
  local function mmap(lhs, fn)
    vim.keymap.set({ "n", "v" }, lhs, fn, mopts)
  end
  mmap("<LeftMouse>", function()
    self:send_mouse("down", "left")
  end)
  mmap("<LeftRelease>", function()
    self:send_mouse("up", "left")
  end)
  mmap("<RightMouse>", function()
    self:send_mouse("down", "right")
  end)
  mmap("<RightRelease>", function()
    self:send_mouse("up", "right")
  end)
  mmap("<MiddleMouse>", function()
    self:send_mouse("down", "middle")
  end)
  mmap("<MiddleRelease>", function()
    self:send_mouse("up", "middle")
  end)
  mmap("<LeftDrag>", function()
    self:send_mouse("move", "left")
  end)
  mmap("<ScrollWheelUp>", function()
    self:send_mouse("scrollup", "none")
  end)
  mmap("<ScrollWheelDown>", function()
    self:send_mouse("scrolldown", "none")
  end)
  vim.keymap.set("n", "i", function()
    self:enter_interact()
  end, mopts)
  vim.keymap.set("n", "q", function()
    self:close()
  end, mopts)

  self.group =
    vim.api.nvim_create_augroup(("jove_webview_%x"):format(self.image_id), { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.group,
    pattern = tostring(win),
    callback = function()
      self:close()
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = self.group,
    callback = function()
      on_win_resized(self)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = self.group,
    callback = function()
      self:close()
    end,
  })

  local job = impl.jobstart({ cmd, "open", url }, {
    env = {
      PIXEL_EMBED = sock_path,
      PIXEL_TTY = impl.tty_name(),
      PIXEL_PANE = vim.NIL,
    },
    stdin = "null",
    on_stdout = function() end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            self._stderr = (self._stderr .. "\n" .. line):sub(-2000)
          end
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if not self.closed then
          self:close()
          if code ~= 0 then
            vim.notify(
              ("[Jove] terminal-browser exited with code %d%s"):format(
                code,
                self._stderr ~= "" and ("\n" .. self._stderr) or ""
              ),
              vim.log.levels.WARN
            )
          end
        end
      end)
    end,
  })
  if type(job) ~= "number" or job <= 0 then
    self:close()
    return nil, ("jove: failed to start %q"):format(cmd)
  end
  self.job = job
  return self
end

--- Write an HTML payload to a temp file and open it in a webview.
---@param html string
---@return jove.Webview? session, string? err
function M.open_html(html)
  local file = vim.fn.tempname() .. ".html"
  local fd = io.open(file, "w")
  if not fd then
    return nil, "jove: could not write temp html file"
  end
  fd:write(html)
  fd:close()
  return M.open("file://" .. file)
end

return M

-- Webview session: owns the placeholder window, the PIXEL_EMBED pipe server,
-- and the terminal-browser child process.
local impl = require("jove.webview.impl")
local kitty = require("jove.webview.kitty")

local M = {}

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
M.Session = Session

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

--- Fill the buffer with kitty placeholder cells for the current grid.
function Session:render_placeholders()
  local grid = self.grid
  if not grid or not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  local cols = math.min(grid.cols, vim.api.nvim_win_get_width(self.win), kitty.MAX_CELLS)
  local rows = math.min(grid.rows, vim.api.nvim_win_get_height(self.win), kitty.MAX_CELLS)
  local lines = {}
  for row = 1, rows do
    local parts = {}
    for col = 1, cols do
      parts[col] = kitty.cell(row, col)
    end
    lines[row] = table.concat(parts)
  end
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
  local hl = kitty.image_hl(grid.imageId)
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
  if not self.grid or not self.win or not vim.api.nvim_win_is_valid(self.win) then
    return
  end
  local pos = self:mouse_pos()
  if pos.winid ~= self.win then
    return
  end
  -- winrow/wincol include window decorations. Measure from the actual image
  -- origin so splits, float borders, and the winbar all use the same space.
  local origin = vim.fn.screenpos(self.win, 1, 1)
  if origin.row == 0 or origin.col == 0 then
    return
  end
  local col = pos.screencol - origin.col
  local row = pos.screenrow - origin.row
  local cols = math.min(self.grid.cols, vim.api.nvim_win_get_width(self.win), kitty.MAX_CELLS)
  local rows = math.min(self.grid.rows, vim.api.nvim_win_get_height(self.win), kitty.MAX_CELLS)
  if col < 0 or col >= cols or row < 0 or row >= rows then
    return
  end
  local x = col * self.cell[1] + math.floor(self.cell[1] / 2)
  local y = row * self.cell[2] + math.floor(self.cell[2] / 2)
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

--- Create the buffer and window hosting the placeholder grid.
---@param self jove.Webview
---@param size { width: number, height: number }  fractions of the editor (0-1)
---@return integer? win, string? err
local function open_placeholder_win(self, size)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  self.buf = buf

  local width = math.max(10, math.min(math.floor(vim.o.columns * size.width), kitty.MAX_CELLS))
  local height = math.max(3, math.min(math.floor(vim.o.lines * size.height), kitty.MAX_CELLS))
  local win_ui = require("jove.ui.win")
  local split_size = win_ui.mode("webview") == "hsplit" and height or width
  local win, err = win_ui.open(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    style = "minimal",
  }, split_size, "webview")
  if not win then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return nil, err
  end
  self.win = win
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].wrap = false
  vim.wo[win].scrolloff = 0
  vim.wo[win].sidescrolloff = 0
  self:update_winbar()
  return win
end

--- Start the pipe server the browser connects to (PIXEL_EMBED).
---@param self jove.Webview
---@return any? server, string? sock_path, string? err
local function start_pipe_server(self)
  local sock_path = vim.fn.tempname()
  local server = vim.uv.new_pipe(false)
  local ok, err = pcall(function()
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
  if not ok then
    pcall(vim.uv.fs_unlink, sock_path)
    return nil, nil, ("jove: webview socket failed: %s"):format(tostring(err))
  end
  return server, sock_path
end

--- Window-local input forwarding to the browser.
---@param self jove.Webview
local function map_input(self)
  local mopts = { buffer = self.buf, nowait = true, silent = true }
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
end

---@param self jove.Webview
local function attach_autocmds(self)
  self.group =
    vim.api.nvim_create_augroup(("jove_webview_%x"):format(self.image_id), { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.group,
    pattern = tostring(self.win),
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
end

--- Spawn the terminal-browser child process.
---@param self jove.Webview
---@param cmd string
---@param url string
---@return integer? job, string? err
local function start_browser(self, cmd, url)
  local job = impl.jobstart({ cmd, "open", url }, {
    env = {
      PIXEL_EMBED = self.sock_path,
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
    return nil, ("jove: failed to start %q"):format(cmd)
  end
  return job
end

--- Start a webview session: placeholder window + pipe server + browser process.
--- Callers must check availability first (see jove.webview.open).
---@param url string
---@param cmd string
---@param size { width: number, height: number }  fractions of the editor (0-1)
---@return jove.Webview? session, string? err
function M.start(url, cmd, size)
  local self = setmetatable({}, Session)
  self.image_id = kitty.alloc_image_id()
  self.cell = { impl.cell_pixels() }
  self.title = url
  self.closed = false
  self.interact = false
  self._rbuf = ""
  self._stderr = ""

  local win, win_err = open_placeholder_win(self, size)
  if not win then
    return nil, win_err
  end

  local server, sock_path, server_err = start_pipe_server(self)
  if not server then
    self:close()
    return nil, server_err
  end
  self.server = server
  self.sock_path = sock_path

  map_input(self)
  attach_autocmds(self)

  local job, job_err = start_browser(self, cmd, url)
  if not job then
    self:close()
    return nil, job_err
  end
  self.job = job
  return self
end

return M

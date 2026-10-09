-- Native terminal io over a PTY.
local impl = require("jove.webview.impl")
local kitty = require("jove.webview.kitty")

local M = {}

---@class jove.Webview
---@field buf integer?
---@field win integer?
---@field job integer?
---@field term integer?  Neovim terminal channel (separate from the PTY job).
---@field tty integer?   Outer-terminal graphics fd.
---@field image_id integer
---@field cell integer[]
---@field cols integer
---@field rows integer
---@field title string
---@field closed boolean
---@field group integer?
---@field transport jove.webview.Transport?
---@field grid { cols: integer, rows: integer }?
---@field _input string  Terminal replies emitted before jobstart returns.
---@field _output_tail string
local Session = {}
Session.__index = Session
M.Session = Session

---@param data string
function Session:send(data)
  if self.closed then
    return
  end
  if self.job then
    impl.jobsend(self.job, data)
  else
    self._input = self._input .. data
  end
end

---@param cols integer
---@param rows integer
function Session:render_placeholders(cols, rows)
  if self.closed or not self.term then
    return
  end
  if self.grid and self.grid.cols == cols and self.grid.rows == rows then
    return
  end
  self.grid = { cols = cols, rows = rows }
  vim.api.nvim_chan_send(self.term, kitty.grid(self.image_id, cols, rows))
end

function Session:update_winbar()
  if not self.win or not vim.api.nvim_win_is_valid(self.win) then
    return
  end
  local interacting = vim.api.nvim_get_current_buf() == self.buf and vim.fn.mode() == "t"
  local hint = interacting and " <C-\\><C-N> Normal mode " or " i interact, q close "
  vim.wo[self.win].winbar = (" %s —%s"):format(self.title:gsub("%%", "%%%%"), hint)
end

function Session:resize()
  if self.closed or not self.win or not vim.api.nvim_win_is_valid(self.win) then
    return
  end
  local cols = math.min(vim.api.nvim_win_get_width(self.win), kitty.MAX_CELLS)
  local rows = math.min(vim.api.nvim_win_get_height(self.win), kitty.MAX_CELLS)
  if cols == self.cols and rows == self.rows then
    return
  end
  self.cols, self.rows = cols, rows
  self.grid = nil
  self.transport:resize(cols, rows)
  if self.job then
    impl.jobresize(self.job, cols, rows)
  end
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
  if self.job then
    pcall(impl.jobstop, self.job)
    self.job = nil
  end
  if self.term then
    pcall(vim.fn.chanclose, self.term)
    self.term = nil
  end
  if self.tty then
    pcall(impl.write_tty, self.tty, kitty.delete(self.image_id))
    pcall(impl.close_tty, self.tty)
    self.tty = nil
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

---@param self jove.Webview
---@param size { width: number, height: number }
---@return integer? win, string? err
local function open_window(self, size)
  local buf = vim.api.nvim_create_buf(false, true)
  self.buf = buf
  vim.bo[buf].bufhidden = "wipe"
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
    return nil, err
  end
  self.win = win
  self:update_winbar()
  return win
end

---@return table<string, string>
local function browser_env()
  local env = vim.fn.environ()
  for _, key in ipairs({ "PIXEL_EMBED", "PIXEL_TTY", "PIXEL_PANE", "TMUX", "TMUX_PANE" }) do
    env[key] = nil
  end
  env.TERM = "xterm-256color"
  env.TERMINAL_BROWSER_NO_MERGE = "1"
  env.PIXEL_SKIP_GRAPHICS_CHECK = "1"
  env.TERMINAL_BROWSER_FRAMES = "inline"
  env.TERMINAL_BROWSER_PRESENT = "full"
  return env
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
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = self.group,
    buffer = self.buf,
    callback = function()
      self:close()
    end,
  })
  vim.api.nvim_create_autocmd({ "TermEnter", "TermLeave" }, {
    group = self.group,
    buffer = self.buf,
    callback = function()
      vim.schedule(function()
        self:update_winbar()
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = self.group,
    callback = function()
      vim.schedule(function()
        self:resize()
      end)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = self.group,
    callback = function()
      self:close()
    end,
  })
end

---@param url string
---@param cmd string
---@param size { width: number, height: number }
---@return jove.Webview? session, string? err
function M.start(url, cmd, size)
  local self = setmetatable({
    image_id = kitty.alloc_image_id(),
    cell = { impl.cell_pixels() },
    cols = 0,
    rows = 0,
    title = url,
    closed = false,
    _input = "",
    _output_tail = "",
  }, Session)
  local win, win_err = open_window(self, size)
  if not win then
    self:close()
    return nil, win_err
  end
  local tty, tty_err = impl.open_tty()
  if not tty then
    self:close()
    return nil, "jove: could not open terminal for webview graphics: " .. tostring(tty_err)
  end
  self.tty = tty
  local ok, term = pcall(vim.api.nvim_open_term, self.buf, {
    force_crlf = false,
    on_input = function(_, _, _, data)
      self:send(data)
    end,
  })
  if not ok or term == 0 then
    self:close()
    return nil, "jove: could not create webview terminal: " .. tostring(term)
  end
  self.term = term
  vim.bo[self.buf].scrollback = 0
  for key, value in pairs({
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    statuscolumn = "",
    wrap = false,
    scrolloff = 0,
    sidescrolloff = 0,
  }) do
    vim.wo[win][key] = value
  end
  self.transport = require("jove.webview.transport").new(self.image_id, self.cell, {
    output = function(data)
      self._output_tail = (self._output_tail .. require("jove.ansi").strip(data)):sub(-2000)
      vim.api.nvim_chan_send(self.term, data)
    end,
    input = function(data)
      self:send(data)
    end,
    graphics = function(data)
      impl.write_tty(self.tty, data)
    end,
    placed = function(cols, rows)
      self:render_placeholders(cols, rows)
    end,
  })
  self:resize()
  attach_autocmds(self)
  vim.keymap.set("n", "q", function()
    self:close()
  end, { buffer = self.buf, nowait = true, silent = true, desc = "Jove: Close Webview" })
  local started, job = pcall(impl.jobstart, { cmd, "open", url }, {
    pty = true,
    width = self.cols,
    height = self.rows,
    clear_env = true,
    env = browser_env(),
    on_stdout = function(_, data)
      if self.closed or not data then
        return
      end
      local parts = {}
      for i, part in ipairs(data) do
        parts[i] = part:gsub("\n", "\0")
      end
      local success, err = pcall(self.transport.feed, self.transport, table.concat(parts, "\n"))
      if not success then
        self:close()
        vim.notify("[Jove] webview transport failed: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      local title = vim.b[self.buf].term_title
      if type(title) == "string" and title ~= "" and title ~= self.title then
        self.title = title
        self:update_winbar()
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if not self.closed then
          self:close()
          if code ~= 0 then
            vim.notify(
              ("[Jove] terminal-browser exited with code %d\n%s"):format(code, self._output_tail),
              vim.log.levels.WARN
            )
          end
        end
      end)
    end,
  })
  if not started or type(job) ~= "number" or job <= 0 then
    self:close()
    return nil, ("jove: failed to start %q%s"):format(cmd, started and "" or ": " .. tostring(job))
  end
  self.job = job
  if self._input ~= "" then
    self:send(self._input)
    self._input = ""
  end
  vim.schedule(function()
    if not self.closed and vim.api.nvim_get_current_win() == self.win then
      vim.cmd("startinsert")
    end
  end)
  return self
end

return M

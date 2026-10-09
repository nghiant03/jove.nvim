-- Injectable platform primitives.

local impl = {
  jobstart = vim.fn.jobstart,
  jobstop = vim.fn.jobstop,
  jobsend = vim.fn.chansend,
  jobresize = vim.fn.jobresize,
  executable = vim.fn.executable,
}

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

---@return integer? fd, string? err
function impl.open_tty()
  return vim.uv.fs_open(impl.tty_name(), "w", 384)
end

---@param fd integer
---@param data string
function impl.write_tty(fd, data)
  local offset = 1
  while offset <= #data do
    local written, err = vim.uv.fs_write(fd, data:sub(offset), -1)
    assert(written and written > 0, err or "could not write webview graphics")
    offset = offset + written
  end
end

---@param fd integer
function impl.close_tty(fd)
  vim.uv.fs_close(fd)
end

return impl

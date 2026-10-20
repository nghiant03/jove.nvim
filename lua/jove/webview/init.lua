-- Embedded interactive webview.

local impl = require("jove.webview.impl")
local session = require("jove.webview.session")

local M = {}

M._impl = impl
M._Session = session.Session -- test seam

---@param mime string
---@param renderer fun(value: any): string
function M.register_renderer(mime, renderer)
  require("jove.webview.document").register(mime, renderer)
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

---@param url string
---@param embedded_err string?  why the embedded webview was skipped (auto fallback)
---@return boolean? ok, string? err
local function open_browser(url, embedded_err)
  local proc, open_err = impl.ui_open(url)
  if not proc then
    return nil,
      (embedded_err and (embedded_err .. "; ") or "")
        .. "could not open the default browser: "
        .. tostring(open_err)
  end
  return true
end

---@param url string
---@param opts { width: number?, height: number? }?  fractions of the editor (0-1)
---@return jove.Webview|boolean|nil session, string? err  true when handed off to the system browser
function M.open(url, opts)
  opts = opts or {}
  local cfg = require("jove").config
  local wv = (cfg and cfg.webview) or {}
  local cmd = wv.cmd or "terminal-browser"
  local renderer = wv.renderer or "auto"
  if renderer == "browser" then
    return open_browser(url)
  end
  local embedded_err
  if impl.executable(cmd) ~= 1 then
    embedded_err = ("jove: %q not found on PATH; install terminal-browser (https://terminal-browser.sh)"):format(
      cmd
    )
  elseif not impl.terminal_supports_kitty() then
    embedded_err =
      "jove: webview requires a terminal with kitty graphics support (kitty, ghostty, wezterm)"
  end
  if embedded_err then
    if renderer == "terminal" then
      return nil, embedded_err
    end
    vim.notify(
      "[Jove] terminal-browser unavailable; opened in the default browser",
      vim.log.levels.INFO
    )
    return open_browser(url, embedded_err)
  end

  local width = tonumber(opts.width or wv.width) or 0.5
  local height = tonumber(opts.height or wv.height) or 0.5
  return session.start(url, cmd, { width = width, height = height })
end

---@param html string
---@return jove.Webview|boolean|nil session, string? err  true when handed off to the system browser
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

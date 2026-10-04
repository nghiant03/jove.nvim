-- Embedded interactive webview via terminal-browser (https://github.com/zenbu-labs/terminal-browser).
--
-- terminal-browser is a real Chromium (Electron offscreen rendering) that draws
-- pixels into the terminal through the kitty graphics protocol. It supports
-- embedding: the host (us) prints kitty unicode placeholder cells, the browser
-- streams frames into them, and input is forwarded as JSON-lines over a unix
-- socket (PIXEL_EMBED). This module is the public entry point; the pieces live
-- in jove.webview.impl (platform primitives), jove.webview.kitty (placeholder
-- mechanics), and jove.webview.session (session lifecycle).

local impl = require("jove.webview.impl")
local session = require("jove.webview.session")

local M = {}

M._impl = impl
M._Session = session.Session -- test seam

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

  local width = tonumber(opts.width or wv.width) or 0.8
  local height = tonumber(opts.height or wv.height) or 0.8
  return session.start(url, cmd, { width = width, height = height })
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

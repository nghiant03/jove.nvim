-- Shared layout policy for Jove viewers.

local M = {}

---@param view jove.WindowView?
---@return jove.WindowMode
function M.mode(view)
  local ok, jove = pcall(require, "jove")
  local ui = ok and type(jove) == "table" and jove.config and jove.config.ui
  local m = type(ui) == "table" and ui.window_mode or nil
  if view and type(ui) == "table" and type(ui.window_overrides) == "table" then
    m = ui.window_overrides[view] or m
  end
  if m == "float" or m == "hsplit" then
    return m
  end
  return "vsplit"
end

---@param fbuf integer
---@param enter boolean
---@param float_opts table  nvim_open_win config for "float" mode
---@param size integer?
---@param view jove.WindowView?
---@return integer? win, string? err
function M.open(fbuf, enter, float_opts, size, view)
  local mode = M.mode(view)
  local cfg = float_opts
  if mode ~= "float" then
    cfg = { split = mode == "vsplit" and "right" or "below", style = float_opts.style }
    if type(size) == "number" and size > 0 then
      if mode == "vsplit" then
        cfg.width = size
      else
        cfg.height = size
      end
    end
  end
  local ok, win = pcall(vim.api.nvim_open_win, fbuf, enter, cfg)
  if not ok then
    return nil, tostring(win)
  end
  return win
end

---@param win integer
---@return boolean
function M.is_float(win)
  return vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= ""
end

return M

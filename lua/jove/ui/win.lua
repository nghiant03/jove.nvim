-- Open scratch UI windows (inspector, kernel panel, output viewer) as floats
-- or splits according to `ui.window_mode`.
local M = {}

---@return "float"|"vsplit"|"hsplit"
function M.mode()
  local ok, jove = pcall(require, "jove")
  local ui = ok and type(jove) == "table" and jove.config and jove.config.ui
  local m = type(ui) == "table" and ui.window_mode or nil
  if m == "float" or m == "hsplit" then
    return m
  end
  return "vsplit"
end

---Open fbuf per `ui.window_mode`: float_opts apply in "float" mode, size is
---the split width ("vsplit") or height ("hsplit").
---@param fbuf integer
---@param enter boolean
---@param float_opts table  nvim_open_win config for "float" mode
---@param size integer?
---@return integer? win, string? err
function M.open(fbuf, enter, float_opts, size)
  local mode = M.mode()
  local cfg = float_opts
  if mode ~= "float" then
    cfg = { split = mode == "vsplit" and "right" or "below" }
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

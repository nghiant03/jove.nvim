-- outputs.lua: bridge molten <-> .ipynb JSON outputs.
local M = {}

---Has molten been loaded into Neovim?
---@return boolean
local function molten_loaded()
  return vim.fn.exists(":MoltenInit") == 2
end

---Has molten been initialized in this buffer?
---@param buf integer
---@return boolean
local function molten_initialized(buf)
  if not molten_loaded() then
    return false
  end
  -- MoltenRunningKernels is the documented Lua-callable accessor.
  local ok, kernels = pcall(vim.fn.MoltenRunningKernels, true)
  if not ok or type(kernels) ~= "table" or #kernels == 0 then
    return false
  end
  -- Molten attaches kernels per-buffer; if any kernel is running we assume the
  -- caller has already targeted the right buffer (single-kernel-per-buffer model).
  return true
end

---Restore outputs from .ipynb JSON into molten cells.
---No-op if molten isn't initialized.
---@param buf integer
function M.import(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  if not molten_initialized(buf) then
    return
  end
  local ok, err = pcall(vim.cmd, "MoltenImportOutput")
  if not ok then
    vim.notify("[ipynb] MoltenImportOutput failed: " .. tostring(err), vim.log.levels.WARN)
  end
end

---Merge molten's in-session outputs back into the .ipynb on disk.
---@param buf integer
function M.export(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  if not molten_initialized(buf) then
    return
  end
  -- The ! variant overwrites without prompting.
  local ok, err = pcall(vim.cmd, "MoltenExportOutput!")
  if not ok then
    vim.notify("[ipynb] MoltenExportOutput failed: " .. tostring(err), vim.log.levels.WARN)
  end
end

return M

-- outputs.lua: output persistence stub.
-- Molten is gone; outputs are merged into the .ipynb automatically on write
-- in a later phase (PLAN.md Phase 6). These shims keep the buffer.lua call
-- sites (`M.import` / `M.export`) working as silent no-ops.
local M = {}

local export_notified = false

---Import outputs from .ipynb JSON (stub: real import lands in Phase 6).
---@param buf integer
---@return boolean
function M.import(_buf)
  return true
end

---Export outputs to the .ipynb on disk (stub: real persistence lands in
---Phase 6; outputs are merged automatically on save).
---@param buf integer
---@return boolean
function M.export(_buf)
  if not export_notified then
    export_notified = true
    vim.notify("jove: outputs are now persisted automatically on save", vim.log.levels.INFO)
  end
  return true
end

return M

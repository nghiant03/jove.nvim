-- Per-buffer state, cleaned up on BufWipeout.
local M = {}

---@class jove.BufferState
---@field path string?        Path of the .ipynb backing this buffer (set on successful read).
---@field json table?         Parsed .ipynb JSON, refreshed on read and write.
---@field last_write string?  Checksum of the last written bytes, used to suppress self-triggered reloads.
-- Module-owned slots: cells (cell.lua), kernel (kernel.lua), exec (execute.lua),
-- outputs (output.lua), and front_matter (buffer.lua). Front matter is removed
-- from the displayed buffer and restored on write.

---@type table<integer, jove.BufferState>
local registry = {}

local group

---Register the single BufWipeout cleanup autocmd (once, lazily).
local function ensure_cleanup_autocmd()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup("jove_state", { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    pattern = "*",
    callback = function(ev)
      M.clear(ev.buf)
    end,
  })
end

---Get (creating on demand) the state table for a buffer.
---@param buf integer
---@return jove.BufferState
function M.get(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  ensure_cleanup_autocmd()
  local entry = registry[buf]
  if not entry then
    entry = {}
    registry[buf] = entry
  end
  return entry
end

---Peek at a buffer's state without creating an entry.
---@param buf integer
---@return jove.BufferState?
function M.peek(buf)
  return registry[buf]
end

---Drop the state table for a buffer.
---@param buf integer
function M.clear(buf)
  registry[buf] = nil
end

return M

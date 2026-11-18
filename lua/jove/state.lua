-- Buffer state.

local M = {}

---@class jove.BufferState
---@field path string?        Path of the .ipynb backing this buffer.
---@field json table?         Parsed .ipynb JSON.
---@field last_write string?  Checksum of the last written bytes, used to suppress self-triggered reloads.
---@field lang string?        Kernelspec language id.
---@field cells jove.CellCache?                    Parsed cell cache.
---@field kernel jove.KernelEntry?                 Kernel handle.
---@field exec jove.ExecState?                     Execution queue/status.
---@field outputs table<string, jove.OutputEntry>? Rendered outputs by cell hash.
---@field front_matter string[]?                   Stripped jupytext header lines.
---@field content_rev integer?                     Detects output changes during a read or write.

---@type table<integer, jove.BufferState>
local registry = {}

local group

local function ensure_cleanup_autocmd()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup("jove_state", { clear = true })
  -- Keep the kernel alive across :bdelete; release its buffer state only on wipeout.
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    pattern = "*",
    callback = function(ev)
      M.clear(ev.buf)
    end,
  })
end

---@param buf integer
---@return jove.BufferState  Buffer state, created on first access.
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

---@param buf integer
---@return jove.BufferState?
function M.peek(buf)
  return registry[buf]
end

---@param buf integer
function M.clear(buf)
  registry[buf] = nil
end

---@return integer[]  valid buffer handles with jove state, sorted
function M.buffers()
  local bufs = {}
  for buf in pairs(registry) do
    if vim.api.nvim_buf_is_valid(buf) then
      bufs[#bufs + 1] = buf
    end
  end
  table.sort(bufs)
  return bufs
end

return M

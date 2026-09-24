-- Buffer state.
local M = {}

---@class jove.BufferState
---@field path string?        Path of the .ipynb backing this buffer (set on successful read).
---@field json table?         Parsed .ipynb JSON, refreshed on read and write.
---@field last_write string?  Checksum of the last written bytes, used to suppress self-triggered reloads.
---@field lang string?        Kernelspec language id (see jove.lang), set on read.

---@type table<integer, jove.BufferState>
local registry = {}

local group

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

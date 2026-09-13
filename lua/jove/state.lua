-- state.lua: per-buffer registry for jove bookkeeping.
-- Replaces the scattered vim.b[buf].jove_json / vim.b[buf].jove_path usage;
-- the registry is a plain Lua table keyed by bufnr, cleaned up on BufWipeout.
local M = {}

---@class jove.BufferState
---@field path string?        Path of the .ipynb backing this buffer (set on successful read).
---@field json table?         Parsed .ipynb JSON, refreshed on read and write.
---@field last_write string?  Checksum of the bytes we last wrote (single-flight guard, Phase 1).
-- Reserved slots for future phases (populated by later modules, documented here):
--   cells   -- lua/jove/cell.lua      cell parse cache (Phase 2)
--   kernel  -- lua/jove/kernel.lua    bridge/kernel handle (Phase 3)
--   exec    -- lua/jove/execute.lua   { queue, running, status, status_cbs,
--                                        attached, unsubs,
--                                        start_hr[hash],
--                                        meta[hash] = { count, elapsed_ms } }
--                                                        (Phase 4 + Phase A)
--   outputs -- lua/jove/output.lua    per-cell output store (Phase 5)
--   front_matter -- lua/jove/buffer.lua    `# ---`...`# ---` block
--                                              stripped from the buffer on read,
--                                              prepended on write ([]|nil)

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

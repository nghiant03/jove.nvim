-- buffer.lua: BufReadCmd / BufWriteCmd handlers.
-- Conversion runs async via jove.convert; state bookkeeping happens on
-- completion callbacks (scheduled onto the main loop).
local convert = require("jove.convert")
local persist = require("jove.persist")
local state = require("jove.state")
local kernel = require("jove.kernel")

local M = {}

-- Monotonic sequence numbers guarding against stale async read completions.
local read_seq = {}

-- Single-flight write bookkeeping per buffer.
-- While a jupytext conversion is in flight for a buffer, further :w requests
-- are coalesced: the latest request's (changedtick, lines) are stashed here
-- and re-issued automatically once the in-flight write completes.
---@type table<integer, {in_flight: boolean, dirty: boolean, pending_tick: integer?, pending_lines: string[]?}>
local flights = {}

---Detect filetype from kernelspec.language in the .ipynb JSON.
---@param json table?
---@return string
local function filetype_for(json)
  local lang = json
    and json.metadata
    and json.metadata.kernelspec
    and json.metadata.kernelspec.language
  if not lang then
    return "python"
  end
  lang = tostring(lang):lower()
  local map = { python = "python", julia = "julia", r = "r", javascript = "javascript" }
  return map[lang] or "python"
end

---Parse the raw .ipynb JSON from disk; returns nil on failure.
---@param path string
---@return table?
local function read_json(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local data = fd:read("*a")
  fd:close()
  local ok, json = pcall(vim.json.decode, data)
  if not ok then
    return nil
  end
  return json
end

---Restore the cursor of a window showing `buf` after the buffer text was
---replaced; clamps to the new line count.
---@param buf integer
---@param cursor [integer, integer]  -- 1-based lnum, 0-based col
---@param lines string[]
local function restore_cursor(buf, cursor, lines)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    return
  end
  local lnum = math.min(cursor[1], #lines)
  local col = math.max(0, math.min(cursor[2], #(lines[lnum] or "")))
  pcall(vim.api.nvim_win_set_cursor, win, { lnum, col })
end

---BufReadCmd handler; also used by :JoveReload and the auto-reload flow.
---Only `buftype` is set synchronously; the jupytext read is async. Concurrent
---reads of the same buffer are guarded: only the most recent read's
---completion is applied, stale ones are ignored.
---@param buf integer
---@param path string
---@param opts {preserve_cursor: boolean?}?
function M.read(buf, path, opts)
  opts = opts or {}
  local cfg = require("jove").config

  if not vim.uv.fs_stat(path) then
    -- New file: empty py:percent buffer, defer JSON creation to first write.
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].filetype = "python"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %%", "" })
    vim.bo[buf].modified = false
    state.get(buf).path = path
    return
  end

  -- Set the buftype up front so the buffer is acwrite while the async
  -- jupytext read is in flight.
  vim.bo[buf].buftype = "acwrite"

  local seq = (read_seq[buf] or 0) + 1
  read_seq[buf] = seq

  convert.read(path, function(lines, err)
    -- The convert callback runs in a libuv (fast) context; move onto the
    -- main loop before touching buffer/window APIs.
    vim.schedule(function()
      if read_seq[buf] ~= seq or not vim.api.nvim_buf_is_valid(buf) then
        return -- stale completion or wiped buffer: ignore
      end

      if not lines then
        vim.notify("[jove] read failed: " .. (err or "?"), vim.log.levels.ERROR)
        return
      end

      local json = read_json(path)
      local ft = filetype_for(json)

      local cursor
      if opts.preserve_cursor then
        local win = vim.fn.bufwinid(buf)
        if win ~= -1 then
          cursor = vim.api.nvim_win_get_cursor(win)
        end
      end

      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

      -- Stash state before setting filetype so FileType autocmds can see it.
      local st = state.get(buf)
      st.path = path
      st.json = json

      vim.bo[buf].filetype = ft
      vim.bo[buf].modified = false

      if cursor then
        restore_cursor(buf, cursor, lines)
      end

      -- Schedule kernel init + output import after BufRead* autocmds settle.
      -- Output import is NOT gated on auto_kernel: importing persisted
      -- outputs works (and is wanted) without a running kernel too.
      if cfg.auto_kernel then
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buf) then
            kernel.init(buf)
          end
        end)
      end
      if cfg.auto_import_outputs then
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buf) then
            persist.import(buf)
          end
        end)
      end
    end)
  end)
end

---Run one jupytext write flight for `buf` and handle its completion.
---@param buf integer
---@param path string
---@param tick integer  -- changedtick captured at request time
---@param lines string[]  -- buffer lines captured at request time
local function start_write(buf, path, tick, lines)
  local cfg = require("jove").config
  local flight = flights[buf]
  flight.in_flight = true

  convert.write(path, lines, function(bytes, err)
    -- The convert callback runs in a libuv (fast) context; move onto the
    -- main loop before touching buffer APIs.
    vim.schedule(function()
      flight.in_flight = false

      if not vim.api.nvim_buf_is_valid(buf) then
        flights[buf] = nil
        return
      end

      if not bytes then
        -- Drop any coalesced request with the failed flight: the user's
        -- buffer stays modified, the notification names the error, and the
        -- next :w starts a fresh flight. Replaying a write that just failed
        -- would only spam identical errors.
        flight.dirty = false
        flight.pending_tick = nil
        flight.pending_lines = nil
        vim.notify("[jove] write failed: " .. (err or "?"), vim.log.levels.ERROR)
        return
      end

      -- jupytext already wrote the file when it existed on disk (convert
      -- wrote it atomically otherwise); only refresh bookkeeping here.
      local st = state.get(buf)
      local ok_json, json = pcall(vim.json.decode, bytes)
      if ok_json then
        st.json = json
      end
      st.last_write = vim.fn.sha256(bytes)

      -- Only clear the modified flag if the user hasn't edited the buffer
      -- while the write was in flight; otherwise leave it set so they know
      -- to re-save.
      if vim.api.nvim_buf_get_changedtick(buf) == tick then
        vim.bo[buf].modified = false
      end

      -- NOTE: user BufWritePost autocmds observe the jupytext-written file
      -- BEFORE the outputs merge — persist.export below runs synchronously
      -- in this same callback, after this event has fired.
      vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })

      if cfg.auto_export_outputs and not flight.dirty then
        -- Merge session outputs into the fresh JSON on disk, matched by cell
        -- content hash (P3). persist.export atomically writes the merged
        -- bytes and refreshes st.json + st.last_write to them, so our own
        -- merged write still suppresses FileChangedShell below. Synchronous
        -- on purpose: we are already on the main loop inside the write
        -- callback, and the checksum must be updated before this callback
        -- yields.
        -- Final flight only: when a coalesced write is pending
        -- (flight.dirty), this flight's merged file would be overwritten by
        -- the replay anyway — the replayed (final) flight exports instead.
        persist.export(buf, bytes)
      end

      -- Replay the latest request captured while this flight was running.
      if flight.dirty then
        flight.dirty = false
        local ptick = flight.pending_tick
        local plines = flight.pending_lines
        flight.pending_tick = nil
        flight.pending_lines = nil
        start_write(buf, path, ptick, plines)
      else
        flights[buf] = nil
      end
    end)
  end)
end

---BufWriteCmd handler.
---
---Single-flight design: at most one jupytext conversion per buffer runs at a
---time. If a write is requested while one is in flight, the latest request's
---(changedtick, lines) are captured and automatically re-issued when the
---in-flight conversion completes. The final disk state therefore always
---reflects the last :w, no jupytext processes race on the same file, and the
---modified flag is only cleared when the buffer hasn't changed since the
---lines that were actually written.
---@param buf integer
---@param path string
function M.write(buf, path)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local flight = flights[buf]
  if flight and flight.in_flight then
    flight.dirty = true
    flight.pending_tick = tick
    flight.pending_lines = lines
    return
  end

  flights[buf] = { in_flight = false, dirty = false, pending_tick = nil, pending_lines = nil }
  start_write(buf, path, tick, lines)
end

---FileChangedShell logic (plan bug P11).
---Decides whether a file-change event for a jove buffer is our own write.
---Callers keep the built-in behavior when this returns nil (the mere
---existence of a FileChangedShell handler already suppresses Neovim's own
---warning; v:fcs_choice stays empty, so no default reload happens either).
---@param buf integer
---@param path string
---@return boolean?  -- true: own write, suppress silently; false: auto-reload
---    scheduled (suppress default handling); nil: not jove-managed, caller
---    falls back to warn-notify
function M.changed_shell(buf, path)
  local st = state.peek(buf)
  if not st or not st.path then
    return nil
  end
  if vim.fn.fnamemodify(st.path, ":p") ~= vim.fn.fnamemodify(path, ":p") then
    return nil
  end

  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local bytes = fd:read("*a")
  fd:close()

  if st.last_write and bytes and vim.fn.sha256(bytes) == st.last_write then
    -- Our own last write echoed back to us: suppress silently.
    return true
  end

  local cfg = require("jove").config
  if cfg.auto_reload then
    -- Foreign change with auto-reload on: go through the normal read flow,
    -- preserving the cursor. fcs_choice stays empty so the default handler
    -- does nothing while ours is in flight.
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then
        M.read(buf, st.path, { preserve_cursor = true })
      end
    end)
    return false
  end

  return nil
end

---Reload the notebook backing `buf` from disk (cursor-preserving).
---@param buf integer
function M.reload(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local st = state.peek(buf)
  local path = (st and st.path) or vim.api.nvim_buf_get_name(buf)
  if path == "" then
    vim.notify("[jove] buffer has no notebook file to reload", vim.log.levels.WARN)
    return
  end
  M.read(buf, path, { preserve_cursor = true })
end

return M

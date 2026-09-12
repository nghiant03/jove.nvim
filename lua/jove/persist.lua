-- persist.lua: native output persistence without molten (Phase 6).
-- Session outputs (the store in state.get(buf).outputs, fed by bridge
-- `output` events) are merged into the .ipynb JSON on write, matched to
-- cells by CONTENT hash: jupytext py:percent round-trips drop cell ids, so
-- sha256(normalized source) is the only stable identity (plan P3). On read,
-- the inverse mapping replays the stored outputs back through output.import
-- -- write -> reload -> outputs survive.
--
-- Both directions convert between the two representations:
--   raw params   (bridge `output` event shape, PROTOCOL.md -- what the
--                 output store's `raw` lists hold, what mime.render draws)
--   nbformat v4  ({output_type = "stream"|"execute_result"|"display_data"|
--                 "error", ...})
local state = require("jove.state")
local cell = require("jove.cell")

local M = {}

-- Tombstone bookkeeping ("seen this session"): hashes that had outputs at
-- any point this session -- imported from disk on read, present in the
-- output store at export time. output.lua's clear() only nils store entries
-- (verified), so persist.lua tracks this itself: at export, a hash that is
-- seen but no longer in the store means the user CLEARED the outputs this
-- session, and the deletion is persisted as `outputs: []` (otherwise
-- jupytext-preserved disk outputs would resurrect on reload). The set lives
-- per buffer and dies with the buffer (BufWipeout below).
---@type table<integer, table<string, boolean>>
local seen = {}

vim.api.nvim_create_autocmd("BufWipeout", {
  group = vim.api.nvim_create_augroup("jove_persist", { clear = false }),
  pattern = "*",
  callback = function(ev)
    seen[ev.buf] = nil
  end,
})

---@param buf integer
---@param hash string
local function mark_seen(buf, hash)
  local set = seen[buf]
  if not set then
    set = {}
    seen[buf] = set
  end
  set[hash] = true
end

---Tombstone-precedence helper used by merge_into (the exact rule, verbatim):
---session clear > session outputs > disk. At export, a code cell whose hash
---(1) has session outputs in the store gets them written; (2) is in the
---session seen-set but NOT in the store gets `outputs = []` and
---`execution_count = null` (the session cleared it -- deletion persists);
---(3) is unseen by the session gets disk truth (jupytext-preserved) untouched.

---Empty-dict helper: empty Lua tables encode as `[]` (array), which nbformat
---rejects for object-typed fields like metadata/data. Returns `t` when it is
---a non-empty table, else a fresh empty dict that encodes as `{}`.
---@param t any
---@return table
local function as_dict(t)
  if type(t) == "table" and next(t) ~= nil then
    return t
  end
  return vim.empty_dict()
end

---String value of an nbformat payload: strings as-is; line lists joined
---(nbformat list items conventionally carry their own trailing "\n").
---@param v any
---@return string
local function text_of(v)
  if type(v) == "table" then
    return table.concat(v, "")
  end
  return type(v) == "string" and v or ""
end

---Mime bundle with every value normalized to a string (mime.render only
---draws string payloads).
---@param data any
---@return table<string, string>
local function bundle_of(data)
  local out = {}
  for mime, v in pairs(data or {}) do
    out[mime] = text_of(v)
  end
  return out
end

---Convert one raw bridge `output` event param to an nbformat v4 output
---object; nil for unknown kinds (skipped on export).
---@param params table
---@return table?
function M.to_nbformat(params)
  params = params or {}
  local kind = params.kind
  if kind == "stream" then
    return {
      output_type = "stream",
      name = params.name or "stdout",
      text = (params.mime or {})["text/plain"] or "",
    }
  elseif kind == "execute_result" then
    return {
      output_type = "execute_result",
      data = as_dict(params.mime),
      metadata = vim.empty_dict(),
      execution_count = vim.NIL,
    }
  elseif kind == "display_data" then
    return {
      output_type = "display_data",
      data = as_dict(params.mime),
      metadata = vim.empty_dict(),
    }
  elseif kind == "error" then
    return {
      output_type = "error",
      ename = params.ename or "",
      evalue = params.evalue or "",
      traceback = params.traceback or {}, -- ANSI raw, per PROTOCOL.md; a list, so [] is valid
    }
  end
  return nil
end

---Inverse mapping: nbformat v4 output object → raw bridge `output` event
---params; nil for unknown types (skipped on import).
---@param nb table
---@return table?
function M.to_raw(nb)
  nb = nb or {}
  local t = nb.output_type
  if t == "stream" then
    return {
      kind = "stream",
      name = nb.name or "stdout",
      mime = { ["text/plain"] = text_of(nb.text) },
    }
  elseif t == "execute_result" then
    return { kind = "execute_result", mime = bundle_of(nb.data) }
  elseif t == "display_data" then
    return { kind = "display_data", mime = bundle_of(nb.data) }
  elseif t == "error" then
    return {
      kind = "error",
      ename = nb.ename or "",
      evalue = nb.evalue or "",
      traceback = nb.traceback or {}, -- stays ANSI raw
    }
  end
  return nil
end

---Merge session outputs into a parsed notebook (mutates code cells in
---place): each code cell's source is hashed and the tombstone precedence
---rule (see near the top of this file) decides the outcome:
---session outputs REPLACE the cell's `outputs`; a seen-but-cleared hash is
---tombstoned to `outputs = []`; unseen cells keep whatever jupytext
---`--update` preserved. Replaced/tombstoned cells also get
---`execution_count = null` (the session result carries no count).
---Store entries flagged `from_disk` (output.import: disk content transiting
---the store, not session results) are SKIPPED entirely — their outputs are
---already on disk; rewriting them would null execution counts on every save.
---@param nb table?
---@param store table?  -- state.outputs: hash → {raw = {...}, from_disk?}
---@param seen_hashes table?  -- hash → true, "had outputs this session"
---@return integer merged  -- number of cells replaced or tombstoned
function M.merge_into(nb, store, seen_hashes)
  if type(nb) ~= "table" or type(nb.cells) ~= "table" then
    return 0
  end
  local merged = 0
  for _, c in ipairs(nb.cells) do
    if c.cell_type == "code" and c.source ~= nil then
      local hash = cell.hash_source(c.source)
      local entry = store and store[hash]
      -- Disk content transiting the store (output.import tags entries
      -- from_disk) is skipped entirely: its outputs are already on disk,
      -- and rewriting them would null execution counts on every save. A
      -- CLEARED entry is gone from the store and still tombstones below.
      local from_disk = entry ~= nil and entry.from_disk == true
      if not from_disk and entry and type(entry.raw) == "table" and #entry.raw > 0 then
        local outs = {}
        for _, params in ipairs(entry.raw) do
          local out = M.to_nbformat(params)
          if out then
            outs[#outs + 1] = out
          end
        end
        c.outputs = outs
        c.execution_count = vim.NIL
        merged = merged + 1
      elseif not from_disk and seen_hashes and seen_hashes[hash] then
        -- Session cleared this cell's outputs: persist the deletion
        -- (`outputs` is an array, so an empty Lua table encodes correctly).
        c.outputs = {}
        c.execution_count = vim.NIL
        merged = merged + 1
      end
    end
  end
  return merged
end

---Atomic write (same pattern as convert.lua): temp file in the same
---directory, then rename over `path`.
---@param path string
---@param bytes string
---@return boolean, string?
local function atomic_write(path, bytes)
  local tmp = ("%s.jove-%s.tmp"):format(path, vim.uv.os_getpid())
  local fd, ferr = io.open(tmp, "wb")
  if not fd then
    return false, ferr or ("cannot create " .. tmp)
  end
  fd:write(bytes)
  fd:close()
  local ok, rerr = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return false, rerr or ("cannot rename " .. tmp)
  end
  return true
end

---Merge session outputs into the notebook on disk and refresh buffer.lua's
---checksum bookkeeping. Call from the write flow with the fresh jupytext
---bytes. Checksum discipline: the merged write changes the file AFTER
---buffer.lua recorded `st.last_write` for the jupytext bytes, so this
---updates `st.json` and `st.last_write` to the MERGED bytes -- the
---FileChangedShell self-trigger suppression keeps working.
---No-op (silent) when the buffer is not jove-managed, when there is nothing
---session-side to persist, or when the merge changes nothing (a pure
---open→save: from_disk store entries are skipped and the seen-set is pruned
---to the fresh JSON, so nothing merges and the file is not rewritten);
---failures notify WARN, never crash the write.
---@param buf integer
---@param bytes string?  Fresh notebook JSON from the write flow; nil falls
---    back to st.json.
---@return boolean  -- true when a merged write happened
function M.export(buf, bytes)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local st = state.peek(buf)
  if not st or not st.path then
    return false -- not a jove-managed buffer
  end
  local buf_seen = seen[buf]
  local has_store = st.outputs ~= nil and next(st.outputs) ~= nil
  if not has_store and not (buf_seen and next(buf_seen) ~= nil) then
    return false -- nothing session-side to persist (outputs OR tombstones)
  end

  -- Remember store hashes as "had outputs this session" (before the merge
  -- consumes them): a later output.clear() on any of them must tombstone.
  if has_store then
    for hash in pairs(st.outputs) do
      mark_seen(buf, hash)
    end
  end

  local nb = nil
  if bytes then
    local ok, parsed = pcall(vim.json.decode, bytes)
    if ok then
      nb = parsed
    end
  end
  nb = nb or st.json
  if type(nb) ~= "table" then
    return false
  end

  -- Copy before merge: merge_into mutates the notebook, and a later
  -- encode/write failure must not leave st.json diverged from disk.
  nb = vim.deepcopy(nb)

  -- Prune the seen-set to hashes still present in the fresh JSON: cells
  -- deleted from the buffer can never be tombstoned, and pruning keeps
  -- steady-state saves (nothing run/cleared) true no-ops.
  if buf_seen then
    local fresh = {}
    for _, c in ipairs(nb.cells or {}) do
      if c.cell_type == "code" and c.source ~= nil then
        fresh[cell.hash_source(c.source)] = true
      end
    end
    for hash in pairs(buf_seen) do
      if not fresh[hash] then
        buf_seen[hash] = nil
      end
    end
  end

  if M.merge_into(nb, st.outputs, buf_seen) == 0 then
    return false -- nothing matched, nothing to tombstone: real no-op
  end

  local ok, encoded = pcall(vim.json.encode, nb)
  if not ok then
    vim.notify("[jove] output export failed: cannot serialize notebook", vim.log.levels.WARN)
    return false
  end
  local wok, werr = atomic_write(st.path, encoded)
  if not wok then
    vim.notify("[jove] output export failed: " .. tostring(werr), vim.log.levels.WARN)
    return false
  end

  st.json = nb
  st.last_write = vim.fn.sha256(encoded)
  return true
end

---Parse the notebook's stored outputs (st.json from the last read/write)
---into the output store, matched by content hash, then replay them through
---output.import for rendering. No-op on non-jove buffers.
---
---Store reset semantics (deliberate asymmetry): when the disk copy HAS
---outputs (by_hash non-empty), previous store contents are cleared first --
---on reload the disk copy is the source of truth, so session-only outputs
---that were never persisted do not survive, and disk outputs win over stale
---session entries. When the disk copy has NO outputs (by_hash empty), the
---session store is left untouched: clearing it would only destroy
---in-session results that nothing on disk could restore. Hashes imported
---from disk are also recorded in the tombstone seen-set (they had outputs
---this session), so a later session clear persists as deletion.
---@param buf integer
function M.import(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local st = state.peek(buf)
  if not st or type(st.json) ~= "table" then
    return
  end

  local by_hash = {}
  for _, c in ipairs(st.json.cells or {}) do
    if
      c.cell_type == "code"
      and c.source ~= nil
      and type(c.outputs) == "table"
      and #c.outputs > 0
    then
      local hash = cell.hash_source(c.source)
      local raws = {}
      for _, nb_out in ipairs(c.outputs) do
        local params = M.to_raw(nb_out)
        if params then
          raws[#raws + 1] = params
        end
      end
      if #raws > 0 then
        by_hash[hash] = raws
        mark_seen(buf, hash)
      end
    end
  end

  local out = require("jove.output")
  if next(by_hash) ~= nil then
    out.clear(buf) -- reload semantics: disk wins over stale session entries
  end
  out.import(buf, by_hash)
end

return M

-- Notebook output persistence.
-- Session outputs (the store in state.get(buf).outputs, fed by bridge
-- `output` events) are merged into the .ipynb JSON on write, matched to
-- cells by content hash because jupytext py:percent round-trips drop cell ids. On read,
-- the inverse mapping replays the stored outputs back through output.import
--
-- Both directions convert between the two representations:
--   raw params   (bridge `output` event shape, PROTOCOL.md -- what the
--                 output store's `raw` lists hold, what mime.render draws)
--   nbformat v4  ({output_type = "stream"|"execute_result"|"display_data"|
--                 "error", ...})
local state = require("jove.state")
local cell = require("jove.cell")
local convert = require("jove.convert")

local M = {}

-- Track hashes with imported or exported outputs. If a tracked hash disappears
-- from the store, persist an empty output array so cleared outputs cannot return
-- on reload. Each buffer's set is removed on BufWipeout.
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
      -- The bridge tags execute_result events with the kernel execution
      -- count; unknown counts stay null (nbformat-valid).
      execution_count = type(params.execution_count) == "number" and params.execution_count
        or vim.NIL,
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

---Merge outputs into notebook code cells in place, matched by source hash.
---Session outputs replace disk outputs; tracked hashes cleared from the store
---get empty output arrays. Imported entries and unseen cells retain disk outputs.
---Run metadata supplies counts, including for cells that produced no output.
---Replaced or cleared outputs use null counts when metadata is unavailable or
---`persist_counts` is false; result-output counts follow the same rule.
---@param nb table?
---@param store table?  -- state.outputs: hash → {raw = {...}, from_disk?}
---@param seen_hashes table?  -- hash → true, "had outputs this session"
---@param meta table?  -- hash → { count?: integer, elapsed_ms?: number }
---@param persist_counts boolean?  -- write execution counts (default true)
---@return integer merged  -- number of cells replaced, tombstoned, or counted
function M.merge_into(nb, store, seen_hashes, meta, persist_counts)
  if type(nb) ~= "table" or type(nb.cells) ~= "table" then
    return 0
  end
  if persist_counts == nil then
    persist_counts = true
  end
  local merged = 0
  local counts = {} -- sha -> occurrences so far (duplicate suffixing, cell.lua)
  for _, c in ipairs(nb.cells) do
    if c.source ~= nil then
      local sha = cell.hash_source(c.source)
      counts[sha] = (counts[sha] or 0) + 1
      if c.cell_type == "code" then
        local hash = cell.dup_key(sha, counts[sha])
        local entry = store and store[hash]
        local m = persist_counts and meta and meta[hash] or nil
        local count = m and type(m.count) == "number" and m.count or nil
        -- Imported outputs are already on disk; rewriting them would lose counts.
        -- A cleared entry is absent from the store and still persists as a deletion.
        local from_disk = entry ~= nil and entry.from_disk == true
        if not from_disk and entry and type(entry.raw) == "table" and #entry.raw > 0 then
          local outs = {}
          for _, params in ipairs(entry.raw) do
            local out = M.to_nbformat(params)
            if out then
              if out.output_type == "execute_result" then
                -- Attribute the session count to the result output too; when
                -- counts are opted out, force null rather than the bridge count.
                if persist_counts then
                  if count ~= nil then
                    out.execution_count = count
                  end
                else
                  out.execution_count = vim.NIL
                end
              end
              outs[#outs + 1] = out
            end
          end
          c.outputs = outs
          c.execution_count = persist_counts and (count or vim.NIL) or vim.NIL
          merged = merged + 1
        elseif not from_disk and seen_hashes and seen_hashes[hash] then
          -- Session cleared this cell's outputs: persist the deletion
          -- (`outputs` is an array, so an empty Lua table encodes correctly).
          c.outputs = {}
          c.execution_count = persist_counts and (count or vim.NIL) or vim.NIL
          merged = merged + 1
        elseif count ~= nil and c.execution_count ~= count then
          -- A session run can update the count without producing new outputs.
          -- from_disk guards output replacement, not these newer run counts.
          c.execution_count = count
          merged = merged + 1
        end
      end
    end
  end
  return merged
end

---Merge session outputs into the file and update st.json and st.last_write
---to the merged bytes so FileChangedShell recognizes the write as our own.
---Call with fresh jupytext bytes from the write flow. Unmanaged buffers
---and unchanged merges are no-ops; failures issue a warning.
---@param buf integer
---@param bytes string?  Fresh notebook JSON from the write flow; nil falls
---    back to st.json.
---@return boolean ok    -- true when a merged write happened
---@return string? err   -- failure reason (nil for both success and no-op)
function M.export(buf, bytes)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local st = state.peek(buf)
  if not st or not st.path then
    return false -- not a jove-managed buffer
  end
  local buf_seen = seen[buf]
  local persist_counts = require("jove").config.persist_exec_counts ~= false
  local meta = persist_counts and st.exec and st.exec.meta or nil
  local has_meta = meta ~= nil and next(meta) ~= nil
  local has_store = st.outputs ~= nil and next(st.outputs) ~= nil
  if not has_store and not (buf_seen and next(buf_seen) ~= nil) and not has_meta then
    return false -- nothing session-side to persist (outputs OR tombstones OR meta)
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
    local counts = {}
    for _, c in ipairs(nb.cells or {}) do
      if c.source ~= nil then
        local sha = cell.hash_source(c.source)
        counts[sha] = (counts[sha] or 0) + 1
        if c.cell_type == "code" then
          fresh[cell.dup_key(sha, counts[sha])] = true
        end
      end
    end
    for hash in pairs(buf_seen) do
      if not fresh[hash] then
        buf_seen[hash] = nil
      end
    end
  end

  if M.merge_into(nb, st.outputs, buf_seen, meta, persist_counts) == 0 then
    return false -- nothing matched, nothing to tombstone: real no-op
  end

  local ok, encoded = pcall(vim.json.encode, nb)
  if not ok then
    vim.notify("[jove] output export failed: cannot serialize notebook", vim.log.levels.WARN)
    return false, "cannot serialize notebook"
  end
  local wok, werr = convert.atomic_write(st.path, encoded)
  if not wok then
    vim.notify("[jove] output export failed: " .. tostring(werr), vim.log.levels.WARN)
    return false, tostring(werr)
  end

  st.json = nb
  st.last_write = vim.fn.sha256(encoded)

  -- Tombstones were persisted: forget hashes that have no store entry left,
  -- so steady-state saves after a clear become true no-ops (a later re-run
  -- re-adds the hash via the normal export path). Hashes with live session
  -- outputs stay seen — clearing THEM later must still tombstone.
  if buf_seen then
    for hash in pairs(buf_seen) do
      if not (st.outputs and st.outputs[hash]) then
        buf_seen[hash] = nil
      end
    end
  end
  return true
end

---Parse the notebook's stored outputs (st.json from the last read/write)
---into the output store, matched by content hash, then replay them through
---output.import for rendering. No-op on non-jove buffers.
---
---Disk is authoritative: the session store is reset even when the disk copy
---has no outputs at all (an empty output set on disk means the cells ran
---clean or were cleared elsewhere — stale session results must not survive
---the reload and sneak back into the file on the next save). The tombstone
---set is likewise rebuilt from what disk actually holds, and session
---execution counts are dropped: the disk counts are the truth now.
---@param buf integer
function M.import(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local st = state.peek(buf)
  if not st or type(st.json) ~= "table" then
    return
  end

  local by_hash = {}
  local fresh_seen = {}
  local counts = {} -- sha -> occurrences so far (duplicate suffixing, cell.lua)
  for _, c in ipairs(st.json.cells or {}) do
    if c.source ~= nil then
      local sha = cell.hash_source(c.source)
      counts[sha] = (counts[sha] or 0) + 1
      if c.cell_type == "code" and type(c.outputs) == "table" and #c.outputs > 0 then
        local raws = {}
        for _, nb_out in ipairs(c.outputs) do
          local params = M.to_raw(nb_out)
          if params then
            raws[#raws + 1] = params
          end
        end
        if #raws > 0 then
          local hash = cell.dup_key(sha, counts[sha])
          by_hash[hash] = raws
          fresh_seen[hash] = true
        end
      end
    end
  end

  -- Reset the tombstone set to what this disk state carries: clears and runs
  -- from before the reload must not leak into post-reload saves. Imported
  -- hashes stay tracked so clearing them later persists the deletion.
  seen[buf] = fresh_seen

  require("jove.execute").reset(buf)

  local out = require("jove.output")
  out.clear(buf, nil, { skip_dirty = true }) -- disk state replaces session state
  out.import(buf, by_hash)
end

return M

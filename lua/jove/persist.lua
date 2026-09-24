-- Notebook output persistence.
local state = require("jove.state")
local cell = require("jove.cell")
local convert = require("jove.convert")

local M = {}

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

---@param t any
---@return table
local function as_dict(t)
  if type(t) == "table" and next(t) ~= nil then
    return t
  end
  return vim.empty_dict()
end

---@param v any
---@return string
local function text_of(v)
  if type(v) == "table" then
    return table.concat(v, "")
  end
  return type(v) == "string" and v or ""
end

---@param data any
---@return table<string, string>
local function bundle_of(data)
  local out = {}
  for mime, v in pairs(data or {}) do
    out[mime] = text_of(v)
  end
  return out
end

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
      traceback = params.traceback or {},
    }
  end
  return nil
end

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
      traceback = nb.traceback or {},
    }
  end
  return nil
end

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
  local counts = {}
  for _, c in ipairs(nb.cells) do
    if c.source ~= nil then
      local sha = cell.hash_source(c.source)
      counts[sha] = (counts[sha] or 0) + 1
      if c.cell_type == "code" then
        local hash = cell.dup_key(sha, counts[sha])
        local entry = store and store[hash]
        local m = persist_counts and meta and meta[hash] or nil
        local count = m and type(m.count) == "number" and m.count or nil
        local from_disk = entry ~= nil and entry.from_disk == true
        if not from_disk and entry and type(entry.raw) == "table" and #entry.raw > 0 then
          local outs = {}
          for _, params in ipairs(entry.raw) do
            local out = M.to_nbformat(params)
            if out then
              if out.output_type == "execute_result" then
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
          c.outputs = {}
          c.execution_count = persist_counts and (count or vim.NIL) or vim.NIL
          merged = merged + 1
        elseif count ~= nil and c.execution_count ~= count then
          c.execution_count = count
          merged = merged + 1
        end
      end
    end
  end
  return merged
end

---@param buf integer
---@param bytes string?  Fresh notebook JSON from the write flow; nil falls
---    back to st.json.
---@return boolean ok    -- true when a merged write happened
---@return string? err   -- failure reason (nil for both success and no-op)
function M.export(buf, bytes)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local st = state.peek(buf)
  if not st or not st.path then
    return false
  end
  local buf_seen = seen[buf]
  local persist_counts = require("jove").config.persist_exec_counts ~= false
  local meta = persist_counts and st.exec and st.exec.meta or nil
  local has_meta = meta ~= nil and next(meta) ~= nil
  local has_store = st.outputs ~= nil and next(st.outputs) ~= nil
  if not has_store and not (buf_seen and next(buf_seen) ~= nil) and not has_meta then
    return false
  end

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

  nb = vim.deepcopy(nb)

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
    return false
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

  if buf_seen then
    for hash in pairs(buf_seen) do
      if not (st.outputs and st.outputs[hash]) then
        buf_seen[hash] = nil
      end
    end
  end
  return true
end

---@param buf integer
function M.import(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local st = state.peek(buf)
  if not st or type(st.json) ~= "table" then
    return
  end

  local by_hash = {}
  local fresh_seen = {}
  local counts = {}
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

  seen[buf] = fresh_seen

  require("jove.execute").reset(buf)

  local out = require("jove.output")
  out.clear(buf, nil, { skip_dirty = true })
  out.import(buf, by_hash)
end

return M

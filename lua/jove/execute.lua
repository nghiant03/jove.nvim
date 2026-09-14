-- execute.lua: per-buffer FIFO execution queue over the buffer's one kernel
-- (PLAN.md Phase 4). Direct code send -- no visual-mode hack (fixes P4) --
-- and one cached cell.all pass per batch (fixes P7).
--
-- Queue semantics (strictly serial):
--   * enqueue marks items "queued"; the pump starts the head item ("running")
--     and the next item only starts once the previous execute's RESPONSE
--     arrives (ok or error; bridge death fails pending via bridge.lua).
--   * the bridge cell key is the cell's content hash (cell.hash) -- the
--     output-routing key per PROTOCOL.md. Selections route to the hash of the
--     cell containing the selection start.
--   * no kernel at enqueue time: notify + drop the queue (nothing stale runs
--     when a kernel later appears). Kernel dying mid-queue: in-flight items
--     fail with status "error" (the bridge answers kernel_not_running) and
--     the queue drains with visible errors; queued-but-not-started items
--     after M.interrupt stay queued (interrupt clears the shell channel, the
--     next response re-pumps).
--
-- Kernel-handle subscription contract: listeners live on the bridge handle,
-- which survives bridge respawn (handlers are per-handle in bridge.lua) but
-- is REPLACED by kernel.select/shutdown. ensure_attached() therefore
-- re-subscribes whenever state.get(buf).kernel is a different entry than the
-- last one attached; it is called lazily from enqueue, so no wiring outside
-- this module is needed.
local state = require("jove.state")
local cell = require("jove.cell")

local M = {}

-- Output seam: the output UI is built in a parallel phase (jove.output).
-- Duck-typed contract: clear(buf, cell_hash), push(buf, cell_hash, params).
-- All calls are pcall-guarded; tests inject a stub via execute._output.
M._output = function()
  local ok, m = pcall(require, "jove.output")
  return ok and m or nil
end

local NO_KERNEL_MSG = "No kernel — run :JoveInitKernel"

---@param buf integer
---@return integer
local function norm_buf(buf)
  return buf == 0 and vim.api.nvim_get_current_buf() or buf
end

local pump -- forward declaration (ensure_attached's closures call it)

---@param st jove.BufferState
---@return table exec
local function ensure_exec(st)
  local exec = st.exec
  if not exec then
    exec = {
      queue = {}, -- jove.ExecItem[]
      running = nil, -- jove.ExecItem currently in flight
      status = {}, -- [hash] -> "queued"|"running"|"ok"|"error"
      status_cbs = {}, -- fn(hash, status)
      attached = nil, -- kernel entry whose bridge we subscribed
      unsubs = nil, -- unsubscribe fns for the attached bridge
      start_hr = {}, -- [hash] -> hrtime at request send (elapsed source)
      meta = {}, -- [hash] -> { count?: integer, elapsed_ms?: number }
    }
    st.exec = exec
  end
  return exec
end

---Record per-run metadata for a cell (count from the bridge, elapsed from
---hrtime). Only numeric values are stored; absent data leaves prior values
---(or nil) intact.
---@param exec table?
---@param hash string
---@param count integer?
---@param elapsed_ms number?
local function set_meta(exec, hash, count, elapsed_ms)
  if not exec then
    return
  end
  exec.meta = exec.meta or {}
  local m = exec.meta[hash] or {}
  if type(count) == "number" then
    m.count = count
  end
  if type(elapsed_ms) == "number" then
    m.elapsed_ms = elapsed_ms
  end
  exec.meta[hash] = m
end

---@param buf integer
---@param hash string
---@param status string
local function set_status(buf, hash, status)
  local st = state.get(buf)
  if not st.exec then
    return
  end
  st.exec.status[hash] = status
  for _, fn in ipairs(st.exec.status_cbs) do
    pcall(fn, hash, status)
  end
end

---(Re)subscribe this buffer's execute listeners to its current kernel entry.
---No-op when already attached to it. Safe across kernel replacement and
---bridge respawn (see module comment).
---@param buf integer
---@return table? kernel_entry
local function ensure_attached(buf)
  local st = state.get(buf)
  local exec = ensure_exec(st)
  local k = st.kernel
  if exec.attached == k then
    return k
  end
  if exec.unsubs then
    for _, unsub in ipairs(exec.unsubs) do
      pcall(unsub)
    end
    exec.unsubs = nil
  end
  exec.attached = nil
  if not k or not k.bridge then
    return nil
  end

  local function on_output(params)
    if type(params) ~= "table" or type(params.cell) ~= "string" then
      return
    end
    -- The bridge tags execute_result events with the kernel execution count;
    -- record it even when the shell reply (which may also carry it) is late.
    if params.kind == "execute_result" and type(params.execution_count) == "number" then
      local st2 = state.peek(buf)
      set_meta(st2 and st2.exec, params.cell, params.execution_count, nil)
    end
    local out = M._output()
    if out then
      pcall(out.push, buf, params.cell, params)
    end
  end

  local function on_kernel_status(params)
    -- Kernel death clears the in-flight item immediately (its execute will
    -- also fail with kernel_not_running; the status transition is idempotent
    -- because the pump slot is already empty).
    if type(params) == "table" and params.status == "dead" then
      -- Peek (not get): a dead-event dispatch racing BufWipeout must not
      -- resurrect a phantom registry entry for a wiped buffer.
      local st2 = state.peek(buf)
      local exec2 = st2 and st2.exec
      if exec2 and exec2.running then
        local item = exec2.running
        exec2.running = nil
        set_status(buf, item.hash, "error")
        pump(buf)
      end
    end
  end

  exec.unsubs = {
    k.bridge:on("output", on_output),
    k.bridge:on("kernel_status", on_kernel_status),
  }
  exec.attached = k
  return k
end

---Start the next queued item when idle. No-op when empty/busy.
---@param buf integer
function pump(buf)
  local st = state.peek(buf)
  local exec = st and st.exec
  if not exec or exec.running then
    return
  end
  local item = exec.queue[1]
  if not item then
    return
  end
  local k = st.kernel
  if not (k and k.name and k.bridge and k.bridge:is_alive()) then
    -- Kernel vanished mid-queue: drop the rest loudly (enqueue-time checks
    -- already cover the "never had a kernel" case). Dropped items get
    -- status "error" so no gutter sign is stuck on "queued" forever.
    for _, dropped in ipairs(exec.queue) do
      set_status(buf, dropped.hash, "error")
    end
    exec.queue = {}
    vim.notify(NO_KERNEL_MSG, vim.log.levels.WARN)
    return
  end

  table.remove(exec.queue, 1)
  exec.running = item
  set_status(buf, item.hash, "running")
  local out = M._output()
  if out then
    pcall(out.clear, buf, item.hash) -- drop stale outputs from earlier runs
  end

  -- Execute has NO timeout (the cell may run for minutes); disable the
  -- bridge's default explicitly. The reply may outlive the buffer (wiped
  -- mid-run): peek the state and bail when the registry entry is gone --
  -- state.get here would resurrect a phantom entry.
  exec.start_hr[item.hash] = vim.uv.hrtime()
  k.bridge:request("execute", { code = item.code, cell = item.hash }, function(result, err)
    local st2 = state.peek(buf)
    local exec2 = st2 and st2.exec
    if exec2 then
      -- Elapsed is measured at the response handler boundary (covers queue
      -- wait excluded: start_hr is stamped just before the send).
      local start = exec2.start_hr and exec2.start_hr[item.hash]
      local elapsed = start and (vim.uv.hrtime() - start) / 1e6 or nil
      if exec2.start_hr then
        exec2.start_hr[item.hash] = nil
      end
      local count = (not err and type(result) == "table") and result.execution_count or nil
      set_meta(exec2, item.hash, count, elapsed)
      if exec2.running == item then
        exec2.running = nil
        local status = (not err and type(result) == "table" and result.status == "ok") and "ok"
          or "error"
        set_status(buf, item.hash, status)
      end
      -- The execution count may only arrive with this reply (print-only cells
      -- emit no execute_result output event): re-render so the inline `Out[n]`
      -- header picks it up.
      if out and out.refresh_cell then
        pcall(out.refresh_cell, buf, item.hash)
      end
    end
    pump(buf)
  end, { timeout_ms = false })
end

---@param buf integer
---@param items jove.ExecItem[]
local function enqueue(buf, items)
  if #items == 0 then
    return
  end
  local kernel = require("jove.kernel")
  if not kernel.available(buf) then
    local st = state.get(buf)
    if st.exec then
      -- Dropped items get status "error" so no gutter sign is stuck on
      -- "queued" forever.
      for _, dropped in ipairs(st.exec.queue) do
        set_status(buf, dropped.hash, "error")
      end
      st.exec.queue = {} -- drop queued items too; nothing stale runs later
    end
    vim.notify(NO_KERNEL_MSG, vim.log.levels.WARN)
    return
  end
  local st = state.get(buf)
  local exec = ensure_exec(st)
  ensure_attached(buf)
  for _, item in ipairs(items) do
    set_status(buf, item.hash, "queued")
    table.insert(exec.queue, item)
  end
  pump(buf)
end

---Cell body lines (header excluded), or nil for an empty body.
---@param buf integer
---@param c jove.Cell
---@return string?
local function cell_code(buf, c)
  local body_start = c.header and c.header + 1 or c.start_lnum
  if body_start > c.end_lnum then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(buf, body_start - 1, c.end_lnum, false)
  return table.concat(lines, "\n")
end

---Run the cell containing `lnum` (default: cursor).
---@param buf integer
---@param lnum integer?
function M.run_cell(buf, lnum)
  buf = norm_buf(buf)
  if not lnum then
    lnum = vim.api.nvim_win_get_cursor(0)[1]
  end
  local c = cell.at(buf, lnum)
  if not c then
    return
  end
  local code = cell_code(buf, c)
  if not code then
    return
  end
  enqueue(buf, { { hash = c.hash, code = code, lnum = c.start_lnum } })
end

---Run all code cells above (and including, per the historical contract) the
---cell at `lnum` (default: cursor). One cell.all pass.
---@param buf integer
---@param lnum integer?
function M.run_above(buf, lnum)
  buf = norm_buf(buf)
  if not lnum then
    lnum = vim.api.nvim_win_get_cursor(0)[1]
  end
  local items = {}
  for _, c in ipairs(cell.all(buf)) do
    if c.kind == "code" and c.header and c.header <= lnum then
      local code = cell_code(buf, c)
      if code then
        items[#items + 1] = { hash = c.hash, code = code, lnum = c.start_lnum }
      end
    end
  end
  enqueue(buf, items)
end

---Run every code cell in the buffer. One cell.all pass.
---@param buf integer
function M.run_all(buf)
  buf = norm_buf(buf)
  local items = {}
  for _, c in ipairs(cell.all(buf)) do
    if c.kind == "code" then
      local code = cell_code(buf, c)
      if code then
        items[#items + 1] = { hash = c.hash, code = code, lnum = c.start_lnum }
      end
    end
  end
  enqueue(buf, items)
end

---Run the current visual selection's lines as one unit. Outputs route to the
---cell containing the selection start (its content hash is the bridge cell
---key); a selection outside any cell falls back to the key "selection".
---Intended to be called with visual marks active (mapped in x-mode).
---@param buf integer
function M.run_selection(buf)
  buf = norm_buf(buf)
  -- Buffer-local visual marks: readable without the buffer being current.
  local s = vim.api.nvim_buf_get_mark(buf, "<")
  local e = vim.api.nvim_buf_get_mark(buf, ">")
  local l1, l2 = s[1], e[1]
  if l2 < l1 then
    l1, l2 = l2, l1
  end
  local lines = vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false)
  if #lines == 0 then
    return
  end
  -- Charwise single-line selection: slice the columns (get_mark cols are
  -- 0-based).
  local c1, c2 = s[2] + 1, e[2] + 1
  if l1 == l2 and c1 > 0 and c2 > 0 and c1 ~= c2 then
    local cs, ce = math.min(c1, c2), math.max(c1, c2)
    lines[1] = lines[1]:sub(cs, ce)
  end
  local containing = cell.at(buf, l1)
  local hash = containing and containing.hash or "selection"
  enqueue(buf, { { hash = hash, code = table.concat(lines, "\n"), lnum = l1 } })
end

---Run the cell at the cursor, then move the cursor to the next cell header.
---@param buf integer
function M.run_cell_and_advance(buf)
  buf = norm_buf(buf)
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  M.run_cell(buf, cur)
  local next_lnum = cell.next(buf, cur)
  if next_lnum then
    vim.api.nvim_win_set_cursor(0, { next_lnum, 0 })
  end
end

---Forward to the kernel's interrupt. Queued-but-not-started items remain
---queued (documented choice): interrupt clears the shell channel; the
---in-flight execute still returns (typically status "error" with the
---KeyboardInterrupt) and the pump continues.
---@param buf integer
function M.interrupt(buf)
  require("jove.kernel").interrupt(buf)
end

---Subscribe to per-cell status transitions; fn(hash, status). Returns an
---unsubscribe function.
---@param buf integer
---@param fn fun(hash: string, status: "queued"|"running"|"ok"|"error")
---@return fun()
function M.on_status(buf, fn)
  local st = state.get(buf)
  local exec = ensure_exec(st)
  table.insert(exec.status_cbs, fn)
  return function()
    for i, h in ipairs(exec.status_cbs) do
      if h == fn then
        table.remove(exec.status_cbs, i)
        break
      end
    end
  end
end

---Current status of a cell hash: "queued"|"running"|"ok"|"error"|nil.
---@param buf integer
---@param hash string
---@return string?
function M.status(buf, hash)
  local st = state.peek(norm_buf(buf))
  return st and st.exec and st.exec.status[hash] or nil
end

---Per-run metadata recorded for a cell: { count?: integer, elapsed_ms?: number }
---(nil until the cell has run and the bridge supplied the data).
---@param buf integer
---@param hash string
---@return { count: integer?, elapsed_ms: number? }?
function M.meta(buf, hash)
  local st = state.peek(norm_buf(buf))
  return st and st.exec and st.exec.meta and st.exec.meta[hash] or nil
end

---Number of queued (not yet running) items.
---@param buf integer
---@return integer
function M.queue_len(buf)
  local st = state.peek(norm_buf(buf))
  return (st and st.exec) and #st.exec.queue or 0
end

return M

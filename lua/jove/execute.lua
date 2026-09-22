-- Buffer FIFO execution queue.

local cell = require("jove.cell")
local state = require("jove.state")

local M = {}
local next_run = 0

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

local pump

---@param st jove.BufferState
---@return table exec
local function ensure_exec(st)
  local exec = st.exec
  if not exec then
    exec = {
      queue = {},
      running = nil,
      status = {},
      status_cbs = {},
      attached = nil,
      unsubs = nil,
      start_hr = {},
      meta = {},
    }
    st.exec = exec
  end
  exec.routes = exec.routes or {}
  exec.latest = exec.latest or {}
  return exec
end

function M.reset(buf)
  local st = state.peek(buf)
  local old = st and st.exec
  if not old then
    return
  end
  for _, unsub in ipairs(old.unsubs or {}) do
    pcall(unsub)
  end
  st.exec = nil
  local fresh = ensure_exec(st)
  fresh.status_cbs = old.status_cbs or {}
end

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
    local current = state.peek(buf)
    if not current or current.exec ~= exec or current.kernel ~= k then
      return
    end
    local hash = exec.routes[params.cell]
    if not hash or exec.latest[hash] ~= params.cell then
      return
    end
    if params.kind == "execute_result" and type(params.execution_count) == "number" then
      local st2 = state.peek(buf)
      set_meta(st2 and st2.exec, hash, params.execution_count, nil)
    end
    local out = M._output()
    if out then
      pcall(out.push, buf, hash, params, { defer = true })
    end
  end

  local function on_kernel_status(params)
    if type(params) == "table" and params.status == "dead" then
      local st2 = state.peek(buf)
      local exec2 = st2 and st2.exec
      if exec2 == exec and st2.kernel == k and exec2.running then
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
    pcall(out.clear, buf, item.hash)
  end

  exec.start_hr[item.hash] = vim.uv.hrtime()
  next_run = next_run + 1
  local wire = item.hash .. ":run:" .. next_run
  local previous = exec.latest[item.hash]
  if previous then
    exec.routes[previous] = nil
  end
  exec.latest[item.hash] = wire
  exec.routes[wire] = item.hash
  k.bridge:request("execute", { code = item.code, cell = wire }, function(result, err)
    local st2 = state.peek(buf)
    local exec2 = st2 and st2.exec
    if exec2 ~= exec then
      return
    end
    if st2.kernel ~= k then
      if exec.running == item then
        exec.running = nil
        set_status(buf, item.hash, "error")
        for _, queued in ipairs(exec.queue) do
          set_status(buf, queued.hash, "error")
        end
        exec.queue = {}
        vim.notify(NO_KERNEL_MSG, vim.log.levels.WARN)
      end
      exec.routes[wire] = nil
      return
    end
    vim.defer_fn(function()
      exec.routes[wire] = nil
      if exec.latest[item.hash] == wire then
        exec.latest[item.hash] = nil
      end
    end, 10000)
    if exec2 then
      local start = exec2.start_hr and exec2.start_hr[item.hash]
      local elapsed = start and (vim.uv.hrtime() - start) / 1e6 or nil
      if exec2.start_hr then
        exec2.start_hr[item.hash] = nil
      end
      local count = (not err and type(result) == "table") and result.execution_count or nil
      set_meta(exec2, item.hash, count, elapsed)
      if count ~= nil and out and out.mark_dirty then
        pcall(out.mark_dirty, buf)
      end
      if exec2.running == item then
        exec2.running = nil
        local status = (not err and type(result) == "table" and result.status == "ok") and "ok"
          or "error"
        set_status(buf, item.hash, status)
      end
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
      for _, dropped in ipairs(st.exec.queue) do
        set_status(buf, dropped.hash, "error")
      end
      st.exec.queue = {}
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

---@param buf integer
function M.run_selection(buf)
  buf = norm_buf(buf)
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
  local c1, c2 = s[2] + 1, e[2] + 1
  if l1 == l2 and c1 > 0 and c2 > 0 and c1 ~= c2 then
    local cs, ce = math.min(c1, c2), math.max(c1, c2)
    lines[1] = lines[1]:sub(cs, ce)
  end
  local containing = cell.at(buf, l1)
  local hash = containing and containing.hash or "selection"
  enqueue(buf, { { hash = hash, code = table.concat(lines, "\n"), lnum = l1 } })
end

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

---@param buf integer
function M.interrupt(buf)
  require("jove.kernel").interrupt(buf)
end

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

---@param buf integer
---@param hash string
---@return string?
function M.status(buf, hash)
  local st = state.peek(norm_buf(buf))
  return st and st.exec and st.exec.status[hash] or nil
end

---@param buf integer
---@param hash string
---@return { count: integer?, elapsed_ms: number? }?
function M.meta(buf, hash)
  local st = state.peek(norm_buf(buf))
  return st and st.exec and st.exec.meta and st.exec.meta[hash] or nil
end

---@param buf integer
---@return { hash: string, lnum: integer }?
function M.running(buf)
  local st = state.peek(norm_buf(buf))
  local item = st and st.exec and st.exec.running or nil
  return item and { hash = item.hash, lnum = item.lnum } or nil
end

---@param buf integer
---@return integer
function M.queue_len(buf)
  local st = state.peek(norm_buf(buf))
  return (st and st.exec) and #st.exec.queue or 0
end

return M

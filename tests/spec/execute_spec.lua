-- Inject a bridge through state.get(buf).kernel.bridge to control replies and events.
local MiniTest = require("mini.test")
local state = require("jove.state")
local cell = require("jove.cell")
local execute = require("jove.execute")
local ui = require("jove.ui")

local T = MiniTest.new_set()

local LINES = { "# %% a", "x = 1", "# %% b", "y = 2", "# %% c", "z = 3" }

---@param cond any
local function expect_truthy(cond)
  MiniTest.expect.equality(cond == true, true)
end

---@return table  -- fake bridge: records requests, replays events by hand
local function fake_bridge()
  local br = { requests = {}, handlers = {}, unsubs = 0, alive = true }
  function br:request(method, params, cb, opts)
    table.insert(self.requests, { method = method, params = params, cb = cb, opts = opts })
  end
  function br:on(event, fn)
    self.handlers[event] = self.handlers[event] or {}
    table.insert(self.handlers[event], fn)
    self.unsubs = self.unsubs + 1
    return function()
      br.unsubs = br.unsubs - 1
    end
  end
  function br:is_alive()
    return br.alive
  end
  function br:is_ready()
    return true
  end
  function br:stop() end
  ---Dispatch an event to subscribed handlers (synchronously, like the real
  ---bridge's scheduled dispatch would from the test's perspective).
  function br:emit(event, params)
    for _, fn in ipairs(self.handlers[event] or {}) do
      fn(params)
    end
  end
  function br:reply(result, err)
    local req = table.remove(self.requests, 1)
    req.cb(result, err)
  end
  return br
end

---@param bridge table
---@param buf integer
local function inject_kernel(bridge, buf)
  state.get(buf).kernel = { bridge = bridge, name = "python3", status = "idle" }
end

local created, real_notify, real_output, notes

local function make_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  state.get(buf).path = "fake.ipynb"
  created[#created + 1] = buf
  return buf
end

T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      created, notes = {}, {}
      real_notify, real_output = vim.notify, execute._output
      vim.notify = function(msg, level)
        table.insert(notes, { msg = msg, level = level })
      end
      execute._output = function()
        return nil -- default: output module absent
      end
    end,
    post_case = function()
      execute._output = real_output
      vim.notify = real_notify
      for _, buf in ipairs(created) do
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end,
  },
})

---First code cell hashes for LINES (a/b/c), via the real cell model.
---@param buf integer
---@return string, string, string
local function hashes(buf)
  local h = {}
  for i, lnum in ipairs({ 1, 3, 5 }) do
    h[i] = cell.at(buf, lnum).hash
  end
  return h[1], h[2], h[3]
end

T["queue"] = MiniTest.new_set()

T["queue"]["runs serially: next request only after previous reply"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  inject_kernel(br, buf)

  execute.run_all(buf)
  MiniTest.expect.equality(#br.requests, 1)
  MiniTest.expect.equality(execute.queue_len(buf), 2)

  br:reply({ status = "ok" })
  MiniTest.expect.equality(#br.requests, 1)
  MiniTest.expect.equality(execute.queue_len(buf), 1)

  br:reply({ status = "ok" })
  MiniTest.expect.equality(#br.requests, 1)
  MiniTest.expect.equality(execute.queue_len(buf), 0)

  br:reply({ status = "ok" })
  MiniTest.expect.equality(#br.requests, 0)
  MiniTest.expect.equality(execute.queue_len(buf), 0)
end

T["queue"]["sends the cell BODY (header excluded), keyed by content hash"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  inject_kernel(br, buf)
  local h1, _, _ = hashes(buf)

  execute.run_cell(buf, 1)
  MiniTest.expect.equality(#br.requests, 1)
  local req = br.requests[1]
  MiniTest.expect.equality(req.method, "execute")
  MiniTest.expect.equality(req.params.code, "x = 1") -- direct send, no header
  MiniTest.expect.equality(req.params.cell, h1) -- output-routing key
  MiniTest.expect.equality(req.opts.timeout_ms, false)
end

T["queue"]["no kernel: notifies and drops the queue"] = function()
  local buf = make_buffer(LINES)
  execute.run_all(buf) -- nothing queued: no kernel at all
  MiniTest.expect.equality(execute.queue_len(buf), 0)
  MiniTest.expect.equality(#notes, 1)
  expect_truthy(notes[1].msg:find("No kernel", 1, true) ~= nil)

  -- Kernel attached but its bridge is dead: same treatment.
  local br = fake_bridge()
  br.alive = false
  inject_kernel(br, buf)
  execute.run_all(buf)
  MiniTest.expect.equality(execute.queue_len(buf), 0)
  MiniTest.expect.equality(#notes, 2)
end

T["queue"]["kernel gone mid-queue: remaining items dropped as error"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  inject_kernel(br, buf)
  local _, h2, h3 = hashes(buf)
  execute.run_all(buf)

  -- Kernel handle disappears (shutdown/replaced and not yet re-attached).
  state.get(buf).kernel = nil
  br:reply({ status = "ok" }) -- first finishes; pump sees no kernel
  MiniTest.expect.equality(execute.queue_len(buf), 0)
  MiniTest.expect.equality(notes[1].msg:find("No kernel", 1, true) ~= nil, true)
  MiniTest.expect.equality(execute.status(buf, h2), "error")
  MiniTest.expect.equality(execute.status(buf, h3), "error")
end

T["queue"]["no-kernel enqueue: already-queued items dropped as error"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  inject_kernel(br, buf)
  local _, h2, h3 = hashes(buf)
  execute.run_all(buf)
  MiniTest.expect.equality(execute.status(buf, h2), "queued")

  -- Kernel becomes unavailable; another run attempt drops the queue...
  br.alive = false
  execute.run_all(buf)
  MiniTest.expect.equality(execute.queue_len(buf), 0)
  MiniTest.expect.equality(execute.status(buf, h2), "error")
  MiniTest.expect.equality(execute.status(buf, h3), "error")
end

T["queue"]["reply after wipe leaves no phantom state entry"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  inject_kernel(br, buf)
  execute.run_cell(buf, 1)

  -- Wipe the buffer mid-run (state registry cleared by BufWipeout)...
  vim.api.nvim_buf_delete(buf, { force = true })
  MiniTest.expect.equality(state.peek(buf) == nil, true)

  -- ...then deliver the reply: must not resurrect the registry entry.
  br:reply({ status = "ok" })
  MiniTest.expect.equality(state.peek(buf) == nil, true)
end

T["status"] = MiniTest.new_set()

T["status"]["queued -> running -> ok, per hash"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  inject_kernel(br, buf)
  local h1, h2, h3 = hashes(buf)

  execute.run_all(buf)
  MiniTest.expect.equality(execute.status(buf, h1), "running")
  MiniTest.expect.equality(execute.status(buf, h2), "queued")
  MiniTest.expect.equality(execute.status(buf, h3), "queued")

  br:reply({ status = "ok" })
  MiniTest.expect.equality(execute.status(buf, h1), "ok")
  MiniTest.expect.equality(execute.status(buf, h2), "running")

  br:reply({ status = "error", ename = "E", evalue = "boom" })
  MiniTest.expect.equality(execute.status(buf, h2), "error")
  MiniTest.expect.equality(execute.status(buf, h3), "running")

  br:reply({ status = "ok" })
  MiniTest.expect.equality(execute.status(buf, h3), "ok")
end

T["status"]["error response marks the cell error and keeps pumping"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  inject_kernel(br, buf)
  local h1, _, _ = hashes(buf)

  execute.run_all(buf)
  br:reply(nil, { code = "kernel_not_running", message = "start a kernel first" })
  MiniTest.expect.equality(execute.status(buf, h1), "error")
  MiniTest.expect.equality(#br.requests, 1)
end

T["status"]["kernel_status dead clears the in-flight item"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  inject_kernel(br, buf)
  local h1, _, _ = hashes(buf)

  execute.run_all(buf)
  MiniTest.expect.equality(execute.status(buf, h1), "running")
  br:emit("kernel_status", { status = "dead" })
  MiniTest.expect.equality(execute.status(buf, h1), "error")
  MiniTest.expect.equality(execute.queue_len(buf), 1)
end

T["status"]["on_status callback fires and unsubscribes"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  inject_kernel(br, buf)

  local seen = {}
  local unsub = execute.on_status(buf, function(hash, status)
    table.insert(seen, { hash = hash, status = status })
  end)
  execute.run_cell(buf, 1)
  br:reply({ status = "ok" })
  MiniTest.expect.equality(#seen, 3) -- queued + running + ok
  MiniTest.expect.equality(seen[1].status, "queued")
  MiniTest.expect.equality(seen[2].status, "running")
  MiniTest.expect.equality(seen[3].status, "ok")

  unsub()
  execute.run_cell(buf, 1)
  br:reply({ status = "ok" })
  MiniTest.expect.equality(#seen, 3)
  MiniTest.expect.equality(seen[3].status, "ok")
end

T["meta"] = MiniTest.new_set()

T["meta"]["response count + elapsed recorded per hash"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  inject_kernel(br, buf)
  local h1 = hashes(buf)

  execute.run_cell(buf, 1)
  br:reply({ status = "ok", execution_count = 7 })

  local m = execute.meta(buf, h1)
  MiniTest.expect.equality(m.count, 7)
  MiniTest.expect.equality(type(m.elapsed_ms), "number")
  expect_truthy(m.elapsed_ms >= 0)
end

T["meta"]["execute_result output event carries the count before the reply"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  inject_kernel(br, buf)
  local h1 = hashes(buf)

  execute.run_cell(buf, 1)
  br:emit("output", {
    cell = h1,
    kind = "execute_result",
    execution_count = 3,
    mime = { ["text/plain"] = "1" },
  })
  MiniTest.expect.equality(execute.meta(buf, h1).count, 3)

  -- A later reply without a count must not clobber the recorded one.
  br:reply({ status = "ok" })
  MiniTest.expect.equality(execute.meta(buf, h1).count, 3)
end

T["meta"]["unknown count stays nil; elapsed still recorded (json shape)"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  inject_kernel(br, buf)
  local h1 = hashes(buf)

  execute.run_cell(buf, 1)
  br:reply({ status = "ok" })

  local m = execute.meta(buf, h1)
  MiniTest.expect.equality(m.count == nil, true)
  MiniTest.expect.equality(type(m.elapsed_ms), "number")
  local encoded = vim.json.encode(m)
  expect_truthy(encoded:find('"elapsed_ms"', 1, true) ~= nil)
  expect_truthy(encoded:find('"count"', 1, true) == nil)
end

T["output seam"] = MiniTest.new_set()

T["output seam"]["clear on running, push on output event"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  inject_kernel(br, buf)
  local h1, _, _ = hashes(buf)

  local calls = { clear = {}, push = {} }
  execute._output = function()
    return {
      clear = function(b, hash)
        table.insert(calls.clear, { buf = b, hash = hash })
      end,
      push = function(b, hash, params)
        table.insert(calls.push, { buf = b, hash = hash, params = params })
      end,
    }
  end

  execute.run_cell(buf, 1)
  MiniTest.expect.equality(#calls.clear, 1)
  MiniTest.expect.equality(calls.clear[1].hash, h1)

  br:emit(
    "output",
    { cell = h1, kind = "stream", name = "stdout", mime = { ["text/plain"] = "1" } }
  )
  MiniTest.expect.equality(#calls.push, 1)
  MiniTest.expect.equality(calls.push[1].hash, h1)
  MiniTest.expect.equality(calls.push[1].params.kind, "stream")

  br:reply({ status = "ok" })
end

T["output seam"]["absent module never breaks the queue"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  inject_kernel(br, buf)
  execute._output = function()
    return nil
  end
  execute.run_all(buf)
  br:emit("output", { cell = "x", kind = "stream", mime = {} })
  br:reply({ status = "ok" })
  br:reply({ status = "ok" })
  br:reply({ status = "ok" })
  MiniTest.expect.equality(#br.requests, 0)
  MiniTest.expect.equality(execute.status(buf, cell.at(buf, 1).hash), "ok")
end

T["batch"] = MiniTest.new_set()

T["batch"]["run_above enqueues code cells up to and including the cursor"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  inject_kernel(br, buf)
  local h1, h2, h3 = hashes(buf)

  execute.run_above(buf, 5) -- Cursor on cell c's header.
  -- run_above includes a code cell whose header is at the cursor.
  MiniTest.expect.equality(execute.status(buf, h1), "running")
  MiniTest.expect.equality(execute.status(buf, h2), "queued")
  MiniTest.expect.equality(execute.status(buf, h3), "queued")
  br:reply({ status = "ok" })
  br:reply({ status = "ok" })
  br:reply({ status = "ok" })
  MiniTest.expect.equality(#br.requests, 0)

  local md = make_buffer({ "# %% [markdown]", "text", "# %% code", "q = 1" })
  local br2 = fake_bridge()
  inject_kernel(br2, md)
  execute.run_all(md)
  MiniTest.expect.equality(#br2.requests, 1)
  MiniTest.expect.equality(br2.requests[1].params.cell, cell.at(md, 3).hash)
  br2:reply({ status = "ok" })
end

T["batch"]["one cell.all pass per batch (cached parse)"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  inject_kernel(br, buf)
  cell.all(buf) -- warm cache
  local tick = vim.b[buf].changedtick

  execute.run_all(buf)
  -- No re-parse: the cache tick is unchanged by enqueueing.
  MiniTest.expect.equality(vim.b[buf].changedtick, tick)
  br:reply({ status = "ok" })
  br:reply({ status = "ok" })
  br:reply({ status = "ok" })
end

T["batch"]["run_selection sends selection text, keyed to the containing cell"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  inject_kernel(br, buf)
  local h1, _, _ = hashes(buf)

  vim.fn.setpos("'<", { buf, 2, 1, 0 })
  vim.fn.setpos("'>", { buf, 2, 5, 0 })
  execute.run_selection(buf)
  MiniTest.expect.equality(#br.requests, 1)
  MiniTest.expect.equality(br.requests[1].params.code, "x = 1")
  MiniTest.expect.equality(br.requests[1].params.cell, h1) -- containing cell
  br:reply({ status = "ok" })
end

T["advance"] = MiniTest.new_set()

T["advance"]["run_cell_and_advance moves to the next header"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  inject_kernel(br, buf)
  vim.api.nvim_set_current_buf(buf) -- cursor APIs need the buffer displayed

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  execute.run_cell_and_advance(buf)
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 3) -- "# %% b"
  br:reply({ status = "ok" })

  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  execute.run_cell_and_advance(buf)
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 5)
  br:reply({ status = "ok" })
end

T["attach"] = MiniTest.new_set()

T["attach"]["resubscribes when the kernel handle is replaced"] = function()
  local buf = make_buffer(LINES)
  local brA, brB = fake_bridge(), fake_bridge()
  inject_kernel(brA, buf)

  execute.run_cell(buf, 1)
  MiniTest.expect.equality(#brA.requests, 1)
  brA:reply({ status = "ok" })

  -- kernel.select/shutdown replaces the handle: next run must go to B.
  inject_kernel(brB, buf)
  execute.run_cell(buf, 3)
  MiniTest.expect.equality(#brB.requests, 1)
  MiniTest.expect.equality(#brA.requests, 0)
  MiniTest.expect.equality(brA.unsubs, 0)
  expect_truthy(brB.handlers.output ~= nil)
  brB:reply({ status = "ok" })
end

T["signs"] = MiniTest.new_set()

---All extmark sign texts currently placed on `buf`.
---@param buf integer
---@return string[]
local function sign_texts(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    if m[4].sign_text then
      out[#out + 1] = m[4].sign_text
    end
  end
  table.sort(out)
  return out
end

T["signs"]["queued/running/ok swap in place, ok persists until rerun"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  inject_kernel(br, buf)
  ui.attach(buf)

  execute.run_cell(buf, 1)
  expect_truthy(vim.tbl_contains(sign_texts(buf), "▶ "))

  br:reply({ status = "ok" })
  expect_truthy(vim.tbl_contains(sign_texts(buf), "✓ "))
  expect_truthy(not vim.tbl_contains(sign_texts(buf), "▶ "))

  -- Re-run: the ok sign is replaced by queued/running again (same extmark).
  execute.run_cell(buf, 1)
  expect_truthy(
    vim.tbl_contains(sign_texts(buf), "… ") or vim.tbl_contains(sign_texts(buf), "▶ ")
  )
  br:reply({ status = "ok" })
end

T["signs"]["spinner appears while running and is removed on completion"] = function()
  local buf = make_buffer(LINES)
  local br = fake_bridge()
  inject_kernel(br, buf)
  ui.attach(buf)

  execute.run_cell(buf, 1)
  local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
  local virt = {}
  for _, m in ipairs(marks) do
    if m[4].virt_text then
      virt[#virt + 1] = m[4].virt_text[1][1]
    end
  end
  MiniTest.expect.equality(#virt, 1)
  MiniTest.expect.equality(virt[1]:len() > 0, true)

  br:reply({ status = "ok" })
  local after = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
  for _, m in ipairs(after) do
    MiniTest.expect.equality(m[4].virt_text == nil, true)
  end
end

return T

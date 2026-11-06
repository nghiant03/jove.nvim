local MiniTest = require("mini.test")
local cell = require("jove.cell")
local execute = require("jove.execute")
local state = require("jove.state")

local saved_output, saved_defer, buffers, timers, pushed

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      buffers, timers, pushed = {}, {}, {}
      saved_output, saved_defer = execute._output, vim.defer_fn
      rawset(execute, "_output", function()
        return {
          clear = function() end,
          push = function(buf, hash, params)
            pushed[#pushed + 1] = { buf, hash, params.text }
          end,
        }
      end)
      vim.defer_fn = function(fn, ms)
        if ms == 10000 then
          timers[#timers + 1] = fn
          return
        end
        return saved_defer(fn, ms)
      end
    end,
    post_case = function()
      rawset(execute, "_output", saved_output)
      vim.defer_fn = saved_defer
      for _, buf in ipairs(buffers) do
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
    end,
  },
})

local function fake_bridge()
  local bridge = { requests = {}, handlers = {} }
  function bridge:request(method, params, cb)
    MiniTest.expect.equality(method, "execute")
    self.requests[#self.requests + 1] = { wire = params.cell, reply = cb }
  end
  function bridge:on(event, fn)
    self.handlers[event] = self.handlers[event] or {}
    table.insert(self.handlers[event], fn)
    return function() end
  end
  function bridge:is_alive()
    return true
  end
  function bridge:is_ready()
    return true
  end
  function bridge:stop() end
  function bridge:deliver(params)
    for _, callback in ipairs(self.handlers.output or {}) do
      callback(params)
    end
  end
  return bridge
end

local function sequence(reply_after, expire_after)
  local steps = { "run", "reply-first" }
  if expire_after == "reply-first" then
    steps[#steps + 1] = "expire-first"
  end
  for _, boundary in ipairs({ "rerun", "reload", "wipe" }) do
    steps[#steps + 1] = boundary
    if reply_after == boundary then
      steps[#steps + 1] = "reply-second"
    end
    if expire_after == boundary then
      steps[#steps + 1] = "expire-first"
    end
  end
  steps[#steps + 1] = "reply-third"
  return steps
end

for _, reply_after in ipairs({ "rerun", "reload", "wipe" }) do
  for _, expire_after in ipairs({ "reply-first", "rerun", "reload", "wipe" }) do
    local steps = sequence(reply_after, expire_after)
    T[table.concat(steps, " -> ")] = function()
      local buf = vim.api.nvim_create_buf(false, true)
      buffers[#buffers + 1] = buf
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %%", "x = 1" })
      local bridge = fake_bridge()
      state.get(buf).kernel = { bridge = bridge, name = "python3", status = "idle" }
      local hash = cell.at(buf, 1).hash
      local expected = {}
      local model = { alive = true, run = 0 }
      local wires = {}

      local function check(label)
        for index, request in ipairs(bridge.requests) do
          local text = label .. ":output-" .. index
          if model.alive and model.accept == index then
            expected[#expected + 1] = { buf, hash, text }
          end
          bridge:deliver({ cell = request.wire, kind = "stream", text = text })
          MiniTest.expect.equality(pushed, expected)
          MiniTest.expect.equality(state.peek(buf) ~= nil, model.alive)
        end
        MiniTest.expect.equality(#bridge.requests, model.run)
        if model.alive then
          MiniTest.expect.equality(execute.status(buf, hash), model.status)
          MiniTest.expect.equality(execute.queue_len(buf), 0)
          MiniTest.expect.equality(
            execute.running(buf),
            model.status == "running" and { hash = hash, lnum = 1 } or nil
          )
          local meta = execute.meta(buf, hash)
          MiniTest.expect.equality(meta and meta.count, model.count)
        else
          MiniTest.expect.equality(vim.api.nvim_buf_is_valid(buf), false)
        end
      end

      for step, action in ipairs(steps) do
        if action == "run" or action == "rerun" or action == "reload" then
          if action == "reload" then
            execute.reset(buf)
            model.accept, model.status, model.count = nil, nil, nil
            check(step .. ":reset")
          end
          model.run = model.run + 1
          model.accept, model.status = model.run, "running"
          execute.run_cell(buf, 1)
          local request = bridge.requests[model.run]
          MiniTest.expect.equality(type(request.wire), "string")
          MiniTest.expect.equality(wires[request.wire], nil)
          wires[request.wire] = true
        elseif action == "wipe" then
          model.alive, model.accept = false, nil
          vim.api.nvim_buf_delete(buf, { force = true })
        elseif action == "expire-first" then
          if model.accept == 1 then
            model.accept = nil
          end
          timers[1]()
        else
          local index = ({ ["reply-first"] = 1, ["reply-second"] = 2, ["reply-third"] = 3 })[action]
          if model.alive and model.run == index then
            model.status, model.count = "ok", index
          end
          bridge.requests[index].reply({ status = "ok", execution_count = index })
        end
        check(step .. ":" .. action)
      end
      for _, callback in ipairs(timers) do
        callback()
        check("drain-expiry")
      end
    end
  end
end

return T

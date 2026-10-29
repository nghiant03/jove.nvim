local MiniTest = require("mini.test")
local log = require("jove.log")
local state = require("jove.state")
local cell = require("jove.cell")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      log.enabled = false
      log.reset()
    end,
    post_case = function()
      log.enabled = false
      log.reset()
    end,
  },
})

T["disabled by default"] = MiniTest.new_set()

T["disabled by default"]["time calls through and records nothing"] = function()
  local hits = 0
  local function fn(a, b)
    hits = hits + 1
    return a + b, a - b
  end
  local sum, diff = log.time("phase", fn, 3, 1)
  MiniTest.expect.equality(sum, 4)
  MiniTest.expect.equality(diff, 2)
  MiniTest.expect.equality(hits, 1)
  MiniTest.expect.equality(next(log._stats), nil)
end

T["disabled by default"]["span_begin returns nil and count is a no-op"] = function()
  MiniTest.expect.equality(log.span_begin("phase"), nil)
  log.count("metric")
  MiniTest.expect.equality(next(log._counts), nil)
end

T["disabled by default"]["report mentions no samples"] = function()
  local msg = log.report()
  MiniTest.expect.equality(msg:find("no samples", 1, true) ~= nil, true)
end

T["time"] = MiniTest.new_set()

T["time"]["records a stat and forwards return values"] = function()
  log.enabled = true
  local function fn(a, b)
    return a .. b, b .. a
  end
  local first, second = log.time("phase", fn, "x", "y")
  MiniTest.expect.equality(first, "xy")
  MiniTest.expect.equality(second, "yx")
  MiniTest.expect.equality(log._stats.phase.count, 1)
  MiniTest.expect.equality(log._stats.phase.total_ms >= 0, true)
  MiniTest.expect.equality(log._stats.phase.min_ms <= log._stats.phase.max_ms, true)
end

T["time"]["forwards all return values with nil positions intact"] = function()
  log.enabled = true
  local function fn()
    return "a", nil, "c"
  end
  local a, b, c = log.time("phase", fn)
  MiniTest.expect.equality(a, "a")
  MiniTest.expect.equality(b, nil)
  MiniTest.expect.equality(c, "c")
  MiniTest.expect.equality(select("#", log.time("phase", fn)), 3)
end

T["time"]["keeps trailing nils in the return count"] = function()
  log.enabled = true
  local function fn()
    return "a", nil
  end
  MiniTest.expect.equality(select("#", log.time("phase", fn)), 2)
  MiniTest.expect.equality(select("#", log.time("disabled passthrough", fn)), 2)
end

T["time"]["propagates errors from fn"] = function()
  log.enabled = true
  local ok, err = pcall(log.time, "phase", function()
    error("boom")
  end)
  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(err:find("boom", 1, true) ~= nil, true)
  MiniTest.expect.equality(log._stats.phase, nil)
end

T["spans"] = MiniTest.new_set()

T["spans"]["span_end records the elapsed duration"] = function()
  log.enabled = true
  local span = log.span_begin("phase")
  MiniTest.expect.equality(type(span), "table")
  log.span_end("phase", span)
  MiniTest.expect.equality(log._stats.phase.count, 1)
  MiniTest.expect.equality(log._stats.phase.total_ms >= 0, true)
end

T["spans"]["span_end ignores a nil span (disabled begin)"] = function()
  log.enabled = true
  log.span_end("phase", nil)
  MiniTest.expect.equality(log._stats.phase, nil)
end

T["spans"]["span_end ignores a phase mismatch"] = function()
  log.enabled = true
  local span = log.span_begin("phase_a")
  log.span_end("phase_b", span)
  MiniTest.expect.equality(log._stats.phase_a, nil)
  MiniTest.expect.equality(log._stats.phase_b, nil)
end

T["counters and report"] = MiniTest.new_set()

T["counters and report"]["count increments with a default of one"] = function()
  log.enabled = true
  log.count("metric")
  log.count("metric")
  log.count("other", 5)
  MiniTest.expect.equality(log._counts.metric, 2)
  MiniTest.expect.equality(log._counts.other, 5)
end

T["counters and report"]["record adds a raw duration"] = function()
  log.enabled = true
  log.record("phase", 1.5)
  log.record("phase", 2.5)
  MiniTest.expect.equality(log._stats.phase.count, 2)
  MiniTest.expect.equality(log._stats.phase.total_ms, 4)
  MiniTest.expect.equality(log._stats.phase.min_ms, 1.5)
  MiniTest.expect.equality(log._stats.phase.max_ms, 2.5)
end

T["counters and report"]["report lists phases and counters"] = function()
  log.enabled = true
  log.record("slow", 10)
  log.record("fast", 1)
  log.count("metric")
  local msg = log.report()
  MiniTest.expect.equality(msg:find("slow", 1, true) ~= nil, true)
  MiniTest.expect.equality(msg:find("fast", 1, true) ~= nil, true)
  MiniTest.expect.equality(msg:find("metric", 1, true) ~= nil, true)
  MiniTest.expect.equality(msg:find("slow", 1, true) < msg:find("fast", 1, true), true)
end

T["counters and report"]["reset clears everything"] = function()
  log.enabled = true
  log.record("phase", 1)
  log.count("metric")
  log.reset()
  MiniTest.expect.equality(next(log._stats), nil)
  MiniTest.expect.equality(next(log._counts), nil)
end

T["instrumentation"] = MiniTest.new_set()

T["instrumentation"]["cell.all records a cell_parse sample when enabled"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %%", "x = 1" })
  state.get(buf).path = "fake.ipynb"
  log.enabled = true
  local cells = cell.all(buf)
  MiniTest.expect.equality(#cells, 1)
  MiniTest.expect.equality(log._stats.cell_parse.count, 1)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["instrumentation"]["cell.all records nothing when disabled"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %%", "x = 1" })
  state.get(buf).path = "fake.ipynb"
  cell.all(buf)
  MiniTest.expect.equality(next(log._stats), nil)
  vim.api.nvim_buf_delete(buf, { force = true })
end

return T

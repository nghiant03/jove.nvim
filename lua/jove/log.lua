-- Timing and metrics for jove

local M = {}

M.enabled = false

---@class jove.LogStat
---@field count integer
---@field total_ms number
---@field min_ms number
---@field max_ms number

-- Test seams.
---@type table<string, jove.LogStat>
M._stats = {}
---@type table<string, integer>
M._counts = {}

---@param phase string
---@param ms number
local function record(phase, ms)
  local s = M._stats[phase]
  if not s then
    s = { count = 0, total_ms = 0, min_ms = math.huge, max_ms = 0 }
    M._stats[phase] = s
  end
  s.count = s.count + 1
  s.total_ms = s.total_ms + ms
  if ms < s.min_ms then
    s.min_ms = ms
  end
  if ms > s.max_ms then
    s.max_ms = ms
  end
end

local function capture_returns(...)
  return { ... }, select("#", ...)
end

---@param phase string
---@param fn function
---@return any ...
function M.time(phase, fn, ...)
  if not M.enabled then
    return fn(...)
  end
  local t0 = vim.uv.hrtime()
  local res, n = capture_returns(fn(...))
  record(phase, (vim.uv.hrtime() - t0) / 1e6)
  return unpack(res, 1, n)
end

---@param phase string
---@return table? span
function M.span_begin(phase)
  if not M.enabled then
    return nil
  end
  return { phase = phase, start_hr = vim.uv.hrtime() }
end

---@param phase string
---@param span table?
function M.span_end(phase, span)
  if span and span.phase == phase and M.enabled then
    record(phase, (vim.uv.hrtime() - span.start_hr) / 1e6)
  end
end

---@param phase string
---@param ms number
function M.record(phase, ms)
  if not M.enabled then
    return
  end
  record(phase, ms)
end

---@param metric string
---@param inc integer?  default 1
function M.count(metric, inc)
  if not M.enabled then
    return
  end
  M._counts[metric] = (M._counts[metric] or 0) + (inc == nil and 1 or inc)
end

function M.reset()
  M._stats = {}
  M._counts = {}
end

local function phase_lines(stats)
  local phases = {}
  for phase in pairs(stats) do
    phases[#phases + 1] = phase
  end
  table.sort(phases, function(a, b)
    return stats[a].total_ms > stats[b].total_ms
  end)
  local lines = {}
  for _, phase in ipairs(phases) do
    local s = stats[phase]
    lines[#lines + 1] = ("  %-24s n=%-5d total=%-8.1fms avg=%-7.2fms min=%-7.2fms max=%.2fms"):format(
      phase,
      s.count,
      s.total_ms,
      s.total_ms / s.count,
      s.min_ms,
      s.max_ms
    )
  end
  return lines
end

local function count_lines(counts)
  local metrics = {}
  for metric in pairs(counts) do
    metrics[#metrics + 1] = metric
  end
  table.sort(metrics, function(a, b)
    return counts[a] > counts[b]
  end)
  local lines = {}
  for _, metric in ipairs(metrics) do
    lines[#lines + 1] = ("  %-24s n=%d"):format(metric, counts[metric])
  end
  return lines
end

---@return string
function M.report()
  local phases = phase_lines(vim.deepcopy(M._stats))
  local metrics = count_lines(vim.deepcopy(M._counts))
  local lines = {}
  if #phases == 0 and #metrics == 0 then
    lines[#lines + 1] = "[Jove] profile: no samples collected"
  else
    lines[#lines + 1] = "[Jove] profile"
    for _, l in ipairs(phases) do
      lines[#lines + 1] = l
    end
    for _, l in ipairs(metrics) do
      lines[#lines + 1] = l
    end
  end
  local msg = table.concat(lines, "\n")
  if M.enabled then
    vim.notify(msg, vim.log.levels.INFO)
  end
  return msg
end

return M

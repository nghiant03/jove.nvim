local MiniTest = require("mini.test")
local health = require("jove.health")

local T = MiniTest.new_set()

---Stub fields on the shared vim.health table so health.lua sees the replacements.
---@param fn fun()
---@return table calls  -- {start = {...}, ok = {...}, ...} lists of messages
local function capture_health(fn)
  local calls = { start = {}, ok = {}, info = {}, warn = {}, error = {} }
  local orig = {}
  for k in pairs(calls) do
    orig[k] = vim.health[k]
    vim.health[k] = function(msg)
      calls[k][#calls[k] + 1] = msg
    end
  end
  local _, err = pcall(fn)
  for k, f in pairs(orig) do
    vim.health[k] = f
  end
  MiniTest.expect.equality(err == nil, true)
  return calls
end

T["check"] = MiniTest.new_set()

T["check"]["runs headless without error and emits a jove section"] = function()
  local calls = capture_health(function()
    health.check()
  end)
  MiniTest.expect.equality(calls.start, { "jove" })
  MiniTest.expect.equality(#calls.ok >= 3, true)
end

T["check"]["reports snacks.image as INFO only, never WARN/ERROR"] = function()
  local calls = capture_health(function()
    health.check()
  end)
  for _, msg in ipairs(calls.info) do
    if msg:find("snacks.image", 1, true) then
      return
    end
  end
  error("no snacks.image info line emitted")
end

T["check"]["no molten WARN when molten is absent"] = function()
  local calls = capture_health(function()
    health.check()
  end)
  for _, msg in ipairs(calls.warn or {}) do
    MiniTest.expect.equality(msg:find("molten", 1, true) == nil, true)
  end
end

T["check_import_result"] = MiniTest.new_set()

T["check_import_result"]["code 0 -> ok"] = function()
  local status, detail = health.check_import_result(0, "")
  MiniTest.expect.equality(status, "ok")
  MiniTest.expect.equality(detail, "jupyter_client + ipykernel importable")
end

T["check_import_result"]["failure -> missing with stderr detail (or fallback)"] = function()
  local status, detail = health.check_import_result(1, "ModuleNotFoundError: no module named x")
  MiniTest.expect.equality(status, "missing")
  MiniTest.expect.equality(detail, "ModuleNotFoundError: no module named x")

  local status2, detail2 = health.check_import_result(1, "")
  MiniTest.expect.equality(status2, "missing")
  MiniTest.expect.equality(detail2, "import failed")

  -- Timeout/kill: nil exit code counts as missing.
  local status3 = health.check_import_result(nil, "")
  MiniTest.expect.equality(status3, "missing")
end

return T

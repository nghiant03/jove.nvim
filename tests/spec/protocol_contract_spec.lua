local MiniTest = require("mini.test")
local bridge = require("jove.bridge")
local fixture = require("tests.helpers.bridge")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local contract =
  vim.json.decode(table.concat(vim.fn.readfile(root .. "/tests/fixtures/protocol.json"), "\n"))
local job

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      job = fixture.new()
    end,
    post_case = function()
      job.restore()
    end,
  },
})

T["bridge consumes shared execute outputs and replies without changing cell wire keys"] = function()
  local handle = bridge.new({ respawn = false, timeout_ms = false })
  local received, expected, errors = {}, {}, {}
  handle:on("output", function(params)
    table.insert(received, { event = "output", params = params })
  end)
  handle:on("protocol_error", function(params)
    table.insert(errors, params)
  end)
  handle:start()
  job.stdout('{"event":"ready","params":{"protocol":1}}\n')
  for _, request in ipairs(contract.requests) do
    handle:request(request.method, request.params, function(result, err)
      table.insert(received, { id = request.id, result = result })
      if err then
        table.insert(errors, err)
      end
    end)
  end
  local sent = {}
  for _, line in ipairs(job.sent) do
    table.insert(sent, vim.json.decode(line))
  end
  MiniTest.expect.equality(sent, contract.requests)
  for _, step in ipairs(contract.steps) do
    table.insert(expected, step.wire)
    local line = vim.json.encode(step.wire) .. "\n"
    local middle = math.floor(#line / 2)
    job.stdout(line:sub(1, middle))
    job.stdout(line:sub(middle + 1))
  end
  MiniTest.expect.equality(
    vim.wait(1000, function()
      return #received == #expected
    end),
    true
  )
  MiniTest.expect.equality(errors, {})
  MiniTest.expect.equality(received, expected)
  MiniTest.expect.equality(next(handle._pending), nil)
end

return T

-- Integration tests using the Python sidecar. Skipped when its dependencies
-- or package are unavailable; Python tests cover protocol conformance.
local MiniTest = require("mini.test")
local bridge_mod = require("jove.bridge")

local T = MiniTest.new_set()

---True when the real bridge can run: python deps importable and the
---jove_bridge package present under <repo>/python.
---@return boolean
local function deps_present()
  vim.fn.system({ "python3", "-c", "import jupyter_client, ipykernel" })
  if vim.v.shell_error ~= 0 then
    return false
  end
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
  return vim.uv.fs_stat(vim.fs.joinpath(root, "python", "jove_bridge", "__main__.py")) ~= nil
end

T["sidecar"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      if not deps_present() then
        MiniTest.skip("python3 lacks jupyter_client/ipykernel or python/jove_bridge is missing")
      end
    end,
  },
})

T["sidecar"]["ready -> kernelspecs -> start_kernel -> execute -> stop"] = function()
  local b = bridge_mod.new()

  local ready_params
  b:on("ready", function(params)
    ready_params = params
  end)
  local outputs = {}
  b:on("output", function(params)
    table.insert(outputs, params)
  end)

  b:start()
  MiniTest.expect.equality(
    vim.wait(15000, function()
      return b:is_ready()
    end),
    true
  )
  MiniTest.expect.equality(ready_params and ready_params.protocol, 1)

  local ks, ks_err
  b:request("list_kernelspecs", {}, function(r, e)
    ks, ks_err = r, e
  end)
  vim.wait(10000, function()
    return ks or ks_err
  end)
  MiniTest.expect.equality(ks_err, nil)
  MiniTest.expect.equality(type(ks.kernelspecs), "table")
  MiniTest.expect.equality(ks.kernelspecs["python3"] ~= nil, true)

  -- start_kernel (generous timeout: kernel spawn + sidecar readiness probe).
  local sk_res, sk_err
  b:request("start_kernel", { kernelspec = "python3" }, function(r, e)
    sk_res, sk_err = r, e
  end, { timeout_ms = 30000 })
  vim.wait(35000, function()
    return sk_res or sk_err
  end)
  MiniTest.expect.equality(sk_err, nil)
  MiniTest.expect.equality(type(sk_res), "table")

  -- execute: reply deferred until execute_reply; iopub streams in between.
  local ex_res, ex_err
  b:request("execute", { code = "print(21*2)", cell = "e2e-cell" }, function(r, e)
    ex_res, ex_err = r, e
  end, { timeout_ms = 30000 })
  vim.wait(30000, function()
    return ex_res or ex_err
  end)
  MiniTest.expect.equality(ex_err, nil)
  MiniTest.expect.equality(ex_res.status, "ok")

  local found
  for _, o in ipairs(outputs) do
    if o.cell == "e2e-cell" and o.kind == "stream" then
      local text = tostring((o.mime or {})["text/plain"] or "")
      if text:find("42", 1, true) then
        found = o
      end
    end
  end
  MiniTest.expect.equality(type(found), "table")
  MiniTest.expect.equality(found and found.name, "stdout")

  b:stop()
  MiniTest.expect.equality(
    vim.wait(10000, function()
      return not b:is_alive()
    end),
    true
  )
  MiniTest.expect.equality(b:is_ready(), false)
end

return T

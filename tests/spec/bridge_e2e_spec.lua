local MiniTest = require("mini.test")
local bridge_mod = require("jove.bridge")

local T = MiniTest.new_set()
local active_bridge

---@return boolean
local function deps_present()
  vim.fn.system({
    bridge_mod.resolve_python(),
    "-c",
    "import jupyter_client, ipykernel; "
      .. "assert 'python3' in jupyter_client.kernelspec.KernelSpecManager().find_kernel_specs()",
  })
  if vim.v.shell_error ~= 0 then
    return false
  end
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
  return vim.uv.fs_stat(vim.fs.joinpath(root, "python", "jove_bridge", "__main__.py")) ~= nil
end

T["sidecar"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      active_bridge = nil
      if not deps_present() then
        local reason =
          "bridge Python lacks jupyter_client/ipykernel/python3 kernelspec or sidecar is missing"
        if vim.env.JOVE_TEST_STRICT == "1" then
          error(reason)
        end
        MiniTest.skip(reason)
      end
    end,
    post_case = function()
      if active_bridge then
        active_bridge:stop()
        local stopped = vim.wait(10000, function()
          return not active_bridge:is_alive()
        end)
        active_bridge = nil
        MiniTest.expect.equality(stopped, true)
      end
    end,
  },
})

T["sidecar"]["complete kernel lifecycle"] = function()
  local b = bridge_mod.new()
  active_bridge = b

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
  MiniTest.expect.equality(
    vim.wait(10000, function()
      return ks or ks_err
    end),
    true
  )
  MiniTest.expect.equality(ks_err, nil)
  MiniTest.expect.equality(type(ks.kernelspecs), "table")
  MiniTest.expect.equality(ks.kernelspecs["python3"] ~= nil, true)

  local sk_res, sk_err
  b:request("start_kernel", { kernelspec = "python3" }, function(r, e)
    sk_res, sk_err = r, e
  end, { timeout_ms = 30000 })
  MiniTest.expect.equality(
    vim.wait(35000, function()
      return sk_res or sk_err
    end),
    true
  )
  MiniTest.expect.equality(sk_err, nil)
  MiniTest.expect.equality(type(sk_res), "table")

  local ex_res, ex_err
  b:request("execute", { code = "print(21*2)", cell = "e2e-cell" }, function(r, e)
    ex_res, ex_err = r, e
  end, { timeout_ms = 30000 })
  MiniTest.expect.equality(
    vim.wait(30000, function()
      return ex_res or ex_err
    end),
    true
  )
  MiniTest.expect.equality(ex_err, nil)
  MiniTest.expect.equality(ex_res.status, "ok")

  local found
  MiniTest.expect.equality(
    vim.wait(15000, function()
      for _, o in ipairs(outputs) do
        if o.cell == "e2e-cell" and o.kind == "stream" then
          local text = tostring((o.mime or {})["text/plain"] or "")
          if text:find("42", 1, true) then
            found = o
            return true
          end
        end
      end
      return false
    end),
    true
  )
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

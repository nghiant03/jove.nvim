local MiniTest = require("mini.test")
local lsp = require("jove.lsp")
local state = require("jove.state")
local jove = require("jove")

local T = MiniTest.new_set()

local orig_impl = vim.deepcopy(lsp._impl)
local orig_lsp_cfg = vim.deepcopy(jove.config.lsp)

---@param cond any
local function expect_truthy(cond)
  MiniTest.expect.equality(cond == true, true)
end

T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      jove.config.lsp = vim.deepcopy(orig_lsp_cfg)
      lsp._reset()
    end,
    post_case = function()
      jove.config.lsp = vim.deepcopy(orig_lsp_cfg)
      lsp._impl.get_clients = orig_impl.get_clients
      lsp._impl.start = orig_impl.start
      lsp._impl.config = orig_impl.config
      lsp._reset()
    end,
  },
})

---@param calls table
local function stub_impl(calls)
  lsp._impl.get_clients = function()
    return calls.clients or {}
  end
  lsp._impl.start = function(conf, opts)
    calls.started[#calls.started + 1] = { conf = conf, opts = opts }
    return 1
  end
  lsp._impl.config = function(name)
    return calls.configs and calls.configs[name] or nil
  end
end

local function capture_notify(fn)
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  local ok = pcall(fn)
  vim.notify = orig
  MiniTest.expect.equality(ok, true)
  return notes
end

---@return integer buf
local function notebook_buffer(lang_id)
  local buf = vim.api.nvim_create_buf(false, true)
  local st = state.get(buf)
  st.path = "fake.ipynb"
  st.lang = lang_id
  return buf
end

T["attach"] = MiniTest.new_set()

T["attach"]["no-op when auto_attach is disabled"] = function()
  local calls = { started = {}, configs = { fakeserver = { cmd = { "true" } } } }
  stub_impl(calls)
  local buf = notebook_buffer("python")
  lsp.attach(buf)
  MiniTest.expect.equality(#calls.started, 0)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["attach"]["no-op when the language has no servers entry"] = function()
  jove.config.lsp = { auto_attach = true, servers = { javascript = { "ts_ls" } } }
  local calls = { started = {}, configs = { ts_ls = { cmd = { "true" } } } }
  stub_impl(calls)
  local buf = notebook_buffer("python")
  lsp.attach(buf)
  MiniTest.expect.equality(#calls.started, 0)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["attach"]["starts configured servers with their vim.lsp.config entry"] = function()
  jove.config.lsp = { auto_attach = true, servers = { python = { "fakeserver" } } }
  local conf = { cmd = { "true" }, name = "fakeserver" }
  local calls = { started = {}, configs = { fakeserver = conf } }
  stub_impl(calls)
  local buf = notebook_buffer("python")
  lsp.attach(buf)
  MiniTest.expect.equality(#calls.started, 1)
  MiniTest.expect.equality(calls.started[1].conf, conf)
  MiniTest.expect.equality(calls.started[1].opts.bufnr, buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["attach"]["skips servers already attached to the buffer"] = function()
  jove.config.lsp = { auto_attach = true, servers = { python = { "fakeserver" } } }
  local calls = {
    started = {},
    clients = { { name = "fakeserver" } },
    configs = { fakeserver = { cmd = { "true" } } },
  }
  stub_impl(calls)
  local buf = notebook_buffer("python")
  lsp.attach(buf)
  MiniTest.expect.equality(#calls.started, 0)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["attach"]["warns once when no vim.lsp.config entry exists"] = function()
  jove.config.lsp = { auto_attach = true, servers = { python = { "ghostserver" } } }
  local calls = { started = {}, configs = {} }
  stub_impl(calls)
  local buf = notebook_buffer("python")
  local notes = capture_notify(function()
    lsp.attach(buf)
    lsp.attach(buf)
  end)
  MiniTest.expect.equality(#calls.started, 0)
  MiniTest.expect.equality(#notes, 1)
  MiniTest.expect.equality(notes[1].level, vim.log.levels.WARN)
  expect_truthy(notes[1].msg:find("ghostserver", 1, true) ~= nil)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["attach"]["start failure notifies without raising"] = function()
  jove.config.lsp = { auto_attach = true, servers = { python = { "boomserver" } } }
  local calls = { started = {}, configs = { boomserver = { cmd = { "missing-bin" } } } }
  stub_impl(calls)
  lsp._impl.start = function()
    error("spawn failed")
  end
  local buf = notebook_buffer("python")
  local notes = capture_notify(function()
    lsp.attach(buf)
  end)
  MiniTest.expect.equality(#notes, 1)
  expect_truthy(notes[1].msg:find("boomserver", 1, true) ~= nil)
  vim.api.nvim_buf_delete(buf, { force = true })
end

return T

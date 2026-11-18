---@diagnostic disable: duplicate-set-field, param-type-mismatch
local MiniTest = require("mini.test")
local state = require("jove.state")
local vars = require("jove.ui.vars")
local sidebar = require("jove.ui.sidebar")

local T = MiniTest.new_set()

local created, real_variables, real_show_float, saved_config_variables

---@param cond any
local function expect_truthy(cond)
  MiniTest.expect.equality(cond == true, true)
end

---@param lines string[]
---@return integer
local function make_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  state.get(buf).path = "fake.ipynb"
  created[#created + 1] = buf
  return buf
end

---@param win integer
---@return string
local function win_text(win)
  local fbuf = vim.api.nvim_win_get_buf(win)
  return table.concat(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false), "\n")
end

T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      created = {}
      real_variables = vars._variables
      real_show_float = vars.show_float
      saved_config_variables = require("jove").config.variables
      require("jove").config.variables = { size = 0.4, auto_refresh = false }
    end,
    post_case = function()
      for _, buf in ipairs(created) do
        pcall(sidebar.close, buf)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
      vars._variables = real_variables
      vars.show_float = real_show_float
      require("jove").config.variables = saved_config_variables
    end,
  },
})

T["format"] = MiniTest.new_set()

T["format"]["renders a muted header row plus name, type, and value columns"] = function()
  local lines, spans, items_offset = vars.format({
    { name = "alpha", type = "int", value = "42" },
    { name = "beta", type = "str", value = "'hello'" },
  }, 40)
  MiniTest.expect.equality(items_offset, 1)
  MiniTest.expect.equality(#lines, 3)
  expect_truthy(lines[1]:find("Name", 1, true) ~= nil)
  expect_truthy(lines[2]:find("alpha", 1, true) ~= nil)
  expect_truthy(lines[2]:find("int", 1, true) ~= nil)
  expect_truthy(lines[2]:find("42", 1, true) ~= nil)
  expect_truthy(lines[3]:find("'hello'", 1, true) ~= nil)
  local groups = {}
  for _, span in ipairs(spans) do
    groups[#groups + 1] = span[4]
  end
  expect_truthy(vim.tbl_contains(groups, "JoveSidebarMuted"))
  expect_truthy(vim.tbl_contains(groups, "JoveSidebarVarName"))
  expect_truthy(vim.tbl_contains(groups, "JoveSidebarVarType"))
end

T["format"]["truncates long values to fit the width"] = function()
  local lines = vars.format({
    { name = "n", type = "list", value = string.rep("x", 200) },
  }, 30)
  MiniTest.expect.equality(#lines, 2)
  expect_truthy(vim.fn.strdisplaywidth(lines[2]) <= 30)
  expect_truthy(lines[2]:find("…", 1, true) ~= nil)
end

T["format"]["flattens embedded newlines in values for sidebar rows"] = function()
  local lines = vars.format({
    { name = "df", type = "DataFrame", value = "   a\n0  1\n1  2" },
  }, 40)
  MiniTest.expect.equality(#lines, 2)
  expect_truthy(not lines[2]:find("\n", 1, true))
  expect_truthy(lines[2]:find("a", 1, true) ~= nil)
end

T["format"]["keeps non-syntactic names and types on a single sidebar line"] = function()
  local lines = vars.format({ { name = "a\nb", type = "c\nd", value = "42" } }, 40)
  expect_truthy(lines[2]:find("a b", 1, true) ~= nil)
  expect_truthy(lines[2]:find("c d", 1, true) ~= nil)
end

T["format"]["keeps empty values empty"] = function()
  local lines = vars.format({
    { name = "n", type = "NoneType", value = "" },
  }, 40)
  MiniTest.expect.equality(#lines, 2)
  expect_truthy(not lines[2]:find("\n", 1, true))
  expect_truthy(lines[2]:find("NoneType", 1, true) ~= nil)
end

T["format"]["handles the empty case"] = function()
  MiniTest.expect.equality(vars.format({}, 40), { "No variables in scope" })
  MiniTest.expect.equality(vars.format(nil, 40), { "No variables in scope" })
end

T["show_float"] = MiniTest.new_set()

T["show_float"]["strips ANSI sequences and renders SGR styling as highlights"] = function()
  local win = vars.show_float("\27[0;31mred\27[0m plain")
  expect_truthy(win ~= nil)
  local fbuf = vim.api.nvim_win_get_buf(win)
  MiniTest.expect.equality(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false), { "red plain" })
  local ns = vim.api.nvim_create_namespace("jove_vars_float")
  local marks = vim.api.nvim_buf_get_extmarks(fbuf, ns, 0, -1, { details = true })
  MiniTest.expect.equality(#marks, 1)
  MiniTest.expect.equality(marks[1][3], 0)
  MiniTest.expect.equality(marks[1][4].end_col, 3)
  expect_truthy(type(marks[1][4].hl_group) == "string")
  pcall(vim.api.nvim_win_close, win, true)
end

T["show_float"]["splits spans across lines"] = function()
  local win = vars.show_float("one\n\27[1mtwo\27[0m")
  expect_truthy(win ~= nil)
  local fbuf = vim.api.nvim_win_get_buf(win)
  MiniTest.expect.equality(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false), { "one", "two" })
  local ns = vim.api.nvim_create_namespace("jove_vars_float")
  local marks = vim.api.nvim_buf_get_extmarks(fbuf, ns, 0, -1, { details = true })
  MiniTest.expect.equality(#marks, 1)
  MiniTest.expect.equality(marks[1][2], 1)
  MiniTest.expect.equality(marks[1][3], 0)
  MiniTest.expect.equality(marks[1][4].end_col, 3)
  pcall(vim.api.nvim_win_close, win, true)
end

T["sidebar"] = MiniTest.new_set()

T["sidebar"]["open fetches through the bridge seam, renders, and closes"] = function()
  local buf = make_buffer({ "# %%", "x = 1" })
  local called = 0
  vars._variables = function(_, cb)
    called = called + 1
    cb({
      variables = {
        { name = "alpha", type = "int", value = "42" },
        { name = "beta", type = "str", value = "'hello'" },
      },
    })
  end

  local win = sidebar.open(buf, "vars")
  expect_truthy(win ~= nil)
  MiniTest.expect.equality(sidebar.is_open(buf), true)
  MiniTest.expect.equality(called, 1)
  local text = win_text(win)
  expect_truthy(text:find("alpha", 1, true) ~= nil)
  expect_truthy(text:find("'hello'", 1, true) ~= nil)

  sidebar.close(buf)
  MiniTest.expect.equality(sidebar.is_open(buf), false)
end

T["sidebar"]["toggle opens then closes"] = function()
  local buf = make_buffer({ "# %%", "x = 1" })
  vars._variables = function(_, cb)
    cb({ variables = {} })
  end
  sidebar.toggle(buf)
  MiniTest.expect.equality(sidebar.is_open(buf), true)
  sidebar.toggle(buf)
  MiniTest.expect.equality(sidebar.is_open(buf), false)
end

local function attach_kernel(buf, language)
  local requests = {}
  state.get(buf).kernel = {
    name = "custom-spec",
    language = language,
    status = "idle",
    ---@diagnostic disable-next-line: missing-fields
    bridge = {
      is_alive = function()
        return true
      end,
      request = function(_, method, params, cb, opts)
        requests[#requests + 1] = { method = method, params = params, reply = cb, opts = opts }
      end,
    },
  }
  return requests
end

local function expect_text(win, text)
  assert(
    vim.wait(1000, function()
      return win_text(win):find(text, 1, true) ~= nil
    end),
    "missing " .. text .. " in " .. win_text(win)
  )
end

local function row(name)
  return { variables = { { name = name, type = "numeric", value = "42" } } }
end

T["sidebar"]["distinguishes no kernel, unsupported, empty, probe failure and a successful retry"] = function()
  local buf = make_buffer({})
  state.get(buf).json = { metadata = { kernelspec = { language = "julia" } } }
  local win = sidebar.open(buf, "vars")
  expect_text(win, "No kernel running")

  local requests = attach_kernel(buf, "r")
  sidebar.refresh(buf)
  MiniTest.expect.equality(requests[1].method, "variables")
  expect_truthy(requests[1].opts.timeout_ms > 12000)
  requests[1].reply({ variables = {}, unsupported = "custom" })
  expect_text(win, "unavailable for custom kernels")

  sidebar.refresh(buf)
  requests[2].reply({ variables = {} })
  expect_text(win, "No variables in scope")
  sidebar.refresh(buf)
  requests[3].reply(nil, { code = "variables_failed", message = "probe\nfailed" })
  expect_text(win, "r to retry")
  expect_text(win, "probe failed")
  sidebar.refresh(buf)
  requests[4].reply(row("recovered"))
  expect_text(win, "recovered")

  state.get(buf).kernel.status = "dead"
  sidebar.refresh(buf)
  expect_text(win, "No kernel running")
  MiniTest.expect.equality(#requests, 4)
end

T["sidebar"]["ignores out-of-order replies from a closed session and a superseded refresh"] = function()
  local buf = make_buffer({})
  local requests = attach_kernel(buf, "julia")
  sidebar.open(buf, "vars")
  sidebar.close(buf)
  local win = sidebar.open(buf, "vars")
  sidebar.refresh(buf)
  requests[3].reply(row("newest"))
  expect_text(win, "newest")
  requests[1].reply(nil, "old session")
  requests[2].reply(row("obsolete"))
  local drained = false
  vim.schedule(function()
    drained = true
  end)
  assert(vim.wait(1000, function()
    return drained
  end))
  expect_text(win, "newest")
end

T["sidebar"]["a replaced or restarted kernel cannot supply the current snapshot"] = function()
  local buf = make_buffer({})
  local old = attach_kernel(buf, "r")
  local win = sidebar.open(buf, "vars")
  local current = attach_kernel(buf, "r")
  old[1].reply(row("replaced"))
  assert(vim.wait(1000, function()
    return #current == 1
  end))
  MiniTest.expect.equality(win_text(win):find("replaced", 1, true), nil)

  require("jove.kernel").restart(buf)
  MiniTest.expect.equality(current[2].method, "restart")
  current[2].reply({})
  current[1].reply(row("stale"))
  assert(vim.wait(1000, function()
    return #current == 3
  end))
  MiniTest.expect.equality(win_text(win):find("stale", 1, true), nil)
  current[3].reply(row("fresh"))
  expect_text(win, "fresh")
end

T["sidebar"]["auto-refresh fetches after completed cells, not busy events or after close"] = function()
  require("jove").config.variables.auto_refresh = true
  local buf = make_buffer({})
  local requests = attach_kernel(buf, "r")
  local win = sidebar.open(buf, "vars")
  local listeners = state.get(buf).exec.status_cbs
  local notify = listeners[1]
  notify("cell", "queued")
  notify("cell", "running")
  MiniTest.expect.equality(#requests, 1)
  notify("cell", "ok")
  notify("cell", "error")
  MiniTest.expect.equality(#requests, 3)
  requests[3].reply(row("updated"))
  expect_text(win, "updated")
  sidebar.close(buf)
  MiniTest.expect.equality(#listeners, 0)
end

T["sidebar"]["Enter uses live details, falls back to the cached preview and ignores late details"] = function()
  local buf = make_buffer({})
  local requests = attach_kernel(buf, "julia")
  local win = sidebar.open(buf, "vars")
  requests[1].reply(row("α"))
  expect_text(win, "α")
  vim.api.nvim_win_set_cursor(win, { 4, 0 })
  local shown = {}
  vars.show_float = function(text)
    shown[#shown + 1] = text
  end
  sidebar.activate(buf)
  MiniTest.expect.equality(requests[2].method, "inspect")
  MiniTest.expect.equality(requests[2].params, { code = "α", cursor_pos = 1, detail_level = 1 })
  requests[2].reply({ mime = { ["text/plain"] = "live detail" } })
  sidebar.activate(buf)
  requests[3].reply({ mime = {} })
  sidebar.activate(buf)
  requests[4].reply(nil, "inspect unavailable")
  sidebar.activate(buf)
  require("jove.kernel").restart(buf)
  requests[5].reply({ mime = { ["text/plain"] = "obsolete" } })
  state.get(buf).kernel = nil
  sidebar.activate(buf)
  MiniTest.expect.equality(shown, { "live detail", "α = 42", "α = 42", "α = 42" })

  requests = attach_kernel(buf, "julia")
  sidebar.refresh(buf)
  requests[1].reply(row("β"))
  expect_text(win, "β")
  sidebar.activate(buf)
  sidebar.close(buf)
  sidebar.open(buf, "vars")
  requests[2].reply(nil, "closed")
  MiniTest.expect.equality(#shown, 4)
end

T["sidebar"]["refresh re-queries and re-renders"] = function()
  local buf = make_buffer({ "# %%", "x = 1" })
  local payload = { variables = { { name = "first", type = "int", value = "1" } } }
  vars._variables = function(_, cb)
    cb(payload)
  end
  local win = sidebar.open(buf, "vars")
  expect_truthy(win_text(win):find("first", 1, true) ~= nil)

  payload = { variables = { { name = "second", type = "str", value = "2" } } }
  sidebar.refresh(buf)
  expect_truthy(win_text(win):find("second", 1, true) ~= nil)
  sidebar.close(buf)
end

T["sidebar"]["opens a vertical split by default and a float when configured"] = function()
  local buf = make_buffer({ "# %%", "x = 1" })
  vars._variables = function(_, cb)
    cb({ variables = {} })
  end

  local jove = require("jove")
  local saved = jove.config.ui.window_mode

  jove.config.ui.window_mode = "vsplit"
  local win = sidebar.open(buf, "vars")
  expect_truthy(win ~= nil)
  MiniTest.expect.equality(vim.api.nvim_win_get_config(win).relative, "")
  sidebar.close(buf)

  jove.config.ui.window_mode = "float"
  win = sidebar.open(buf, "vars")
  expect_truthy(win ~= nil)
  MiniTest.expect.equality(vim.api.nvim_win_get_config(win).relative, "editor")
  sidebar.close(buf)

  jove.config.ui.window_mode = saved
end

return T

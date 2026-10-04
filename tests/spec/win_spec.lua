---@diagnostic disable: duplicate-set-field, missing-fields, need-check-nil
local MiniTest = require("mini.test")
local jove = require("jove")
local sidebar = require("jove.ui.sidebar")
local vars = require("jove.ui.vars")
local webview = require("jove.webview")

local saved_config, saved_variables, saved_impl, buf, windows, sessions
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      saved_config = vim.deepcopy(jove.config)
      saved_variables = vars._variables
      saved_impl = vim.tbl_extend("force", {}, webview._impl)
      jove.config.ui.window_mode = "vsplit"
      jove.config.ui.window_overrides = {}
      jove.config.variables.auto_refresh = false
      vars._variables = function(_, cb)
        cb({ variables = {} })
      end
      webview._impl.executable = function()
        return 1
      end
      webview._impl.terminal_supports_kitty = function()
        return true
      end
      webview._impl.cell_pixels = function()
        return 10, 20
      end
      webview._impl.jobstart = function()
        return 42
      end
      webview._impl.jobstop = function() end
      webview._impl.open_tty = function()
        return 999
      end
      webview._impl.close_tty = function() end
      webview._impl.write_tty = function() end
      webview._impl.jobsend = function() end
      webview._impl.jobresize = function() end
      buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %%", "x = 1" })
      vim.api.nvim_set_current_buf(buf)
      require("jove.state").get(buf).path = "fake.ipynb"
      require("jove.output").push(buf, require("jove.cell").all(buf)[1].hash, {
        kind = "stream",
        mime = { ["text/plain"] = "hello" },
      })
      windows, sessions = {}, {}
    end,
    post_case = function()
      for _, session in ipairs(sessions) do
        session:close()
      end
      sidebar.close(buf)
      for _, win in ipairs(windows) do
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end
      vim.api.nvim_buf_delete(buf, { force = true })
      jove.config = saved_config
      vars._variables = saved_variables
      for key, value in pairs(saved_impl) do
        webview._impl[key] = value
      end
    end,
  },
})

local function open(view)
  local win
  if view == "sidebar" then
    win = sidebar.open(buf, "vars")
  elseif view == "output" then
    win = require("jove.output").open_float(buf, 1)
  elseif view == "inspect" then
    win = vars.show_float("x = 1")
  else
    local session = assert(webview.open("about:blank", { width = 0.5, height = 0.5 }))
    sessions[#sessions + 1] = session
    win = session.win
  end
  assert(win, view .. " failed to open")
  windows[#windows + 1] = win
  return win
end

for _, view in ipairs({ "sidebar", "output", "inspect", "webview" }) do
  T[view] = MiniTest.new_set()
  for _, mode in ipairs({ "vsplit", "hsplit", "float" }) do
    for _, override in ipairs({ false, true }) do
      local label = (override and "uses the per-view override: " or "inherits the default mode: ")
        .. mode
      T[view][label] = function()
        jove.config.ui.window_mode = override and (mode == "float" and "hsplit" or "float") or mode
        if override then
          jove.config.ui.window_overrides[view] = mode
        end
        local source = vim.api.nvim_get_current_win()
        local win = open(view)
        local cfg = vim.api.nvim_win_get_config(win)
        MiniTest.expect.equality(cfg.relative, mode == "float" and "editor" or "")
        if mode ~= "float" then
          local a, b = vim.api.nvim_win_get_position(source), vim.api.nvim_win_get_position(win)
          local axis = mode == "vsplit" and 2 or 1
          MiniTest.expect.equality(b[axis] > a[axis], true)
        end
        if view == "inspect" and mode == "hsplit" then
          -- A short detail view uses its content height, never its column width.
          MiniTest.expect.equality(vim.api.nvim_win_get_height(win), 3)
        end
        if view == "webview" then
          MiniTest.expect.equality(vim.wo[win].number, false)
          MiniTest.expect.equality(vim.wo[win].signcolumn, "no")
          MiniTest.expect.equality(vim.wo[win].wrap, false)
        end
        if override then
          MiniTest.expect.equality(require("jove.ui.win").mode(), jove.config.ui.window_mode)
        end
      end
    end
  end
end

return T

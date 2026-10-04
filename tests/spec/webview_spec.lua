---@diagnostic disable: duplicate-set-field, missing-fields, need-check-nil
local MiniTest = require("mini.test")
local webview = require("jove.webview")
local jove = require("jove")
local saved_impl, saved_config, sessions, captured, inputs, graphics, stopped, resized

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      saved_config = vim.deepcopy(jove.config)
      saved_impl = vim.tbl_extend("force", {}, webview._impl)
      sessions, inputs, graphics, stopped, resized = {}, {}, {}, {}, {}
      jove.config.ui.window_mode = "vsplit"
      jove.config.ui.window_overrides = {}
      jove.config.webview.enabled = true
      webview._impl.executable = function()
        return 1
      end
      webview._impl.terminal_supports_kitty = function()
        return true
      end
      webview._impl.cell_pixels = function()
        return 10, 20
      end
      webview._impl.open_tty = function()
        return 999
      end
      webview._impl.close_tty = function() end
      webview._impl.write_tty = function(_, data)
        graphics[#graphics + 1] = data
      end
      webview._impl.jobsend = function(_, data)
        inputs[#inputs + 1] = data
      end
      webview._impl.jobresize = function(_, cols, rows)
        resized[#resized + 1] = { cols, rows }
      end
      webview._impl.jobstop = function(job)
        stopped[#stopped + 1] = job
      end
      webview._impl.jobstart = function(cmd, opts)
        captured = { cmd = cmd, opts = opts }
        return 42
      end
    end,
    post_case = function()
      for _, session in ipairs(sessions) do
        session:close()
      end
      for key, value in pairs(saved_impl) do
        webview._impl[key] = value
      end
      jove.config = saved_config
    end,
  },
})

local function open()
  local session = assert(webview.open("about:blank"))
  sessions[#sessions + 1] = session
  return session
end

T["available"] = MiniTest.new_set()
T["open"] = MiniTest.new_set()
T["output"] = MiniTest.new_set()
T["resize"] = MiniTest.new_set()
T["close"] = MiniTest.new_set()
T["open_webview"] = MiniTest.new_set()

T["available"]["requires enabled webview, executable browser, and Kitty graphics"] = function()
  MiniTest.expect.equality(webview.available(), true)
  jove.config.webview.enabled = false
  MiniTest.expect.equality(webview.available(), false)
  jove.config.webview.enabled = true
  webview._impl.executable = function()
    return 0
  end
  MiniTest.expect.equality(webview.available(), false)
  webview._impl.executable = function()
    return 1
  end
  webview._impl.terminal_supports_kitty = function()
    return false
  end
  MiniTest.expect.equality(webview.available(), false)
end

T["open"]["creates a terminal buffer and starts the browser on a PTY"] = function()
  local session = open()
  MiniTest.expect.equality(vim.bo[session.buf].buftype, "terminal")
  MiniTest.expect.equality(captured.cmd, { "terminal-browser", "open", "about:blank" })
  MiniTest.expect.equality(captured.opts.pty, true)
  MiniTest.expect.equality(captured.opts.clear_env, true)
  MiniTest.expect.equality(captured.opts.env.PIXEL_EMBED, nil)
  MiniTest.expect.equality(captured.opts.env.PIXEL_TTY, nil)
  MiniTest.expect.equality(captured.opts.env.TERMINAL_BROWSER_NO_MERGE, "1")
  MiniTest.expect.equality(captured.opts.env.TERMINAL_BROWSER_FRAMES, "inline")
  MiniTest.expect.equality(captured.opts.env.TERMINAL_BROWSER_PRESENT, "full")
  MiniTest.expect.equality({ captured.opts.width, captured.opts.height }, {
    vim.api.nvim_win_get_width(session.win),
    vim.api.nvim_win_get_height(session.win),
  })
  MiniTest.expect.equality(vim.api.nvim_win_get_config(session.win).relative, "")
  local maps = vim.api.nvim_buf_get_keymap(session.buf, "n")
  local ours = {}
  for _, map in ipairs(maps) do
    if map.desc and map.desc:find("Jove:", 1, true) then
      ours[#ours + 1] = map.lhs
    end
  end
  MiniTest.expect.equality(ours, { "q" })
  MiniTest.expect.equality(vim.api.nvim_buf_get_keymap(session.buf, "t"), {})
end

T["output"]["forwards terminal replies and renders graphics placeholders"] = function()
  local session = open()
  captured.opts.on_stdout(42, { "\27[16t" })
  MiniTest.expect.equality(inputs[#inputs], "\27[6;20;10t")
  captured.opts.on_stdout(42, { "\27_Ga=T,f=32,s=40,v=60,t=d,i=1,m=0;AAAA\27\\" })
  MiniTest.expect.equality(#graphics, 1)
  MiniTest.expect.equality(graphics[1]:find("U=1", 1, true) ~= nil, true)
  MiniTest.expect.equality(graphics[1]:find("i=" .. session.image_id, 1, true) ~= nil, true)
  MiniTest.expect.equality(session.grid, { cols = 4, rows = 3 })
  vim.wait(20)
  vim.cmd("redraw")
  local lines = vim.api.nvim_buf_get_lines(session.buf, 0, 3, false)
  local placeholder = vim.fn.nr2char(0x10EEEE)
  for _, line in ipairs(lines) do
    local _, count = line:gsub(placeholder, "")
    MiniTest.expect.equality(count, 4)
  end
end

T["resize"]["updates the PTY only when the viewport changes"] = function()
  local session = open()
  session:resize()
  MiniTest.expect.equality(resized, {})
  vim.api.nvim_win_set_width(session.win, 30)
  session:resize()
  MiniTest.expect.equality(#resized, 1)
  MiniTest.expect.equality(resized[1][1], 30)
  MiniTest.expect.equality(session.transport.cols, 30)
end

T["open"]["cleans up the terminal and window when jobstart fails"] = function()
  local before = #vim.api.nvim_list_wins()
  webview._impl.jobstart = function()
    return 0
  end
  local session, err = webview.open("about:blank")
  MiniTest.expect.equality(session, nil)
  MiniTest.expect.equality(err:find("failed to start", 1, true) ~= nil, true)
  MiniTest.expect.equality(#vim.api.nvim_list_wins(), before)
end

T["open"]["reports failure to open the outer terminal"] = function()
  webview._impl.open_tty = function()
    return nil, "no tty"
  end
  local session, err = webview.open("about:blank")
  MiniTest.expect.equality(session, nil)
  MiniTest.expect.equality(err:find("no tty", 1, true) ~= nil, true)
end

T["open"]["cleans up the terminal and window when jobstart raises"] = function()
  local before = #vim.api.nvim_list_wins()
  webview._impl.jobstart = function()
    error("spawn failed")
  end
  local session, err = webview.open("about:blank")
  MiniTest.expect.equality(session, nil)
  MiniTest.expect.equality(err:find("spawn failed", 1, true) ~= nil, true)
  MiniTest.expect.equality(#vim.api.nvim_list_wins(), before)
end

T["close"]["stops the PTY and deletes only the session image exactly once"] = function()
  local session = open()
  local win, buf, term = session.win, session.buf, session.term
  session:close()
  session:close()
  MiniTest.expect.equality(stopped, { 42 })
  MiniTest.expect.equality(
    graphics[#graphics],
    require("jove.webview.kitty").delete(session.image_id)
  )
  MiniTest.expect.equality(vim.api.nvim_win_is_valid(win), false)
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(buf), false)
  MiniTest.expect.equality(vim.api.nvim_get_chan_info(term).buffer, nil)
end

T["close"]["stops the PTY when the buffer is wiped"] = function()
  local session = open()
  vim.api.nvim_buf_delete(session.buf, { force = true })
  MiniTest.expect.equality(session.closed, true)
  MiniTest.expect.equality(stopped, { 42 })
end

T["open_webview"]["opens the cell's latest HTML payload"] = function()
  local state = require("jove.state")
  local cell = require("jove.cell")
  local output = require("jove.output")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %%", "x = 1" })
  state.get(buf).path = "fake.ipynb"
  output.push(buf, cell.all(buf)[1].hash, {
    kind = "execute_result",
    mime = { ["text/html"] = "<b>hi</b>" },
  })
  local opened
  local original = webview.open_html
  webview.open_html = function(html)
    opened = html
    return true
  end
  output.open_webview(buf, 2)
  webview.open_html = original
  MiniTest.expect.equality(opened, "<b>hi</b>")
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["open_webview"]["opens a saved Plotly MIME bundle without HTML"] = function()
  local state = require("jove.state")
  local cell = require("jove.cell")
  local output = require("jove.output")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %%", "fig" })
  state.get(buf).path = "fake.ipynb"
  output.import(buf, {
    [cell.all(buf)[1].hash] = {
      require("jove.persist").to_raw({
        output_type = "display_data",
        data = { ["application/vnd.plotly.v1+json"] = { data = { { y = { 1, 2, 3 } } } } },
      }),
    },
  })
  local opened
  local original = webview.open_html
  webview.open_html = function(html)
    opened = html
    return true
  end
  local ok, err = pcall(output.open_webview, buf, 2)
  webview.open_html = original
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ok, err)
  MiniTest.expect.equality(type(opened), "string")
  MiniTest.expect.equality(opened:find("Plotly.newPlot", 1, true) ~= nil, true)
end

return T

---@diagnostic disable: duplicate-set-field, missing-fields, need-check-nil
local MiniTest = require("mini.test")
local webview = require("jove.webview")
local jove = require("jove")

local function default_webview()
  jove.config.webview.enabled = true
  jove.config.webview.cmd = "terminal-browser"
  jove.config.webview.width = 0.8
  jove.config.webview.height = 0.8
end

local saved_impl, saved_ui

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      default_webview()
      saved_ui = vim.deepcopy(jove.config.ui)
      jove.config.ui.window_mode = "vsplit"
      jove.config.ui.window_overrides = {}
      saved_impl = {
        jobstart = webview._impl.jobstart,
        jobstop = webview._impl.jobstop,
        executable = webview._impl.executable,
        terminal_supports_kitty = webview._impl.terminal_supports_kitty,
        cell_pixels = webview._impl.cell_pixels,
        tty_name = webview._impl.tty_name,
      }
      webview._impl.executable = function()
        return 1
      end
      webview._impl.terminal_supports_kitty = function()
        return true
      end
      webview._impl.cell_pixels = function()
        return 10, 20
      end
      webview._impl.tty_name = function()
        return "/dev/tty"
      end
      webview._impl.jobstop = function() end
    end,
    post_case = function()
      for k, v in pairs(saved_impl) do
        webview._impl[k] = v
      end
      saved_impl = nil
      jove.config.ui = saved_ui
    end,
  },
})

---@param cond any
local function expect_truthy(cond)
  MiniTest.expect.equality(cond == true, true)
end

--- Fake spawn: captures cmd/env, returns a fake job id.
---@return table captured
local function fake_jobstart()
  local captured = {}
  webview._impl.jobstart = function(cmd, opts)
    captured.cmd = cmd
    captured.opts = opts
    return 42
  end
  return captured
end

--- Capture Session:send traffic without a real socket.
---@param session table
---@return table[] sent
local function capture_send(session)
  local sent = {}
  session.conn = {
    is_closing = function()
      return false
    end,
    write = function(_, data)
      sent[#sent + 1] = vim.json.decode((data:gsub("\n$", "")))
    end,
    close = function() end,
  }
  return sent
end

T["available()"] = MiniTest.new_set()

T["available()"]["false when disabled"] = function()
  jove.config.webview.enabled = false
  MiniTest.expect.equality(webview.available(), false)
end

T["available()"]["false without binary"] = function()
  webview._impl.executable = function()
    return 0
  end
  MiniTest.expect.equality(webview.available(), false)
end

T["available()"]["false without kitty graphics"] = function()
  webview._impl.terminal_supports_kitty = function()
    return false
  end
  MiniTest.expect.equality(webview.available(), false)
end

T["available()"]["true when binary + kitty terminal"] = function()
  MiniTest.expect.equality(webview.available(), true)
end

T["open()"] = MiniTest.new_set()

T["open()"]["errors without binary"] = function()
  webview._impl.executable = function()
    return 0
  end
  local session, err = webview.open("https://example.com")
  MiniTest.expect.equality(session, nil)
  expect_truthy(type(err) == "string" and err:find("not found") ~= nil)
end

T["open()"]["errors without kitty terminal"] = function()
  webview._impl.terminal_supports_kitty = function()
    return false
  end
  local session, err = webview.open("https://example.com")
  MiniTest.expect.equality(session, nil)
  expect_truthy(type(err) == "string" and err:find("kitty") ~= nil)
end

T["open()"]["spawns browser with PIXEL_EMBED env and opens a right split by default"] = function()
  local captured = fake_jobstart()
  local session, err = webview.open("https://example.com")
  MiniTest.expect.equality(err, nil)
  expect_truthy(session ~= nil)
  if not session then
    return
  end
  MiniTest.expect.equality(captured.cmd, { "terminal-browser", "open", "https://example.com" })
  MiniTest.expect.equality(captured.opts.env.PIXEL_EMBED, session.sock_path)
  MiniTest.expect.equality(captured.opts.env.PIXEL_TTY, "/dev/tty")
  expect_truthy(vim.api.nvim_win_is_valid(session.win))
  MiniTest.expect.equality(vim.api.nvim_win_get_config(session.win).relative, "")
  expect_truthy(vim.api.nvim_win_get_position(session.win)[2] > 0)
  local win = session.win
  session:close()
  expect_truthy(not vim.api.nvim_win_is_valid(win))
end

T["open()"]["fails cleanly when jobstart fails"] = function()
  webview._impl.jobstart = function()
    return 0
  end
  local session, err = webview.open("https://example.com")
  MiniTest.expect.equality(session, nil)
  expect_truthy(type(err) == "string" and err:find("failed to start") ~= nil)
end

T["protocol"] = MiniTest.new_set()

---@return table session, table[] sent
local function open_session()
  fake_jobstart()
  local session = webview.open("https://example.com")
  assert(session, "session")
  local sent = capture_send(session)
  return session, sent
end

T["protocol"]["join replies with init carrying size, cell and imageId"] = function()
  local session, sent = open_session()
  session:handle({ type = "join" })
  MiniTest.expect.equality(#sent, 1)
  local init = sent[1]
  MiniTest.expect.equality(init.type, "init")
  MiniTest.expect.equality(init.imageId, session.image_id)
  MiniTest.expect.equality(init.transport, "inline")
  MiniTest.expect.equality(init.focused, true)
  MiniTest.expect.equality(init.cell, { 10, 20 })
  MiniTest.expect.equality(init.cols, vim.api.nvim_win_get_width(session.win))
  MiniTest.expect.equality(init.rows, vim.api.nvim_win_get_height(session.win))
  MiniTest.expect.equality(init.width, init.cols * 10)
  MiniTest.expect.equality(init.height, init.rows * 20)
  session:close()
end

T["protocol"]["placed renders kitty placeholder cells in the buffer"] = function()
  local session = open_session()
  session:handle({ type = "placed", imageId = session.image_id, cols = 4, rows = 3 })
  local lines = vim.api.nvim_buf_get_lines(session.buf, 0, -1, false)
  MiniTest.expect.equality(#lines, 3)
  -- every row has 4 placeholder cells (placeholder + 2 diacritics each)
  local placeholder = vim.fn.nr2char(0x10EEEE)
  for _, line in ipairs(lines) do
    local _, count = line:gsub(placeholder, "")
    MiniTest.expect.equality(count, 4)
  end
  -- fg color encodes the image id
  local hl = vim.api.nvim_get_hl(0, { name = ("JoveWebview%x"):format(session.image_id) })
  MiniTest.expect.equality(hl.fg, session.image_id)
  session:close()
end

T["protocol"]["title updates the winbar"] = function()
  local session = open_session()
  session:handle({ type = "title", text = "Plotly chart" })
  MiniTest.expect.equality(session.title, "Plotly chart")
  expect_truthy(vim.wo[session.win].winbar:find("Plotly chart", 1, true) ~= nil)
  session:close()
end

T["input"] = MiniTest.new_set()

T["input"]["send_key forwards press events with text and mods"] = function()
  local session, sent = open_session()
  session:send_key("a", "A", { shift = true })
  MiniTest.expect.equality(sent[1], {
    type = "key",
    key = "a",
    kind = "press",
    mods = { shift = true, alt = false, ctrl = false, super = false },
    text = "A",
  })
  session:close()
end

T["input"]["send_mouse converts cell coords to pixels"] = function()
  local session, sent = open_session()
  session:handle({ type = "placed", imageId = session.image_id, cols = 4, rows = 3 })
  vim.cmd("redraw")
  local origin = vim.fn.screenpos(session.win, 1, 1)
  session.mouse_pos = function()
    return { winid = session.win, screencol = origin.col + 2, screenrow = origin.row + 1 }
  end
  session:send_mouse("down", "left")
  local ev = sent[1]
  MiniTest.expect.equality(ev.type, "mouse")
  MiniTest.expect.equality(ev.kind, "down")
  MiniTest.expect.equality(ev.button, "left")
  -- col 3 -> (3-1)*10 + 5 = 25, row 2 -> (2-1)*20 + 10 = 30
  MiniTest.expect.equality(ev.x, 25)
  MiniTest.expect.equality(ev.y, 30)
  session:close()
end

T["input"]["send_mouse ignores clicks outside the webview window"] = function()
  local session, sent = open_session()
  session:handle({ type = "placed", imageId = session.image_id, cols = 4, rows = 3 })
  session.mouse_pos = function()
    return { winid = -1, wincol = 1, winrow = 1 }
  end
  session:send_mouse("down", "left")
  MiniTest.expect.equality(#sent, 0)
  session:close()
end

T["input"]["real mouse clicks use image coordinates in every layout"] = function()
  local child = MiniTest.new_child_neovim()
  child.start({ "-u", "scripts/minimal_init.lua" })
  local ok, err = pcall(function()
    child.api.nvim_ui_attach(100, 40, { rgb = true })
    child.lua([[
      vim.o.mouse = "a"
      local wv = require("jove.webview")
      wv._impl.executable = function() return 1 end
      wv._impl.terminal_supports_kitty = function() return true end
      wv._impl.cell_pixels = function() return 10, 20 end
      wv._impl.jobstart = function() return 42 end
      wv._impl.jobstop = function() end
    ]])
    for _, mode in ipairs({ "vsplit", "hsplit", "float" }) do
      child.lua(
        [[
        require("jove").config.ui.window_mode = ...
        _G.session = assert(require("jove.webview").open("about:blank"))
        _G.events = {}
        session.send = function(_, msg)
          if msg.type == "mouse" then table.insert(events, msg) end
        end
        vim.cmd("redraw")
      ]],
        { mode }
      )
      -- Opening a window can queue a resize; let it settle before placement.
      child.lua([[vim.wait(20)
        session:handle({ type = "placed", imageId = session.image_id, cols = 4, rows = 3 })
        vim.cmd("redraw")
      ]])
      local origin = child.lua_get("vim.fn.screenpos(session.win, 1, 1)")
      for _, action in ipairs({ "press", "release" }) do
        child.api.nvim_input_mouse("left", action, "", 0, origin.row - 1, origin.col - 1)
      end
      child.lua([[assert(vim.wait(1000, function() return #events == 2 end))]])
      local events = child.lua_get("events")
      MiniTest.expect.equality({ events[1].kind, events[2].kind }, { "down", "up" })
      for _, ev in ipairs(events) do
        MiniTest.expect.equality({ ev.x, ev.y }, { 5, 10 })
      end
      -- Same window, but above/left of the image or beyond the placed grid.
      child.lua([[
        local origin = vim.fn.screenpos(session.win, 1, 1)
        for _, offset in ipairs({ { 0, -1 }, { -1, 0 }, { 4, 0 }, { 0, 3 } }) do
          session.mouse_pos = function()
            return { winid = session.win, screencol = origin.col + offset[1], screenrow = origin.row + offset[2] }
          end
          session:send_mouse("down", "left")
        end
      ]])
      MiniTest.expect.equality(child.lua_get("#events"), 2)
      child.lua("session:close()")
    end
  end)
  child.stop()
  if not ok then
    error(err)
  end
end

T["input"]["interact mode maps printable keys and esc exits"] = function()
  local session, sent = open_session()
  session:enter_interact()
  expect_truthy(session.interact)
  expect_truthy(vim.wo[session.win].winbar:find("INTERACT", 1, true) ~= nil)
  -- printable mapping fires
  local buf = session.buf
  local maps = vim.api.nvim_buf_get_keymap(buf, "n")
  local lhs_set = {}
  for _, m in ipairs(maps) do
    lhs_set[m.lhs] = m
  end
  expect_truthy(lhs_set["a"] ~= nil)
  expect_truthy(lhs_set["<Esc>"] ~= nil)
  expect_truthy(lhs_set["<CR>"] ~= nil)
  -- invoke the "a" mapping callback
  lhs_set["a"].callback()
  MiniTest.expect.equality(sent[#sent].key, "a")
  session:exit_interact()
  expect_truthy(not session.interact)
  MiniTest.expect.equality(#vim.api.nvim_buf_get_keymap(buf, "n") < #maps, true)
  session:close()
end

T["close()"] = MiniTest.new_set()

T["close()"]["stops job, removes socket, closes window; idempotent"] = function()
  fake_jobstart()
  local stopped = {}
  webview._impl.jobstop = function(job)
    stopped[#stopped + 1] = job
  end
  local session = webview.open("https://example.com")
  assert(session, "session")
  local sock = session.sock_path
  local win = session.win
  session:close()
  session:close()
  MiniTest.expect.equality(stopped, { 42 })
  MiniTest.expect.equality(vim.uv.fs_stat(sock), nil)
  expect_truthy(not vim.api.nvim_win_is_valid(win))
end

T["output.open_webview"] = MiniTest.new_set()

T["output.open_webview"]["opens latest text/html payload of the cell"] = function()
  local state = require("jove.state")
  local cell = require("jove.cell")
  local output = require("jove.output")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %%", "x = 1" })
  state.get(buf).path = "fake.ipynb"
  local hash = cell.all(buf)[1].hash
  output.push(buf, hash, {
    kind = "execute_result",
    mime = { ["text/html"] = "<b>hi</b>", ["text/plain"] = "hi" },
  })
  local opened
  package.loaded["jove.webview"] = nil
  -- stub open_html on the real module table
  local real = require("jove.webview")
  local orig = real.open_html
  real.open_html = function(html)
    opened = html
    return true
  end
  vim.api.nvim_set_current_buf(buf)
  output.open_webview(buf, 2)
  MiniTest.expect.equality(opened, "<b>hi</b>")
  real.open_html = orig
  vim.api.nvim_buf_delete(buf, { force = true })
end

return T

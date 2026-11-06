local MiniTest = require("mini.test")
local T = MiniTest.new_set()

T["terminal"] = MiniTest.new_set()

T["terminal"]["forwards native input, resizes, and closes a real PTY in every layout"] = function()
  local child = MiniTest.new_child_neovim()
  local log = vim.fn.tempname()
  child.start({ "-u", "scripts/minimal_init.lua" })
  local ok, err = xpcall(function()
    child.api.nvim_ui_attach(100, 40, { rgb = true })
    child.lua(
      [[
      vim.o.mouse = "a"
      vim.o.mousemoveevent = true
      local wv = require("jove.webview")
      wv._impl.executable = function() return 1 end
      wv._impl.terminal_supports_kitty = function() return true end
      wv._impl.cell_pixels = function() return 10, 20 end
      wv._impl.open_tty = function() return 999 end
      wv._impl.close_tty = function() end
      wv._impl.write_tty = function() end
      local jobstart = wv._impl.jobstart
      local log = ...
      wv._impl.jobstart = function(_, opts)
        return jobstart({ "python3", "-u", "tests/fixtures/webview_terminal.py", log }, opts)
      end
    ]],
      { log }
    )
    for _, mode in ipairs({ "vsplit", "hsplit", "float" }) do
      vim.fn.writefile({}, log)
      child.lua(
        [[
        require("jove").config.ui.window_mode = ...
        _G.session = assert(require("jove.webview").open("about:blank"))
      ]],
        { mode }
      )
      child.lua([[assert(vim.wait(5000, function() return session.grid ~= nil end))]])
      MiniTest.expect.equality(child.lua_get("vim.bo[session.buf].buftype"), "terminal")
      MiniTest.expect.equality(child.lua_get("vim.fn.mode()"), "t")
      child.cmd("redraw")
      local origin = child.lua_get("vim.fn.screenpos(session.win, 1, 1)")
      child.api.nvim_input("é<Esc><C-a><Up>")
      child.api.nvim_paste("pasted\ntext", false, -1)
      child.api.nvim_input_mouse("left", "press", "", 0, origin.row - 1, origin.col - 1)
      child.api.nvim_input_mouse("left", "release", "", 0, origin.row - 1, origin.col - 1)
      local function input_bytes()
        local parts = {}
        for _, line in ipairs(vim.fn.readfile(log)) do
          local entry = vim.json.decode(line)
          if entry.input then
            parts[#parts + 1] = entry.input:gsub("%x%x", function(hex)
              return string.char(tonumber(hex, 16))
            end)
          end
        end
        return table.concat(parts)
      end
      MiniTest.expect.equality(
        vim.wait(3000, function()
          return input_bytes():find("\27[<0;1;1m", 1, true) ~= nil
        end),
        true
      )
      local bytes = input_bytes()
      for _, expected in ipairs({
        "é\27\1",
        "\27[A",
        "\27[200~pasted\ntext\27[201~",
        "\27[<0;1;1M",
        "\27[<0;1;1m",
      }) do
        MiniTest.expect.equality(bytes:find(expected, 1, true) ~= nil, true)
      end
      child.api.nvim_input("<C-\\><C-N>")
      child.lua([[assert(vim.wait(1000, function() return vim.fn.mode() == "n" end))]])
      local axis = mode == "hsplit" and 2 or 1
      local target = axis == 2 and 10 or 25
      child.lua(
        [[
        local axis, target = ...
        if axis == 2 then
          vim.api.nvim_win_set_height(session.win, target)
        else
          vim.api.nvim_win_set_width(session.win, target)
        end
        session:resize()
      ]],
        { axis, target }
      )
      MiniTest.expect.equality(
        vim.wait(3000, function()
          for _, line in ipairs(vim.fn.readfile(log)) do
            local entry = vim.json.decode(line)
            if entry.size and entry.size[axis] == target then
              return true
            end
          end
          return false
        end),
        true
      )
      child.api.nvim_input("q")
      child.lua([[assert(vim.wait(1000, function() return session.closed end))]])
    end
  end, debug.traceback)
  child.stop()
  vim.fn.delete(log)
  if not ok then
    error(err)
  end
end

return T

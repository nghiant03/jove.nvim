local MiniTest = require("mini.test")
local chrome = require("jove.ui.chrome")
local state = require("jove.state")

local T = MiniTest.new_set()

T["code bottom border stays between source and output on screen"] = function()
  local child = MiniTest.new_child_neovim()
  child.start({ "-u", "scripts/minimal_init.lua" })
  local ok, err = pcall(function()
    for _, trailing_blank in ipairs({ false, true }) do
      for _, output_first in ipairs({ false, true }) do
        child.lua(
          [[
          local trailing_blank, output_first = ...
          vim.cmd("enew!")
          local buf = vim.api.nvim_get_current_buf()
          local lines = { "# %%", "print(1)" }
          if trailing_blank then lines[#lines + 1] = "" end
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
          require("jove.state").get(buf).path = "fake.ipynb"
          local chrome = require("jove.ui.chrome")
          if not output_first then chrome.attach(buf) end
          require("jove.output").push(buf, require("jove.cell").all(buf)[1].hash, {
            kind = "stream", name = "stdout", mime = { ["text/plain"] = "hello" },
          })
          if output_first then chrome.attach(buf) end
        ]],
          { trailing_blank, output_first }
        )
        for _ = 1, 3 do
          child.lua([[require("jove.ui.chrome").refresh(vim.api.nvim_get_current_buf())]])
          local rows = child.get_screenshot().text
          local code_row, bottom_row, output_row
          for i, row in ipairs(rows) do
            local text = table.concat(row)
            if text:find("print(1)", 1, true) then
              code_row = i
            end
            if text:find("╰", 1, true) then
              bottom_row = i
            end
            if text:find("┌─ Out", 1, true) then
              output_row = i
            end
          end
          MiniTest.expect.equality(type(code_row), "number")
          MiniTest.expect.equality(bottom_row, code_row + (trailing_blank and 2 or 1))
          MiniTest.expect.equality(output_row, bottom_row + 1)
        end
        child.lua([[
          require("jove").config.output.inside_border = true
          local buf = vim.api.nvim_get_current_buf()
          require("jove.output").refresh_cell(buf, require("jove.cell").all(buf)[1].hash)
          require("jove.ui.chrome").refresh(buf)
        ]])
        local content_row, bottom_row
        for i, row in ipairs(child.get_screenshot().text) do
          local text = table.concat(row)
          if text:find("hello", 1, true) then
            content_row = i
          end
          if text:find("╰", 1, true) then
            bottom_row = i
          end
        end
        MiniTest.expect.equality(type(content_row), "number")
        MiniTest.expect.equality(bottom_row, content_row + 1)
        child.lua([[require("jove").config.output.inside_border = false]])
      end
    end
  end)
  child.stop()
  if not ok then
    error(err)
  end
end

---@param lines string[]
---@return integer buf
local function make_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  state.get(buf).path = "fake.ipynb"
  vim.api.nvim_set_current_buf(buf)
  return buf
end

---@param buf integer
local function release_buffer(buf)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

---@param buf integer
---@return table[]
local function marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, chrome.ns, 0, -1, { details = true })
end

---@param buf integer
---@return integer
local function overlay_rule_count(buf)
  local n = 0
  for _, m in ipairs(marks(buf)) do
    if m[4].virt_text_pos == "overlay" then
      n = n + 1
    end
  end
  return n
end

---@param d table
---@return table[]?
local function rule_chunks(d)
  if d.virt_lines and d.virt_lines_above and d.virt_lines[1] then
    return d.virt_lines[1]
  end
  if d.virt_text_pos == "overlay" then
    return d.virt_text
  end
  return nil
end

---@param buf integer
---@return string[]
local function rule_texts(buf)
  local out = {}
  for _, m in ipairs(marks(buf)) do
    local chunks = rule_chunks(m[4])
    if chunks then
      local parts = {}
      for _, chunk in ipairs(chunks) do
        parts[#parts + 1] = chunk[1]
      end
      out[#out + 1] = table.concat(parts)
    end
  end
  return out
end

---@param buf integer
---@return table?
local function active_mark(buf)
  for _, m in ipairs(marks(buf)) do
    if m[4].line_hl_group == "JoveActiveCell" then
      return m
    end
  end
  return nil
end

---@param texts string[]
---@param needle string
---@return boolean
local function any_contains(texts, needle)
  for _, t in ipairs(texts) do
    if t:find(needle, 1, true) then
      return true
    end
  end
  return false
end

T["conceal"] = MiniTest.new_set()

-- With the read pipeline stripping front matter (buffer.lua), chrome no
-- longer replaces it: a buffer that still contains `# ---` lines directly
-- (as here) gets only header replacement marks.
T["conceal"]["conceals every cell header (front matter is stripped upstream)"] = function()
  local buf = make_buffer({
    "# ---",
    "title: x",
    "# ---",
    "# %% a",
    "x1",
    "# %% [markdown]",
    "# md",
  })
  chrome.refresh(buf)
  MiniTest.expect.equality(overlay_rule_count(buf), 2)
  for _, m in ipairs(marks(buf)) do
    MiniTest.expect.equality(m[4].conceal_lines, nil)
  end
  release_buffer(buf)
end

T["conceal"]["no front matter => only header replacement rules"] = function()
  local buf = make_buffer({ "# %% a", "x1", "# %% b", "y1" })
  chrome.refresh(buf)
  MiniTest.expect.equality(overlay_rule_count(buf), 2)
  release_buffer(buf)
end

T["conceal"]["conceal_headers = false disables header replacement"] = function()
  local cfg = require("jove").config
  local saved = cfg.ui
  cfg.ui = { conceal_headers = false }
  local buf = make_buffer({ "# ---", "t: x", "# ---", "# %% a", "x1" })
  chrome.refresh(buf)
  MiniTest.expect.equality(overlay_rule_count(buf), 0)
  cfg.ui = saved
  release_buffer(buf)
end

T["rules"] = MiniTest.new_set()

T["rules"]["renders one rule per non-empty cell body above it"] = function()
  local buf = make_buffer({ "# %% a", "x1", "# %% [markdown]", "# md" })
  chrome.refresh(buf)
  local texts = rule_texts(buf)
  MiniTest.expect.equality(#texts, 2)
  MiniTest.expect.equality(any_contains(texts, "── markdown "), true)
  MiniTest.expect.equality(any_contains(texts, "○"), true) -- unread glyph
  release_buffer(buf)
end

T["rules"]["renders count/elapsed/status from exec.meta and status"] = function()
  local buf = make_buffer({ "# %% a", "x1" })
  local hash = require("jove.cell").all(buf)[1].hash
  state.get(buf).exec =
    { status = { [hash] = "ok" }, meta = { [hash] = { count = 3, elapsed_ms = 400 } } }
  chrome.refresh(buf)
  local texts = rule_texts(buf)
  MiniTest.expect.equality(any_contains(texts, "✓"), true)
  MiniTest.expect.equality(any_contains(texts, "In [3]"), true)
  MiniTest.expect.equality(any_contains(texts, "0.4s"), true)
  MiniTest.expect.equality(any_contains(texts, "Cell 1"), true)
  release_buffer(buf)
end

T["rules"]["exec_counts/elapsed = false omit those chunks"] = function()
  local cfg = require("jove").config
  local saved = cfg.ui
  cfg.ui = { exec_counts = false, elapsed = false }
  local buf = make_buffer({ "# %% a", "x1" })
  local hash = require("jove.cell").all(buf)[1].hash
  state.get(buf).exec =
    { status = { [hash] = "running" }, meta = { [hash] = { count = 7, elapsed_ms = 1200 } } }
  chrome.refresh(buf)
  local texts = rule_texts(buf)
  MiniTest.expect.equality(any_contains(texts, "In ["), false)
  MiniTest.expect.equality(any_contains(texts, "1.2s"), false)
  MiniTest.expect.equality(any_contains(texts, "⠋"), true)
  cfg.ui = saved
  release_buffer(buf)
end

T["rules"]["no kernel state does not crash and renders a blank-count rule"] = function()
  local buf = make_buffer({ "# %% a", "x1" })
  local ok = pcall(chrome.refresh, buf)
  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(#rule_texts(buf), 1)
  release_buffer(buf)
end

T["active cell"] = MiniTest.new_set()

T["active cell"]["highlights the body of the cell under the cursor"] = function()
  local buf = make_buffer({ "# %% a", "x1", "x2", "# %% b", "y1" })
  chrome.refresh(buf)
  vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- inside cell a body
  chrome.refresh_active(buf)
  local m = active_mark(buf)
  MiniTest.expect.equality(m ~= nil, true)
  MiniTest.expect.equality(m[2], 1) -- row 1 (line 2)
  MiniTest.expect.equality(m[4].end_row, 2) -- through line 3
  release_buffer(buf)
end

T["active cell"]["CursorMoved autocmd updates the highlight"] = function()
  local buf = make_buffer({ "# %% a", "x1", "# %% b", "y1", "y2" })
  chrome.attach(buf)
  vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- cell a body (line 2)
  vim.cmd("doautocmd CursorMoved")
  local m1 = active_mark(buf)
  MiniTest.expect.equality(m1 ~= nil, true)
  MiniTest.expect.equality(m1[2], 1)

  vim.api.nvim_win_set_cursor(0, { 4, 0 }) -- cell b body (line 4)
  vim.cmd("doautocmd CursorMoved")
  local m2 = active_mark(buf)
  MiniTest.expect.equality(m2 ~= nil, true)
  MiniTest.expect.equality(m2[2], 3)
  MiniTest.expect.equality(m2[4].end_row, 4)
  release_buffer(buf)
end

T["active cell"]["active_cell = false draws no highlight"] = function()
  local cfg = require("jove").config
  local saved = cfg.ui
  cfg.ui = { active_cell = false }
  local buf = make_buffer({ "# %% a", "x1" })
  chrome.refresh(buf)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  chrome.refresh_active(buf)
  MiniTest.expect.equality(active_mark(buf), nil)
  cfg.ui = saved
  release_buffer(buf)
end

T["detach"] = MiniTest.new_set()

T["detach"]["clears all chrome extmarks"] = function()
  local buf = make_buffer({ "# ---", "t: x", "# ---", "# %% a", "x1" })
  chrome.attach(buf)
  MiniTest.expect.equality(#marks(buf) > 0, true)
  chrome.detach(buf)
  MiniTest.expect.equality(#marks(buf), 0)
  release_buffer(buf)
end

T["borders"] = MiniTest.new_set()

T["borders"]["top rule uses box corners and cell index"] = function()
  local buf = make_buffer({ "# %% a", "x1", "# %% b", "y1" })
  chrome.refresh(buf)
  local texts = rule_texts(buf)
  MiniTest.expect.equality(#texts, 2)
  MiniTest.expect.equality(any_contains(texts, "╭─"), true)
  MiniTest.expect.equality(any_contains(texts, "╮"), true)
  MiniTest.expect.equality(any_contains(texts, "Cell 1"), true)
  MiniTest.expect.equality(any_contains(texts, "Cell 2"), true)
  release_buffer(buf)
end

T["borders"]["bottom border drawn below cell end"] = function()
  local buf = make_buffer({ "# %% a", "x1", "# %% b", "y1" })
  chrome.refresh(buf)
  local found = false
  for _, m in ipairs(marks(buf)) do
    local d = m[4]
    if
      d.virt_lines
      and not d.virt_lines_above
      and d.virt_lines[1]
      and d.virt_lines[1][1]
      and d.virt_lines[1][1][1] == "╰"
    then
      found = true
      break
    end
  end
  MiniTest.expect.equality(found, true)
  release_buffer(buf)
end

T["borders"]["borders = false disables the bottom border but keeps the top"] = function()
  local cfg = require("jove").config
  local saved = cfg.ui
  cfg.ui = { borders = false }
  local buf = make_buffer({ "# %% a", "x1" })
  chrome.refresh(buf)
  local below = 0
  for _, m in ipairs(marks(buf)) do
    local d = m[4]
    if d.virt_lines and not d.virt_lines_above and m[2] == 0 then
      below = below + 1
    end
  end
  MiniTest.expect.equality(below, 0)
  MiniTest.expect.equality(any_contains(rule_texts(buf), "╭─"), true)
  cfg.ui = saved
  release_buffer(buf)
end

T["border_hl"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      -- JoveCellBorder is a module-level global; restore its documented
      -- default before each subcase so attrs leaking from a previous test
      -- cannot be mistaken for a passed assertion.
      vim.api.nvim_set_hl(0, "JoveCellBorder", { link = "Comment", default = false })
    end,
    post_case = function()
      vim.api.nvim_set_hl(0, "JoveCellBorder", { link = "Comment", default = false })
    end,
  },
})

T["border_hl"]["string value links JoveCellBorder to the named group"] = function()
  local cfg = require("jove").config
  local saved = cfg.ui
  vim.api.nvim_set_hl(0, "MyBorder", { fg = "#ff9e64" })
  cfg.ui = { border_hl = "MyBorder" }
  local buf = make_buffer({ "# %% a", "x1" })
  chrome.refresh(buf)
  -- The rendered rule still addresses JoveCellBorder (not MyBorder), but the
  -- group now resolves MyBorder through the link.
  local found = false
  for _, m in ipairs(marks(buf)) do
    for _, chunk in ipairs(rule_chunks(m[4]) or {}) do
      if chunk[2] == "JoveCellBorder" then
        found = true
        break
      end
    end
  end
  MiniTest.expect.equality(found, true)
  cfg.ui = saved
  release_buffer(buf)
end

T["border_hl"]["table value passes attrs straight to nvim_set_hl"] = function()
  local cfg = require("jove").config
  local saved = cfg.ui
  cfg.ui = { border_hl = { fg = "#ff9e64" } }
  local buf = make_buffer({ "# %% a", "x1" })
  chrome.refresh(buf)
  local got = vim.api.nvim_get_hl(0, { name = "JoveCellBorder" })
  MiniTest.expect.equality(got.fg, 0xff9e64)
  MiniTest.expect.equality(got.link, nil)
  cfg.ui = saved
  release_buffer(buf)
end

T["border_hl"]["nil leaves JoveCellBorder at the default Comment link"] = function()
  -- pre_case already reset to the link form; emulate "the user never set
  -- border_hl" with cfg.ui empty.
  local cfg = require("jove").config
  local saved = cfg.ui
  cfg.ui = {}
  local buf = make_buffer({ "# %% a", "x1" })
  chrome.refresh(buf)
  local got = vim.api.nvim_get_hl(0, { name = "JoveCellBorder" })
  MiniTest.expect.equality(got.link, "Comment")
  MiniTest.expect.equality(got.fg, nil)
  cfg.ui = saved
  release_buffer(buf)
end

return T

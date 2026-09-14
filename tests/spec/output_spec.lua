-- output_spec.lua: per-cell output store, extmark rendering, truncation,
-- toggle, clear, import. No kernel/bridge involved — push() is called directly.
local MiniTest = require("mini.test")
local state = require("jove.state")
local cell = require("jove.cell")
local output = require("jove.output")
local jove = require("jove")

local T = MiniTest.new_set()

---mini.test has no truthy expectation; assert identity against true.
---@param cond any
local function expect_truthy(cond)
  MiniTest.expect.equality(cond == true, true)
end

---Create a scratch buffer with jupytext-style py:percent cells and register it
---as a jove buffer (state entry, like buffer.lua does on read).
---@param lines string[]
---@return integer buf
local function make_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  state.get(buf).path = "fake.ipynb"
  return buf
end

---@param buf integer
local function release_buffer(buf)
  -- BufWipeout cleanup drops the state entry too.
  vim.api.nvim_buf_delete(buf, { force = true })
end

---First cell's hash (the fixtures below use a single interesting cell).
---@param buf integer
---@param idx integer?
---@return string
local function cell_hash(buf, idx)
  return cell.all(buf)[idx or 1].hash
end

---Extmark info for a cell's output: { row (1-based), virt_lines } or nil.
---@param buf integer
---@param hash string
---@return table?
local function extmark_of(buf, hash)
  local entry = state.peek(buf).outputs and state.peek(buf).outputs[hash]
  if not entry or not entry.extmark_id then
    return nil
  end
  local ok, ext =
    pcall(vim.api.nvim_buf_get_extmark_by_id, buf, output.ns, entry.extmark_id, { details = true })
  if not ok then
    return nil
  end
  return { row = ext[1] + 1, virt_lines = ext[3].virt_lines, priority = ext[3].priority }
end

---@param s string
---@param prefix string
---@return boolean
local function starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

---Flatten virt_lines into plain text lines for assertions.
---@param virt_lines table
---@return string[]
local function texts(virt_lines)
  local out = {}
  for _, line in ipairs(virt_lines) do
    local parts = {}
    for _, seg in ipairs(line) do
      parts[#parts + 1] = seg[1]
    end
    out[#out + 1] = table.concat(parts)
  end
  return out
end

T["push"] = MiniTest.new_set()

T["push"]["stores the event and renders virt_lines below the cell end"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)
  local end_lnum = cell.all(buf)[1].end_lnum

  output.push(buf, hash, { kind = "stream", name = "stdout", mime = { ["text/plain"] = "hello" } })

  local entry = state.peek(buf).outputs[hash]
  MiniTest.expect.equality(#entry.raw, 1)
  local ext = extmark_of(buf, hash)
  expect_truthy(ext ~= nil)
  MiniTest.expect.equality(ext.row, end_lnum) -- virt_lines appear below end_lnum
  local t = texts(ext.virt_lines)
  MiniTest.expect.equality(#t, 2)
  expect_truthy(starts_with(t[1], "└─ "))
  expect_truthy(t[1]:find("Out", 1, true) ~= nil)
  MiniTest.expect.equality(t[1]:find("Out[", 1, true), nil) -- count unknown: bare "Out"
  MiniTest.expect.equality(t[2], "▎ hello")
  release_buffer(buf)
end

T["push"]["appends incrementally without duplicating the extmark"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)

  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "one" } })
  local first = extmark_of(buf, hash)
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "two" } })
  local second = extmark_of(buf, hash)

  local entry = state.peek(buf).outputs[hash]
  MiniTest.expect.equality(#entry.raw, 2)
  local t = texts(second.virt_lines)
  MiniTest.expect.equality(#t, 3)
  expect_truthy(starts_with(t[1], "└─ "))
  MiniTest.expect.equality(t[2], "▎ one")
  MiniTest.expect.equality(t[3], "▎ two")
  expect_truthy(second.extmark_id == first.extmark_id)
  -- exactly one extmark in the output namespace for the whole buffer
  MiniTest.expect.equality(#vim.api.nvim_buf_get_extmarks(buf, output.ns, 0, -1, {}), 1)
  release_buffer(buf)
end

T["push"]["unknown hash is stored but not rendered"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  output.push(buf, "deadbeef", { kind = "stream", mime = { ["text/plain"] = "x" } })

  local st = state.peek(buf)
  expect_truthy(st.outputs["deadbeef"] ~= nil)
  MiniTest.expect.equality(#vim.api.nvim_buf_get_extmarks(buf, output.ns, 0, -1, {}), 0)
  release_buffer(buf)
end

T["push"]["is a silent no-op on non-jove buffers"] = function()
  -- A buffer with no state entry at all (never registered by buffer.lua):
  -- push must not create one. Note we cannot use cell.all() here, since the
  -- cell cache registers state as a side effect.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %% a", "print(1)" })
  output.push(buf, "deadbeef", { kind = "stream", mime = { ["text/plain"] = "x" } })
  expect_truthy(state.peek(buf) == nil)
  release_buffer(buf)
end

T["push"]["renders a text placeholder for image chunks"] = function()
  local buf = make_buffer({ "# %% a", "import matplotlib" })
  local hash = cell_hash(buf)
  output.push(buf, hash, { kind = "display_data", mime = { ["image/png"] = "iVBORw0KGgo=" } })
  local ext = extmark_of(buf, hash)
  MiniTest.expect.equality(texts(ext.virt_lines)[2], "▎ [image: image/png]")
  release_buffer(buf)
end

T["push"]["survives an error event with ANSI traceback"] = function()
  local buf = make_buffer({ "# %% a", "1/0" })
  local hash = cell_hash(buf)
  output.push(buf, hash, {
    kind = "error",
    ename = "ZeroDivisionError",
    evalue = "division by zero",
    traceback = { "\27[0;31mZeroDivisionError\27[0m" },
  })
  local ext = extmark_of(buf, hash)
  local t = texts(ext.virt_lines)
  expect_truthy(starts_with(t[1], "└─ "))
  MiniTest.expect.equality(t[2], "▎ ZeroDivisionError: division by zero")
  MiniTest.expect.equality(t[3], "▎ ZeroDivisionError")
  release_buffer(buf)
end

T["priority"] = MiniTest.new_set()

T["priority"]["output extmark sorts below the cell border (priority 200)"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "hi" } })
  MiniTest.expect.equality(extmark_of(buf, hash).priority, 200)
  release_buffer(buf)
end

T["priority"]["inside_border = true restores the default extmark priority"] = function()
  local orig = jove.config.output.inside_border
  jove.config.output.inside_border = true
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "hi" } })
  expect_truthy(extmark_of(buf, hash).priority ~= 200)
  jove.config.output.inside_border = orig
  release_buffer(buf)
end

T["decoration"] = MiniTest.new_set()

T["decoration"]["header = false omits the rule and keeps content only"] = function()
  local orig = jove.config.output.header
  jove.config.output.header = false
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "hi" } })
  MiniTest.expect.equality(texts(extmark_of(buf, hash).virt_lines), { "▎ hi" })
  jove.config.output.header = orig
  release_buffer(buf)
end

T["decoration"]["guide = false omits the rail"] = function()
  local orig = jove.config.output.guide
  jove.config.output.guide = false
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "hi" } })
  MiniTest.expect.equality(texts(extmark_of(buf, hash).virt_lines)[2], "hi")
  jove.config.output.guide = orig
  release_buffer(buf)
end

T["decoration"]["custom guide string is used verbatim"] = function()
  local orig = jove.config.output.guide
  jove.config.output.guide = "│ "
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "hi" } })
  MiniTest.expect.equality(texts(extmark_of(buf, hash).virt_lines)[2], "│ hi")
  jove.config.output.guide = orig
  release_buffer(buf)
end

T["decoration"]["error output switches the rail to JoveOutputGuideError"] = function()
  local buf = make_buffer({ "# %% a", "1/0" })
  local hash = cell_hash(buf)
  output.push(buf, hash, {
    kind = "error",
    ename = "ZeroDivisionError",
    evalue = "division by zero",
    traceback = { "ZeroDivisionError" },
  })
  local rail = extmark_of(buf, hash).virt_lines[2][1]
  MiniTest.expect.equality(rail[1], "▎ ")
  MiniTest.expect.equality(rail[2], "JoveOutputGuideError")
  release_buffer(buf)
end

T["refresh_cell"] = MiniTest.new_set()

T["refresh_cell"]["picks up the execution count for the header"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "hi" } })
  expect_truthy(texts(extmark_of(buf, hash).virt_lines)[1]:find("Out[", 1, true) == nil)
  state.peek(buf).exec = { meta = { [hash] = { count = 3 } } }
  output.refresh_cell(buf, hash)
  local header = texts(extmark_of(buf, hash).virt_lines)[1]
  expect_truthy(header:find("Out[3] ", 1, true) ~= nil)
  release_buffer(buf)
end

T["clear"] = MiniTest.new_set()

T["clear"]["drops one cell's extmark and store entry"] = function()
  local buf = make_buffer({ "# %% a", "x", "# %% b", "y" })
  local h1, h2 = cell.all(buf)[1].hash, cell.all(buf)[2].hash
  output.push(buf, h1, { kind = "stream", mime = { ["text/plain"] = "a" } })
  output.push(buf, h2, { kind = "stream", mime = { ["text/plain"] = "b" } })

  output.clear(buf, h1)
  expect_truthy(state.peek(buf).outputs[h1] == nil)
  expect_truthy(state.peek(buf).outputs[h2] ~= nil)
  expect_truthy(extmark_of(buf, h1) == nil)
  expect_truthy(extmark_of(buf, h2) ~= nil)
  release_buffer(buf)
end

T["clear"]["without a hash clears the whole buffer"] = function()
  local buf = make_buffer({ "# %% a", "x", "# %% b", "y" })
  local h1, h2 = cell.all(buf)[1].hash, cell.all(buf)[2].hash
  output.push(buf, h1, { kind = "stream", mime = { ["text/plain"] = "a" } })
  output.push(buf, h2, { kind = "stream", mime = { ["text/plain"] = "b" } })

  output.clear(buf)
  expect_truthy(state.peek(buf).outputs == nil)
  MiniTest.expect.equality(#vim.api.nvim_buf_get_extmarks(buf, output.ns, 0, -1, {}), 0)
  release_buffer(buf)
end

T["toggle"] = MiniTest.new_set()

T["toggle"]["hides and re-shows a cell's virt_lines"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "hello" } })

  local lnum = 1
  output.toggle(buf, lnum)
  expect_truthy(state.peek(buf).outputs[hash].hidden == true)
  expect_truthy(extmark_of(buf, hash) == nil)

  output.toggle(buf, lnum)
  expect_truthy(state.peek(buf).outputs[hash].hidden == false)
  expect_truthy(extmark_of(buf, hash) ~= nil)
  release_buffer(buf)
end

T["toggle"]["ignores cells without outputs and buffers without a store"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  output.toggle(buf, 1) -- no outputs yet: must not error
  expect_truthy(state.peek(buf).outputs == nil)
  release_buffer(buf)
end

T["truncation"] = MiniTest.new_set()

T["truncation"]["caps virt_lines at output.max_lines with a float trailer"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)
  local orig = jove.config.output.max_lines
  jove.config.output.max_lines = 3
  local lines = {}
  for i = 1, 10 do
    lines[#lines + 1] = ("line%d"):format(i)
  end
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = table.concat(lines, "\n") } })

  local ext = extmark_of(buf, hash)
  local t = texts(ext.virt_lines)
  -- header + 3 content lines + trailer
  MiniTest.expect.equality(#t, 5)
  expect_truthy(starts_with(t[1], "└─ "))
  MiniTest.expect.equality(t[2], "▎ line1")
  MiniTest.expect.equality(t[4], "▎ line3")
  MiniTest.expect.equality(t[5], "▎ … +7 lines · :JoveOpenOutput")

  jove.config.output.max_lines = orig
  -- Re-render at restored config shows everything again on next push.
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "done" } })
  ext = extmark_of(buf, hash)
  MiniTest.expect.equality(#texts(ext.virt_lines), 12) -- header + 11 content
  release_buffer(buf)
end

T["import"] = MiniTest.new_set()

T["import"]["bulk-attaches outputs by hash and renders them"] = function()
  local buf = make_buffer({ "# %% a", "print(1)", "# %% b", "print(2)" })
  local h1, h2 = cell.all(buf)[1].hash, cell.all(buf)[2].hash

  output.import(buf, {
    [h1] = {
      { kind = "stream", mime = { ["text/plain"] = "a1" } },
      { kind = "stream", mime = { ["text/plain"] = "a2" } },
    },
    [h2] = { { kind = "stream", mime = { ["text/plain"] = "b1" } } },
  })

  local st = state.peek(buf)
  MiniTest.expect.equality(#st.outputs[h1].raw, 2)
  local t1 = texts(extmark_of(buf, h1).virt_lines)
  MiniTest.expect.equality(t1[2], "▎ a1")
  MiniTest.expect.equality(t1[3], "▎ a2")
  MiniTest.expect.equality(texts(extmark_of(buf, h2).virt_lines)[2], "▎ b1")
  release_buffer(buf)
end

T["import"]["ignores unknown hashes and non-jove buffers without erroring"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  output.import(buf, { deadbeef = { { kind = "stream", mime = { ["text/plain"] = "x" } } } })
  expect_truthy(state.peek(buf).outputs["deadbeef"] ~= nil)
  MiniTest.expect.equality(#vim.api.nvim_buf_get_extmarks(buf, output.ns, 0, -1, {}), 0)

  local orphan = vim.api.nvim_create_buf(false, true)
  output.import(orphan, { deadbeef = {} }) -- must not error
  expect_truthy(state.peek(orphan) == nil)
  release_buffer(buf)
  release_buffer(orphan)
end

T["buf = 0 (current buffer)"] = MiniTest.new_set()

-- Regression: plugin commands pass buf = 0; state.peek does not normalize it,
-- so public functions must do it themselves or silently no-op.

T["buf = 0 (current buffer)"]["toggle(0, lnum) toggles the current buffer's cell"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "hello" } })
  vim.api.nvim_set_current_buf(buf)

  output.toggle(0, 1)
  expect_truthy(state.peek(buf).outputs[hash].hidden == true)
  expect_truthy(extmark_of(buf, hash) == nil)

  output.toggle(0, 1)
  expect_truthy(state.peek(buf).outputs[hash].hidden == false)
  expect_truthy(extmark_of(buf, hash) ~= nil)

  release_buffer(buf)
end

T["buf = 0 (current buffer)"]["clear(0, hash) and clear(0) clear the current buffer"] = function()
  local buf = make_buffer({ "# %% a", "x", "# %% b", "y" })
  local h1, h2 = cell.all(buf)[1].hash, cell.all(buf)[2].hash
  output.push(buf, h1, { kind = "stream", mime = { ["text/plain"] = "a" } })
  output.push(buf, h2, { kind = "stream", mime = { ["text/plain"] = "b" } })
  vim.api.nvim_set_current_buf(buf)

  output.clear(0, h1)
  expect_truthy(state.peek(buf).outputs[h1] == nil)
  expect_truthy(extmark_of(buf, h1) == nil)
  expect_truthy(extmark_of(buf, h2) ~= nil)

  output.clear(0)
  expect_truthy(state.peek(buf).outputs == nil)
  expect_truthy(extmark_of(buf, h2) == nil)

  release_buffer(buf)
end

T["buf = 0 (current buffer)"]["push(0, ...) attaches to the current buffer"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  vim.api.nvim_set_current_buf(buf)
  output.push(0, cell_hash(buf), { kind = "stream", mime = { ["text/plain"] = "hello" } })
  local ext = extmark_of(buf, cell_hash(buf))
  expect_truthy(ext ~= nil)
  MiniTest.expect.equality(texts(ext.virt_lines)[2], "▎ hello")
  release_buffer(buf)
end

T["open_float"] = MiniTest.new_set()

T["open_float"]["shows untruncated output and closes on demand"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)
  local orig = jove.config.output.max_lines
  jove.config.output.max_lines = 2
  local lines = {}
  for i = 1, 8 do
    lines[#lines + 1] = ("l%d"):format(i)
  end
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = table.concat(lines, "\n") } })

  local before = vim.api.nvim_get_current_win()
  local win = output.open_float(buf, 1)
  expect_truthy(win ~= nil)
  expect_truthy(vim.api.nvim_win_is_valid(win))
  local fbuf = vim.api.nvim_win_get_buf(win)
  MiniTest.expect.equality(vim.api.nvim_buf_line_count(fbuf), 8)
  local float_lines = vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)
  MiniTest.expect.equality(float_lines[1], "l1") -- raw, undecorated (no header/rail)
  for _, l in ipairs(float_lines) do
    MiniTest.expect.equality(l:find("└─", 1, true), nil)
    expect_truthy(not starts_with(l, "▎ "))
  end

  -- q closes the float and restores the previous window.
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys("q", "mx", false)
  expect_truthy(not vim.api.nvim_win_is_valid(win))
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), before)

  jove.config.output.max_lines = orig
  release_buffer(buf)
end

T["open_float"]["returns nil when there is nothing to show"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  MiniTest.expect.equality(output.open_float(buf, 1), nil) -- no outputs at all
  output.push(buf, cell_hash(buf), { kind = "stream", mime = { ["text/plain"] = "x" } })
  expect_truthy(output.open_float(buf, 1) ~= nil)
  vim.cmd("silent! close") -- tidy: close the float we just opened
  release_buffer(buf)
end

T["open_float"]["renders the float with treesitter highlighting best-effort"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  vim.bo[buf].filetype = "python"
  local hash = cell_hash(buf)
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "x = 1" } })
  local win = output.open_float(buf, 1)
  expect_truthy(win ~= nil)
  MiniTest.expect.equality(vim.bo[vim.api.nvim_win_get_buf(win)].filetype, "python")
  vim.api.nvim_win_close(win, true)
  release_buffer(buf)
end

return T

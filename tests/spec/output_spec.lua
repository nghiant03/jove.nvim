local MiniTest = require("mini.test")
local state = require("jove.state")
local cell = require("jove.cell")
local output = require("jove.output")
local jove = require("jove")

local function default_output()
  jove.config.output.max_lines = 50
  jove.config.output.images = true
  jove.config.output.image_max_width = 80
  jove.config.output.image_max_height = 40
  jove.config.output.header = true
  jove.config.output.guide = "▎ "
  jove.config.output.inside_border = false
  jove.config.output.hl = nil
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = default_output,
    post_case = function()
      package.loaded["snacks.image"] = nil
    end,
  },
})

---@param cond any
local function expect_truthy(cond)
  MiniTest.expect.equality(cond == true, true)
end

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
  vim.api.nvim_buf_delete(buf, { force = true })
end

---@param buf integer
---@param idx integer?
---@return string
local function cell_hash(buf, idx)
  return cell.all(buf)[idx or 1].hash
end

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

---@param suffix string
---@return boolean
local function ends_with(s, suffix)
  return s:sub(-#suffix) == suffix
end

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
  MiniTest.expect.equality(ext.row, end_lnum)
  local t = texts(ext.virt_lines)
  MiniTest.expect.equality(#t, 3)
  expect_truthy(starts_with(t[1], "┌─ "))
  expect_truthy(t[1]:find("Out", 1, true) ~= nil)
  MiniTest.expect.equality(t[1]:find("Out[", 1, true), nil)
  expect_truthy(starts_with(t[2], "▎ hello"))
  expect_truthy(t[2]:find("│", 1, true) == nil)
  expect_truthy(starts_with(t[3], "└"))
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
  MiniTest.expect.equality(#entry.chunks, 1)
  local t = texts(second.virt_lines)
  MiniTest.expect.equality(#t, 3)
  expect_truthy(starts_with(t[1], "┌─ "))
  expect_truthy(starts_with(t[2], "▎ onetwo") and t[2]:find("│", 1, true) == nil)
  expect_truthy(starts_with(t[3], "└"))
  expect_truthy(second.extmark_id == first.extmark_id)
  MiniTest.expect.equality(#vim.api.nvim_buf_get_extmarks(buf, output.ns, 0, -1, {}), 1)
  release_buffer(buf)
end

T["push"]["folds carriage returns so progress bars render as one line"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)

  output.push(
    buf,
    hash,
    { kind = "stream", name = "stderr", mime = { ["text/plain"] = "\r 10%|one" } }
  )
  output.push(
    buf,
    hash,
    { kind = "stream", name = "stderr", mime = { ["text/plain"] = "\r 20%|two\n" } }
  )

  local entry = state.peek(buf).outputs[hash]
  MiniTest.expect.equality(#entry.chunks, 1)
  MiniTest.expect.equality(entry.chunks[1].text, " 20%|two\n")
  MiniTest.expect.equality(#entry.raw, 2)
  MiniTest.expect.equality(entry.raw[1].mime["text/plain"], "\r 10%|one")
  local t = texts(extmark_of(buf, hash).virt_lines)
  expect_truthy(starts_with(t[2], "▎  20%|two"))
  expect_truthy(t[2]:find("\r", 1, true) == nil)
  release_buffer(buf)
end

T["push"]["folds multiple carriage returns within a single event"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)

  output.push(buf, hash, {
    kind = "stream",
    name = "stderr",
    mime = { ["text/plain"] = "\r 10%|one\r 20%|two\r 30%|three" },
  })

  local entry = state.peek(buf).outputs[hash]
  MiniTest.expect.equality(entry.chunks[1].text, " 30%|three")
  release_buffer(buf)
end

T["push"]["renders ANSI SGR styling as highlight groups"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)

  output.push(buf, hash, {
    kind = "stream",
    name = "stdout",
    mime = { ["text/plain"] = '\27[1mModel: "seq"\27[0m \27[38;5;34m28,842\27[0m' },
  })

  local ext = extmark_of(buf, hash)
  local t = texts(ext.virt_lines)
  expect_truthy(starts_with(t[2], '▎ Model: "seq" 28,842'))
  expect_truthy(t[2]:find("\27", 1, true) == nil)

  local styled = {}
  for _, seg in ipairs(ext.virt_lines[2]) do
    if seg[2] and seg[2]:match("^JoveAnsi") then
      styled[seg[1]] = vim.api.nvim_get_hl(0, { name = seg[2], link = false })
    end
  end
  MiniTest.expect.equality(styled['Model: "seq"'].bold, true)
  MiniTest.expect.equality(string.format("#%06x", styled["28,842"].fg), "#00af00")
  release_buffer(buf)
end

T["push"]["renders ANSI sequences split across stream events"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)

  output.push(buf, hash, {
    kind = "stream",
    name = "stdout",
    mime = { ["text/plain"] = "a\27[38;5;" },
  })
  output.push(buf, hash, {
    kind = "stream",
    name = "stdout",
    mime = { ["text/plain"] = "34mgreen\27[0m tail" },
  })

  local ext = extmark_of(buf, hash)
  local t = texts(ext.virt_lines)
  expect_truthy(starts_with(t[2], "▎ agreen tail"))
  local styled = {}
  for _, seg in ipairs(ext.virt_lines[2]) do
    if seg[2] and seg[2]:match("^JoveAnsi") then
      styled[#styled + 1] = seg[1]
    end
  end
  MiniTest.expect.equality(styled, { "green" })
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
  local t = texts(ext.virt_lines)
  MiniTest.expect.equality(#t, 3)
  expect_truthy(starts_with(t[2], "▎ [image:"))
  release_buffer(buf)
end

---@param supported boolean?  Value returned by the stub's supports(); default true
local function stub_snacks(supported)
  local calls, closed = {}, {}
  package.loaded["snacks.image"] = {
    supports = function()
      return supported ~= false
    end,
    placement = {
      new = function(b, src, opts)
        calls[#calls + 1] = { buf = b, src = src, opts = opts }
        local handle = {}
        function handle.close(self)
          closed[#closed + 1] = self
        end
        return handle
      end,
    },
  }
  return calls, closed
end

T["images"] = MiniTest.new_set()

T["images"]["places chunks via snacks.image.placement anchored at the cell end"] = function()
  local calls = stub_snacks()
  local buf = make_buffer({ "# %% a", "import matplotlib", "plt.plot()" })
  local hash = cell_hash(buf)
  local end_lnum = cell.all(buf)[1].end_lnum
  local data =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

  output.push(buf, hash, { kind = "display_data", mime = { ["image/png"] = data } })

  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(calls[1].buf, buf)
  MiniTest.expect.equality(calls[1].opts.pos, { end_lnum, 0 })
  MiniTest.expect.equality(calls[1].opts.inline, true)
  MiniTest.expect.equality(calls[1].opts.max_width, 80)
  MiniTest.expect.equality(calls[1].opts.max_height, 40)
  expect_truthy(ends_with(calls[1].src, ".png"))
  MiniTest.expect.equality(vim.uv.fs_stat(calls[1].src).size, #vim.base64.decode(data))
  release_buffer(buf)
end

---@param buf integer
---@param hash string
---@return table?
local function extmark_below_of(buf, hash)
  local entry = state.peek(buf).outputs and state.peek(buf).outputs[hash]
  if not entry or not entry.extmark_id_below then
    return nil
  end
  local ok, ext = pcall(
    vim.api.nvim_buf_get_extmark_by_id,
    buf,
    output.ns,
    entry.extmark_id_below,
    { details = true }
  )
  if not ok then
    return nil
  end
  return {
    row = ext[1] + 1,
    virt_lines = ext[3].virt_lines,
    virt_lines_above = ext[3].virt_lines_above,
  }
end

T["images"]["a placed image drops its placeholder and the box closes below it"] = function()
  stub_snacks()
  local buf = make_buffer({ "# %% a", "plt.plot()", "", "# %% b", "print(1)" })
  local hash = cell_hash(buf)
  local end_lnum = cell.all(buf)[1].end_lnum

  output.push(buf, hash, { kind = "display_data", mime = { ["image/png"] = "iVBORw0KGgo=" } })

  local t = texts(extmark_of(buf, hash).virt_lines)
  MiniTest.expect.equality(#t, 1)
  expect_truthy(starts_with(t[1], "┌─ "))
  local below = extmark_below_of(buf, hash)
  expect_truthy(below ~= nil)
  MiniTest.expect.equality(below.row, end_lnum + 1)
  MiniTest.expect.equality(below.virt_lines_above, true)
  local b = texts(below.virt_lines)
  MiniTest.expect.equality(#b, 1)
  expect_truthy(starts_with(b[1], "└"))
  release_buffer(buf)
end

T["images"]["text after a placed image renders in the bottom piece"] = function()
  stub_snacks()
  local buf = make_buffer({ "# %% a", "plt.plot()" })
  local hash = cell_hash(buf)

  output.push(buf, hash, { kind = "display_data", mime = { ["image/png"] = "iVBORw0KGgo=" } })
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "note" } })

  local t = texts(extmark_of(buf, hash).virt_lines)
  MiniTest.expect.equality(#t, 1)
  expect_truthy(starts_with(t[1], "┌─ "))
  local b = texts(extmark_below_of(buf, hash).virt_lines)
  MiniTest.expect.equality(#b, 2)
  expect_truthy(starts_with(b[1], "▎ note"))
  expect_truthy(starts_with(b[2], "└"))
  release_buffer(buf)
end

T["images"]["the bottom piece anchors past a concealed next header"] = function()
  stub_snacks()
  local buf = make_buffer({ "# %% a", "plt.plot()", "# %% b", "print(1)" })
  local hash = cell_hash(buf)
  local chrome_ns = vim.api.nvim_create_namespace("jove_cell_chrome")
  vim.api.nvim_buf_set_extmark(buf, chrome_ns, 2, 0, { conceal_lines = "" })

  output.push(buf, hash, { kind = "display_data", mime = { ["image/png"] = "iVBORw0KGgo=" } })

  local below = extmark_below_of(buf, hash)
  MiniTest.expect.equality(below.row, 4)
  release_buffer(buf)
end

T["images"]["a blank anchor line indents the image inside the frame"] = function()
  local calls = stub_snacks()
  local buf = make_buffer({ "# %% a", "plt.plot()", "", "# %% b" })
  local hash = cell_hash(buf)
  local end_lnum = cell.all(buf)[1].end_lnum

  output.push(buf, hash, { kind = "display_data", mime = { ["image/png"] = "iVBORw0KGgo=" } })

  MiniTest.expect.equality(calls[1].opts.pos, { end_lnum, 2 })
  release_buffer(buf)
end

T["images"]["re-render closes the previous placement instead of stacking grids"] = function()
  local calls, closed = stub_snacks()
  local buf = make_buffer({ "# %% a", "plt.plot()" })
  local hash = cell_hash(buf)

  output.push(buf, hash, { kind = "display_data", mime = { ["image/png"] = "iVBORw0KGgo=" } })
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "note" } })

  MiniTest.expect.equality(#calls, 2)
  MiniTest.expect.equality(#closed, 1)
  release_buffer(buf)
end

T["images"]["passes the configured size caps to snacks.image.placement"] = function()
  local calls = stub_snacks()
  jove.config.output.image_max_width = 120
  jove.config.output.image_max_height = 10
  local buf = make_buffer({ "# %% a", "plt.plot()" })
  local hash = cell_hash(buf)

  output.push(buf, hash, { kind = "display_data", mime = { ["image/png"] = "iVBORw0KGgo=" } })

  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(calls[1].opts.max_width, 120)
  MiniTest.expect.equality(calls[1].opts.max_height, 10)
  release_buffer(buf)
end

T["images"]["omits the size caps from placement opts when unset"] = function()
  local calls = stub_snacks()
  jove.config.output.image_max_width = nil
  jove.config.output.image_max_height = nil
  local buf = make_buffer({ "# %% a", "plt.plot()" })
  local hash = cell_hash(buf)

  output.push(buf, hash, { kind = "display_data", mime = { ["image/png"] = "iVBORw0KGgo=" } })

  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(calls[1].opts.max_width, nil)
  MiniTest.expect.equality(calls[1].opts.max_height, nil)
  release_buffer(buf)
end

T["images"]["keeps the placeholder when the terminal lacks the kitty protocol"] = function()
  stub_snacks(false)
  local buf = make_buffer({ "# %% a", "plt.plot()" })
  local hash = cell_hash(buf)

  output.push(buf, hash, { kind = "display_data", mime = { ["image/png"] = "iVBORw0KGgo=" } })

  local t = texts(extmark_of(buf, hash).virt_lines)
  expect_truthy(t[2]:find("[image:", 1, true) ~= nil)
  release_buffer(buf)
end

T["images"]["a bundled text/plain repr disappears when the image is placed"] = function()
  stub_snacks()
  local buf = make_buffer({ "# %% a", "plt.plot()" })
  local hash = cell_hash(buf)

  output.push(buf, hash, {
    kind = "display_data",
    mime = { ["image/png"] = "iVBORw0KGgo=", ["text/plain"] = "<Figure size 100x100>" },
  })

  local t = texts(extmark_of(buf, hash).virt_lines)
  MiniTest.expect.equality(#t, 1)
  expect_truthy(starts_with(t[1], "┌─ "))
  local b = texts(extmark_below_of(buf, hash).virt_lines)
  MiniTest.expect.equality(#b, 1)
  expect_truthy(starts_with(b[1], "└"))
  release_buffer(buf)
end

T["images"]["a failed placement shows the bundled text/plain repr instead"] = function()
  stub_snacks(false)
  local buf = make_buffer({ "# %% a", "plt.plot()" })
  local hash = cell_hash(buf)

  output.push(buf, hash, {
    kind = "display_data",
    mime = { ["image/png"] = "iVBORw0KGgo=", ["text/plain"] = "<Figure size 100x100>" },
  })

  local t = texts(extmark_of(buf, hash).virt_lines)
  MiniTest.expect.equality(#t, 3)
  expect_truthy(t[2]:find("<Figure size 100x100>", 1, true) ~= nil)
  expect_truthy(t[2]:find("[image:", 1, true) == nil)
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
  expect_truthy(starts_with(t[1], "┌─ "))
  MiniTest.expect.equality(#t, 4)
  expect_truthy(starts_with(t[2], "▎ ZeroDivisionError:"))
  expect_truthy(starts_with(t[3], "▎ ZeroDivisionError"))
  expect_truthy(starts_with(t[4], "└"))
  release_buffer(buf)
end

T["priority"] = MiniTest.new_set()

T["priority"]["outside output uses highlight priority 200"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "hi" } })
  MiniTest.expect.equality(extmark_of(buf, hash).priority, 200)
  release_buffer(buf)
end

T["priority"]["inside_border is true restores the default extmark priority"] = function()
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

T["decoration"]["header is false omits the rule and keeps content only"] = function()
  local orig = jove.config.output.header
  jove.config.output.header = false
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "hi" } })
  MiniTest.expect.equality(texts(extmark_of(buf, hash).virt_lines), { "▎ hi" })
  jove.config.output.header = orig
  release_buffer(buf)
end

T["decoration"]["guide is false omits the inner padding rail"] = function()
  local orig = jove.config.output.guide
  jove.config.output.guide = false
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "hi" } })
  local t = texts(extmark_of(buf, hash).virt_lines)
  MiniTest.expect.equality(#t, 3)
  expect_truthy(starts_with(t[2], "hi"))
  expect_truthy(t[2]:find("▎", 1, true) == nil)
  expect_truthy(t[2]:find("│", 1, true) == nil)
  jove.config.output.guide = orig
  release_buffer(buf)
end

T["decoration"]["custom guide string is used verbatim"] = function()
  local orig = jove.config.output.guide
  jove.config.output.guide = "│ "
  local buf = make_buffer({ "# %% a", "print(1)" })
  local hash = cell_hash(buf)
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "hi" } })
  local t = texts(extmark_of(buf, hash).virt_lines)
  expect_truthy(starts_with(t[2], "│ hi"))
  jove.config.output.guide = orig
  release_buffer(buf)
end

T["decoration"]["error output switches the inner padding rail to JoveOutputGuideError"] = function()
  local orig = jove.config.output.guide
  jove.config.output.guide = "▎ "
  local buf = make_buffer({ "# %% a", "1/0" })
  local hash = cell_hash(buf)
  output.push(buf, hash, {
    kind = "error",
    ename = "ZeroDivisionError",
    evalue = "division by zero",
    traceback = { "ZeroDivisionError" },
  })
  local inner_rail = extmark_of(buf, hash).virt_lines[2][1]
  MiniTest.expect.equality(inner_rail[1], "▎ ")
  MiniTest.expect.equality(inner_rail[2], "JoveOutputGuideError")
  jove.config.output.guide = orig
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
  output.toggle(buf, 1)
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
  MiniTest.expect.equality(#t, 6)
  expect_truthy(starts_with(t[1], "┌─ "))
  expect_truthy(starts_with(t[2], "▎ line1"))
  expect_truthy(starts_with(t[4], "▎ line3"))
  expect_truthy(starts_with(t[5], "▎ … +7 lines · :Jove open-output"))
  expect_truthy(starts_with(t[6], "└"))

  jove.config.output.max_lines = orig
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "done" } })
  ext = extmark_of(buf, hash)
  MiniTest.expect.equality(#texts(ext.virt_lines), 12)
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
  MiniTest.expect.equality(#t1, 3)
  expect_truthy(starts_with(t1[2], "▎ a1a2"))
  expect_truthy(texts(extmark_of(buf, h2).virt_lines)[2]:find("b1", 1, true) ~= nil)
  release_buffer(buf)
end

T["import"]["ignores unknown hashes and non-jove buffers without erroring"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  output.import(buf, { deadbeef = { { kind = "stream", mime = { ["text/plain"] = "x" } } } })
  expect_truthy(state.peek(buf).outputs["deadbeef"] ~= nil)
  MiniTest.expect.equality(#vim.api.nvim_buf_get_extmarks(buf, output.ns, 0, -1, {}), 0)

  local orphan = vim.api.nvim_create_buf(false, true)
  output.import(orphan, { deadbeef = {} })
  expect_truthy(state.peek(orphan) == nil)
  release_buffer(buf)
  release_buffer(orphan)
end

T["buf_0"] = MiniTest.new_set()

T["buf_0"]["toggle(0, lnum) toggles the current buffer's cell"] = function()
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

T["buf_0"]["clear(0, hash) and clear(0) clear the current buffer"] = function()
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

T["buf_0"]["push(0, ...) attaches to the current buffer"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  vim.api.nvim_set_current_buf(buf)
  output.push(0, cell_hash(buf), { kind = "stream", mime = { ["text/plain"] = "hello" } })
  local ext = extmark_of(buf, cell_hash(buf))
  expect_truthy(ext ~= nil)
  local t = texts(ext.virt_lines)
  MiniTest.expect.equality(#t, 3)
  expect_truthy(starts_with(t[2], "▎ hello"))
  expect_truthy(t[2]:find("│", 1, true) == nil)
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
  MiniTest.expect.equality(float_lines[1], "l1")
  for _, l in ipairs(float_lines) do
    MiniTest.expect.equality(l:find("└─", 1, true), nil)
    expect_truthy(not starts_with(l, "▎ "))
  end

  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys("q", "mx", false)
  expect_truthy(not vim.api.nvim_win_is_valid(win))
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), before)

  jove.config.output.max_lines = orig
  release_buffer(buf)
end

T["open_float"]["returns nil when there is nothing to show"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  MiniTest.expect.equality(output.open_float(buf, 1), nil)
  output.push(buf, cell_hash(buf), { kind = "stream", mime = { ["text/plain"] = "x" } })
  expect_truthy(output.open_float(buf, 1) ~= nil)
  vim.cmd("silent! close")
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

T["open_float"]["opens a vertical split by default"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  output.push(buf, cell_hash(buf), { kind = "stream", mime = { ["text/plain"] = "x" } })
  local win = output.open_float(buf, 1)
  expect_truthy(win ~= nil)
  MiniTest.expect.equality(vim.api.nvim_win_get_config(win).relative, "")
  expect_truthy(vim.api.nvim_win_get_width(win) < vim.o.columns)
  vim.api.nvim_win_close(win, true)
  release_buffer(buf)
end

T["open_float"]["honors ui.window_mode is float"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  output.push(buf, cell_hash(buf), { kind = "stream", mime = { ["text/plain"] = "x" } })
  local saved = jove.config.ui.window_mode
  jove.config.ui.window_mode = "float"
  local win = output.open_float(buf, 1)
  jove.config.ui.window_mode = saved
  expect_truthy(win ~= nil)
  MiniTest.expect.equality(vim.api.nvim_win_get_config(win).relative, "editor")
  vim.api.nvim_win_close(win, true)
  release_buffer(buf)
end

T["open_float"]["honors ui.window_mode is hsplit"] = function()
  local buf = make_buffer({ "# %% a", "print(1)" })
  output.push(buf, cell_hash(buf), { kind = "stream", mime = { ["text/plain"] = "x" } })
  local saved = jove.config.ui.window_mode
  jove.config.ui.window_mode = "hsplit"
  local win = output.open_float(buf, 1)
  jove.config.ui.window_mode = saved
  expect_truthy(win ~= nil)
  MiniTest.expect.equality(vim.api.nvim_win_get_config(win).relative, "")
  expect_truthy(vim.api.nvim_win_get_height(win) < vim.o.lines)
  vim.api.nvim_win_close(win, true)
  release_buffer(buf)
end

return T

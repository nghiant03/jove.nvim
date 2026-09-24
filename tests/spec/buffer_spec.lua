-- buffer_spec.lua: BufReadCmd / BufWriteCmd integration through the real
-- jupytext binary. Async handlers are driven to completion with vim.wait
-- polling; everything runs in temp dirs (never writes into the repo).
local MiniTest = require("mini.test")
local buffer = require("jove.buffer")
local convert = require("jove.convert")
local state = require("jove.state")

local orig_convert_write = convert.write

local T = MiniTest.new_set({
  -- Defensive restore in case a case aborts with the convert stub installed.
  hooks = {
    post_case = function()
      convert.write = orig_convert_write
    end,
  },
})

---@param cond any
local function expect_truthy(cond)
  MiniTest.expect.equality(cond == true, true)
end

---Assert two paths name the same file, tolerating symlink resolution
---(macOS temp dirs live under /var, which Neovim resolves to /private/var
---in BufReadCmd's match, so st.path can differ textually from the test's path).
---@param a string
---@param b string
local function expect_same_path(a, b)
  MiniTest.expect.equality(vim.uv.fs_realpath(a), vim.uv.fs_realpath(b))
end

local FIXTURE = vim.fs.joinpath(vim.fn.getcwd(), "tests", "fixtures", "smoke.ipynb")

---@return string path
local function tmp_copy_fixture()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.joinpath(dir, "smoke.ipynb")
  local ok = vim.uv.fs_copyfile(FIXTURE, path)
  expect_truthy(ok)
  return path
end

---@param path string
---@return string?
local function read_disk(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local data = fd:read("*a")
  fd:close()
  return data
end

---Open `path` through BufReadCmd and wait for the async read to settle.
---@param path string
---@return integer buf
local function open_notebook(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  local settled = vim.wait(30000, function()
    local st = state.peek(buf)
    return st ~= nil
      and st.path ~= nil
      and st.json ~= nil
      and vim.bo[buf].filetype == "python"
      and not vim.bo[buf].modified
  end, 10)
  expect_truthy(settled)
  return buf
end

local function close_notebook(buf)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

T["read via BufReadCmd"] = MiniTest.new_set()

T["read via BufReadCmd"]["opens with acwrite buftype and py:percent lines"] = function()
  local path = tmp_copy_fixture()
  local buf = open_notebook(path)

  MiniTest.expect.equality(vim.bo[buf].buftype, "acwrite")

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  expect_truthy(#lines > 0)
  local has_marker = false
  for _, l in ipairs(lines) do
    if l:match("^# %%") then
      has_marker = true
      break
    end
  end
  expect_truthy(has_marker)

  local st = state.get(buf)
  expect_same_path(st.path, path)
  expect_truthy(type(st.json) == "table")
  MiniTest.expect.equality(#st.json.cells, 3)

  close_notebook(buf)
end

T["read via BufReadCmd"]["undo right after open keeps the content"] = function()
  local path = tmp_copy_fixture()
  local buf = open_notebook(path)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent! normal! u")
  end)
  MiniTest.expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines)
  MiniTest.expect.equality(vim.bo[buf].modified, false)

  close_notebook(buf)
end

T["read via BufReadCmd"]["edits after open remain undoable"] = function()
  local path = tmp_copy_fixture()
  local buf = open_notebook(path)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("normal! Goadded")
  end)
  MiniTest.expect.equality(vim.bo[buf].modified, true)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent! normal! u")
  end)
  MiniTest.expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines)

  close_notebook(buf)
end

T["read via BufReadCmd"]["new file: empty py:percent buffer, JSON deferred to write"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.joinpath(dir, "new.ipynb")

  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()

  MiniTest.expect.equality(vim.bo[buf].buftype, "acwrite")
  MiniTest.expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "# %%", "" })
  MiniTest.expect.equality(vim.bo[buf].modified, false)

  local st = state.get(buf)
  expect_same_path(st.path, path)
  MiniTest.expect.equality(st.json, nil)

  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent! normal! u")
  end)
  MiniTest.expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "# %%", "" })

  close_notebook(buf)
end

T["read via BufReadCmd"]["strips jupytext front matter from the buffer"] = function()
  local path = tmp_copy_fixture()
  local buf = open_notebook(path)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, l in ipairs(lines) do
    MiniTest.expect.equality(l:match("^# %-%-") ~= nil, false)
  end
  local fm = state.get(buf).front_matter
  expect_truthy(type(fm) == "table" and #fm >= 2 and fm[1] == "# ---")
  close_notebook(buf)
end

T["read via BufReadCmd"]["trailing empty cell gets a body line"] = function()
  -- jupytext emits a trailing empty cell as a bare header. It needs a body
  -- line to remain accessible when chrome conceals the header.
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.joinpath(dir, "trailing.ipynb")
  local fd = assert(io.open(path, "wb"))
  fd:write(vim.json.encode({
    nbformat = 4,
    nbformat_minor = 5,
    metadata = {
      kernelspec = { name = "python3", language = "python", display_name = "Python 3" },
      language_info = { name = "python" },
    },
    cells = {
      {
        cell_type = "code",
        metadata = { id = "first" },
        execution_count = 1,
        outputs = {},
        source = { "1 + 1\n" },
      },
      {
        cell_type = "code",
        metadata = { id = "trailing" },
        execution_count = nil,
        outputs = {},
        source = {},
      },
    },
  }))
  fd:close()

  local buf = open_notebook(path)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  MiniTest.expect.equality(lines[#lines], "")
  MiniTest.expect.equality(lines[#lines - 1]:match("^# %%") ~= nil, true)
  close_notebook(buf)
end

T["write via BufWriteCmd"] = MiniTest.new_set()

T["write via BufWriteCmd"]["saves edits as valid ipynb and records last_write"] = function()
  local path = tmp_copy_fixture()
  local buf = open_notebook(path)
  local ncells = #state.get(buf).json.cells

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local edit_at
  for i, l in ipairs(lines) do
    if l:find("print", 1, true) then
      edit_at = i
      break
    end
  end
  expect_truthy(edit_at ~= nil)
  vim.api.nvim_buf_set_lines(buf, edit_at - 1, edit_at, false, { 'print("hello edited")' })
  expect_truthy(vim.bo[buf].modified)

  vim.cmd("write")

  -- Async write: settle when last_write matches the on-disk bytes and the
  -- modified flag is cleared.
  local settled = vim.wait(30000, function()
    local st = state.peek(buf)
    if not (st and st.last_write) then
      return false
    end
    local bytes = read_disk(path)
    return bytes ~= nil and vim.fn.sha256(bytes) == st.last_write and not vim.bo[buf].modified
  end, 10)
  expect_truthy(settled)

  local bytes = read_disk(path)
  local ok, nb = pcall(vim.json.decode, bytes)
  expect_truthy(ok)
  MiniTest.expect.equality(#nb.cells, ncells)
  local found_edited = false
  for _, cell in ipairs(nb.cells) do
    local src = type(cell.source) == "table" and table.concat(cell.source, "\n")
      or tostring(cell.source)
    if src:find("hello edited", 1, true) then
      found_edited = true
      break
    end
  end
  expect_truthy(found_edited)

  MiniTest.expect.equality(state.get(buf).json, nb)
  MiniTest.expect.equality(state.get(buf).last_write, vim.fn.sha256(bytes))

  close_notebook(buf)
end

T["write via BufWriteCmd"]["coalesces two rapid writes (single-flight)"] = function()
  local path = tmp_copy_fixture()
  local buf = open_notebook(path)

  local orig = convert.write
  local started, finished = 0, 0
  convert.write = function(p, l, cb)
    started = started + 1
    return orig(p, l, function(bytes, err)
      finished = finished + 1
      cb(bytes, err)
    end)
  end

  -- Two back-to-back :writes in the same event-loop slice: the second must
  -- land while the first is still in flight and be coalesced.
  vim.cmd("write")
  vim.cmd("write")

  local settled = vim.wait(30000, function()
    local st = state.peek(buf)
    return started == 2
      and finished == 2
      and st ~= nil
      and st.last_write ~= nil
      and not vim.bo[buf].modified
  end, 10)
  expect_truthy(settled)
  convert.write = orig

  local bytes = read_disk(path)
  expect_truthy(bytes ~= nil)
  local ok, nb = pcall(vim.json.decode, bytes)
  expect_truthy(ok)
  MiniTest.expect.equality(#nb.cells, 3)
  MiniTest.expect.equality(state.get(buf).last_write, vim.fn.sha256(bytes))

  close_notebook(buf)
end

T["write round-trips"] = MiniTest.new_set()

T["write round-trips"]["preserves kernelspec even with stripped front matter on write"] = function()
  local path = tmp_copy_fixture()
  local buf = open_notebook(path)
  local orig_ks = state.get(buf).json.metadata.kernelspec
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "# touch" })
  vim.cmd("write")
  local done = vim.wait(30000, function()
    local st = state.peek(buf)
    return st ~= nil and st.last_write ~= nil and not vim.bo[buf].modified
  end, 10)
  expect_truthy(done)
  local after = read_disk(path)
  expect_truthy(after:find(orig_ks.name, 1, true) ~= nil)
  close_notebook(buf)
end

T["javascript notebooks"] = MiniTest.new_set()

local JS_FIXTURE = vim.fs.joinpath(vim.fn.getcwd(), "tests", "fixtures", "smoke_js.ipynb")

---@return string path
local function tmp_copy_js_fixture()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.joinpath(dir, "smoke_js.ipynb")
  local ok = vim.uv.fs_copyfile(JS_FIXTURE, path)
  expect_truthy(ok)
  return path
end

T["javascript notebooks"]["read: js:percent lines, javascript filetype, // front matter stripped"] = function()
  local path = tmp_copy_js_fixture()
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  local settled = vim.wait(30000, function()
    local st = state.peek(buf)
    return st ~= nil
      and st.path ~= nil
      and st.json ~= nil
      and vim.bo[buf].filetype == "javascript"
      and not vim.bo[buf].modified
  end, 10)
  expect_truthy(settled)

  local st = state.get(buf)
  MiniTest.expect.equality(st.lang, "javascript")

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local has_marker = false
  for _, l in ipairs(lines) do
    MiniTest.expect.equality(l:match("^// %-%-") == nil, true)
    MiniTest.expect.equality(l:match("^# %%") == nil, true)
    if l:match("^// %%") then
      has_marker = true
    end
  end
  expect_truthy(has_marker)

  local fm = st.front_matter
  expect_truthy(type(fm) == "table" and #fm >= 2 and fm[1] == "// ---")
  close_notebook(buf)
end

T["javascript notebooks"]["write: edits land in the ipynb via js:percent, kernelspec preserved"] = function()
  local path = tmp_copy_js_fixture()
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  local settled = vim.wait(30000, function()
    local st = state.peek(buf)
    return st ~= nil and st.path ~= nil and st.json ~= nil and vim.bo[buf].filetype == "javascript"
  end, 10)
  expect_truthy(settled)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local edit_at
  for i, l in ipairs(lines) do
    if l:find("console.log", 1, true) then
      edit_at = i
      break
    end
  end
  expect_truthy(edit_at ~= nil)
  vim.api.nvim_buf_set_lines(buf, edit_at - 1, edit_at, false, { 'console.log("edited")' })

  vim.cmd("write")
  local done = vim.wait(30000, function()
    local st = state.peek(buf)
    return st ~= nil and st.last_write ~= nil and not vim.bo[buf].modified
  end, 10)
  expect_truthy(done)

  local bytes = read_disk(path)
  expect_truthy(bytes ~= nil)
  local ok, nb = pcall(vim.json.decode, bytes)
  expect_truthy(ok)
  MiniTest.expect.equality(nb.metadata.kernelspec.language, "javascript")
  local found_edited = false
  for _, c in ipairs(nb.cells) do
    local src = type(c.source) == "table" and table.concat(c.source, "\n") or tostring(c.source)
    if src:find("edited", 1, true) then
      found_edited = true
      break
    end
  end
  expect_truthy(found_edited)
  close_notebook(buf)
end

T["changed_shell"] = MiniTest.new_set()

T["changed_shell"]["suppresses our own last write silently"] = function()
  local path = tmp_copy_fixture()
  local buf = open_notebook(path)

  -- Simulate the post-write situation: last_write matches the on-disk bytes.
  local bytes = read_disk(path)
  state.get(buf).last_write = vim.fn.sha256(bytes)
  MiniTest.expect.equality(buffer.changed_shell(buf, path), true)

  close_notebook(buf)
end

T["changed_shell"]["returns nil without jove state (foreign buffer)"] = function()
  local path = tmp_copy_fixture()
  local scratch = vim.api.nvim_create_buf(false, true)
  MiniTest.expect.equality(buffer.changed_shell(scratch, path), nil)
  vim.api.nvim_buf_delete(scratch, { force = true })
end

T["changed_shell"]["auto-reloads a foreign change, preserving the cursor"] = function()
  local path = tmp_copy_fixture()
  local buf = open_notebook(path)

  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  local cursor_before = vim.api.nvim_win_get_cursor(0)

  -- Foreign change on disk: replace a plain substring that appears in the
  -- code cell source (and in a stream output, harmlessly).
  local bytes = read_disk(path)
  local foreign = bytes:gsub("hello", "goodbye")
  expect_truthy(foreign ~= bytes)
  local fd = assert(io.open(path, "wb"))
  fd:write(foreign)
  fd:close()

  local jove = require("jove")
  local auto_reload_before = jove.config.auto_reload
  jove.config.auto_reload = true
  MiniTest.expect.equality(buffer.changed_shell(buf, path), false)

  local settled = vim.wait(30000, function()
    for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if l:find("goodbye", 1, true) then
        return not vim.bo[buf].modified
      end
    end
    return false
  end, 10)
  jove.config.auto_reload = auto_reload_before
  expect_truthy(settled)
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0), cursor_before)

  close_notebook(buf)
end

return T

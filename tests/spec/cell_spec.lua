local MiniTest = require("mini.test")
local state = require("jove.state")
local cell = require("jove.cell")
local keymaps = require("jove.keymaps")

local T = MiniTest.new_set()

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

---@param lines string[]
---@return integer buf
local function attach_buffer(lines)
  local buf = make_buffer(lines)
  keymaps.apply()
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "python"
  return buf
end

---@param keys string
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
  vim.api.nvim_feedkeys("", "x", false)
end

T["parse"] = MiniTest.new_set()

T["parse"]["splits cells with code kind and ranges"] = function()
  local buf = make_buffer({ "# %% a", "x1", "# %% b", "y1", "y2" })
  local cells = cell.all(buf)
  MiniTest.expect.equality(#cells, 2)
  MiniTest.expect.equality(cells[1].start_lnum, 1)
  MiniTest.expect.equality(cells[1].end_lnum, 2)
  MiniTest.expect.equality(cells[1].kind, "code")
  MiniTest.expect.equality(cells[1].header, 1)
  MiniTest.expect.equality(cells[2].start_lnum, 3)
  MiniTest.expect.equality(cells[2].end_lnum, 5)
  MiniTest.expect.equality(cells[2].header, 3)
  release_buffer(buf)
end

T["parse"]["recognizes [markdown] headers"] = function()
  local buf = make_buffer({ "# %% [markdown]", "# title", "# %% code", "x = 1" })
  local cells = cell.all(buf)
  MiniTest.expect.equality(cells[1].kind, "markdown")
  MiniTest.expect.equality(cells[2].kind, "code")
  release_buffer(buf)
end

T["parse"]["treats pre-header lines as a synthetic first cell"] = function()
  local buf = make_buffer({ "import os", "", "# %% a", "x1" })
  local cells = cell.all(buf)
  MiniTest.expect.equality(#cells, 2)
  MiniTest.expect.equality(cells[1].start_lnum, 1)
  MiniTest.expect.equality(cells[1].end_lnum, 2)
  MiniTest.expect.equality(cells[1].kind, "code")
  MiniTest.expect.equality(cells[1].header, nil)
  MiniTest.expect.equality(cells[2].header, 3)
  release_buffer(buf)
end

T["parse"]["cell with only a header has an empty body range"] = function()
  local buf = make_buffer({ "# %% a", "# %% b", "x" })
  local cells = cell.all(buf)
  MiniTest.expect.equality(cells[1].start_lnum, 1)
  MiniTest.expect.equality(cells[1].end_lnum, 1)
  MiniTest.expect.equality(cells[2].start_lnum, 2)
  MiniTest.expect.equality(cells[2].end_lnum, 3)
  release_buffer(buf)
end

T["parse"]["bare `# %%` is a header"] = function()
  local buf = make_buffer({ "# %%", "x1", "# %% b", "y1" })
  local cells = cell.all(buf)
  MiniTest.expect.equality(#cells, 2)
  MiniTest.expect.equality(cells[1].header, 1)
  MiniTest.expect.equality(cells[2].header, 3)
  release_buffer(buf)
end

T["parse"]["uses the buffer language's comment leader (// %% for javascript)"] = function()
  local buf = make_buffer({ "// %% a", "const x = 1;", "// %% [markdown]", "// # hi" })
  state.get(buf).lang = "javascript"
  local cells = cell.all(buf)
  MiniTest.expect.equality(#cells, 2)
  MiniTest.expect.equality(cells[1].header, 1)
  MiniTest.expect.equality(cells[1].kind, "code")
  MiniTest.expect.equality(cells[2].header, 3)
  MiniTest.expect.equality(cells[2].kind, "markdown")
  release_buffer(buf)
end

T["parse"]["python markers are body lines in a javascript buffer"] = function()
  local buf = make_buffer({ "// %% a", "# %%", "const x = 1;" })
  state.get(buf).lang = "javascript"
  local cells = cell.all(buf)
  MiniTest.expect.equality(#cells, 1)
  MiniTest.expect.equality(cells[1].end_lnum, 3)
  release_buffer(buf)
end

T["parse"]["re-parses when the buffer language changes (cache keys on lang)"] = function()
  local buf = make_buffer({ "// %% a", "const x = 1;" })
  local py_cells = cell.all(buf)
  MiniTest.expect.equality(#py_cells, 1)
  MiniTest.expect.equality(py_cells[1].header, nil)
  state.get(buf).lang = "javascript"
  local js_cells = cell.all(buf)
  MiniTest.expect.equality(#js_cells, 1)
  MiniTest.expect.equality(js_cells[1].header, 1)
  release_buffer(buf)
end

T["hash"] = MiniTest.new_set()

T["hash"]["preserves significant whitespace within source lines"] = function()
  local clean = make_buffer({ "# %% a", "x = 1" })
  local dirty = make_buffer({ "# %% a", "x = 1  ", "", "" })
  MiniTest.expect.equality(cell.all(clean)[1].hash == cell.all(dirty)[1].hash, false)
  release_buffer(clean)
  release_buffer(dirty)
end

T["hash"]["excludes the header line"] = function()
  local a = make_buffer({ "# %% a", "x = 1" })
  local b = make_buffer({ "# %% totally different", "x = 1" })
  MiniTest.expect.equality(cell.all(a)[1].hash, cell.all(b)[1].hash)
  release_buffer(a)
  release_buffer(b)
end

T["hash"]["differs for different body content"] = function()
  local a = make_buffer({ "# %% a", "x = 1" })
  local b = make_buffer({ "# %% a", "y = 2" })
  expect_truthy(cell.all(a)[1].hash ~= cell.all(b)[1].hash)
  release_buffer(a)
  release_buffer(b)
end

T["cache"] = MiniTest.new_set()

T["cache"]["reuses the cached list until changedtick moves"] = function()
  local buf = make_buffer({ "# %% a", "x1" })
  local first = cell.all(buf)
  expect_truthy(cell.all(buf) == first)
  expect_truthy(state.get(buf).cells.tick == vim.b[buf].changedtick)
  release_buffer(buf)
end

T["cache"]["re-parses after an edit (changedtick bump)"] = function()
  local buf = make_buffer({ "# %% a", "x1" })
  local first = cell.all(buf)
  vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "x1b" })
  local second = cell.all(buf)
  expect_truthy(second ~= first)
  MiniTest.expect.equality(second[1].end_lnum, 3)
  expect_truthy(state.get(buf).cells.tick == vim.b[buf].changedtick)
  release_buffer(buf)
end

T["at"] = MiniTest.new_set()

T["at"]["returns the cell containing lnum"] = function()
  local buf = make_buffer({ "# %% a", "x1", "# %% b", "y1", "y2" })
  MiniTest.expect.equality(cell.at(buf, 1).header, 1)
  MiniTest.expect.equality(cell.at(buf, 2).header, 1)
  MiniTest.expect.equality(cell.at(buf, 4).header, 3)
  release_buffer(buf)
end

T["at"]["maps pre-header lines to the synthetic first cell"] = function()
  local buf = make_buffer({ "import os", "# %% a", "x1" })
  MiniTest.expect.equality(cell.at(buf, 1).header, nil)
  MiniTest.expect.equality(cell.at(buf, 1).end_lnum, 1)
  release_buffer(buf)
end

T["at"]["returns nil outside the buffer"] = function()
  local buf = make_buffer({ "# %% a", "x1" })
  expect_truthy(cell.at(buf, 0) == nil)
  expect_truthy(cell.at(buf, 3) == nil)
  release_buffer(buf)
end

T["next/prev"] = MiniTest.new_set()

T["next/prev"]["walks the header lnums"] = function()
  local buf = make_buffer({ "# %% a", "x1", "# %% b", "y1", "# %% c", "z1" })
  MiniTest.expect.equality(cell.next(buf, 0), 1)
  MiniTest.expect.equality(cell.next(buf, 1), 3)
  MiniTest.expect.equality(cell.next(buf, 2), 3)
  MiniTest.expect.equality(cell.next(buf, 3), 5)
  MiniTest.expect.equality(cell.next(buf, 5), nil)
  MiniTest.expect.equality(cell.prev(buf, 1), nil)
  MiniTest.expect.equality(cell.prev(buf, 2), 1)
  MiniTest.expect.equality(cell.prev(buf, 4), 3)
  MiniTest.expect.equality(cell.prev(buf, 5), 3)
  MiniTest.expect.equality(cell.prev(buf, 6), 5)
  release_buffer(buf)
end

T["next/prev"]["skips the synthetic pre-header cell"] = function()
  local buf = make_buffer({ "import os", "# %% a", "x1" })
  MiniTest.expect.equality(cell.next(buf, 1), 2)
  MiniTest.expect.equality(cell.next(buf, 2), nil)
  MiniTest.expect.equality(cell.prev(buf, 1), nil)
  release_buffer(buf)
end

T["next/prev"]["next is nil at the bottom, prev nil at the top"] = function()
  local buf = make_buffer({ "# %% a", "x1", "# %% b", "y1" })
  expect_truthy(cell.next(buf, 3) == nil)
  expect_truthy(cell.next(buf, 4) == nil)
  expect_truthy(cell.prev(buf, 1) == nil)
  release_buffer(buf)
end

T["range"] = MiniTest.new_set()

T["range"]["matches the historical cell_range contract"] = function()
  local buf = make_buffer({ "# %% a", "x1", "# %% b", "y1", "y2" })
  local s, e = cell.range(buf, 5)
  MiniTest.expect.equality(s, 3)
  MiniTest.expect.equality(e, 5)
  s, e = cell.range(buf, 2)
  MiniTest.expect.equality(s, 1)
  MiniTest.expect.equality(e, 2)
  release_buffer(buf)
end

T["range"]["returns nil outside the buffer"] = function()
  local buf = make_buffer({ "# %% a", "x1" })
  local s, e = cell.range(buf, 99)
  expect_truthy(s == nil)
  expect_truthy(e == nil)
  release_buffer(buf)
end

T["navigation"] = MiniTest.new_set()

T["navigation"]["next_cell/prev_cell move the cursor to headers"] = function()
  local buf = attach_buffer({ "# %% a", "x1", "# %% b", "y1", "# %% c", "z1" })

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  keymaps.next_cell()
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 3)

  keymaps.prev_cell()
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 1)

  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  keymaps.prev_cell()
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 3)

  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  keymaps.next_cell()
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 5)

  keymaps.prev_cell()
  keymaps.prev_cell()
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 1)

  release_buffer(buf)
end

T["textobjects"] = MiniTest.new_set()

T["textobjects"]["yic yanks the cell body, excluding the header"] = function()
  local buf = attach_buffer({ "# %% a", "x1", "x2", "# %% b", "y1" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.fn.setreg('"', "")
  feed("yic")
  MiniTest.expect.equality(vim.fn.getreg('"'), "x1\nx2\n")
  MiniTest.expect.equality(vim.fn.getregtype('"'), "V")
  release_buffer(buf)
end

T["textobjects"]["yac includes the header"] = function()
  local buf = attach_buffer({ "# %% a", "x1", "x2", "# %% b", "y1" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.fn.setreg('"', "")
  feed("yac")
  MiniTest.expect.equality(vim.fn.getreg('"'), "# %% a\nx1\nx2\n")
  MiniTest.expect.equality(vim.fn.getregtype('"'), "V")
  release_buffer(buf)
end

T["textobjects"]["yic on a header-only cell yanks nothing"] = function()
  local buf = attach_buffer({ "# %% a", "# %% b", "x" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.fn.setreg('"', "")
  feed("yic")
  MiniTest.expect.equality(vim.fn.getreg('"'), "")
  release_buffer(buf)
end

T["textobjects"]["yic from the synthetic pre-header cell yanks those lines"] = function()
  local buf = attach_buffer({ "import os", "import sys", "# %% a", "x1" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.fn.setreg('"', "")
  feed("yic")
  MiniTest.expect.equality(vim.fn.getreg('"'), "import os\nimport sys\n")
  release_buffer(buf)
end

T["textobjects"]["visual ic replaces the selection with the cell body"] = function()
  local buf = attach_buffer({ "# %% a", "x1", "# %% b", "y1" })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  feed("V") -- linewise visual on the header line
  feed("ic") -- reselect as the cell body
  feed("y<Esc>")
  MiniTest.expect.equality(vim.fn.getreg('"'), "y1\n")
  MiniTest.expect.equality(vim.fn.getregtype('"'), "V")
  release_buffer(buf)
end

T["textobjects"]["visual ac reselects the whole cell"] = function()
  local buf = attach_buffer({ "# %% a", "x1", "# %% b", "y1", "y2" })
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  feed("v") -- charwise visual inside cell 2
  feed("ac")
  feed("y<Esc>")
  MiniTest.expect.equality(vim.fn.getreg('"'), "# %% b\ny1\ny2\n")
  MiniTest.expect.equality(vim.fn.getregtype('"'), "V")
  release_buffer(buf)
end

T["textobjects"]["count extends through following cells"] = function()
  local buf = attach_buffer({ "# %% a", "x1", "# %% b", "y1", "# %% c", "z1" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.fn.setreg('"', "")
  feed("y2ic") -- count goes between operator and text-object
  MiniTest.expect.equality(vim.fn.getreg('"'), "x1\n# %% b\ny1\n")
  release_buffer(buf)
end

return T

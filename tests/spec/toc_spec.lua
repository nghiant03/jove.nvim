---@diagnostic disable: duplicate-set-field
local MiniTest = require("mini.test")
local state = require("jove.state")
local toc = require("jove.toc")

local T = MiniTest.new_set()

local created

---@param lines string[]
---@return integer
local function make_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  state.get(buf).path = "fake.ipynb"
  created[#created + 1] = buf
  return buf
end

T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      created = {}
    end,
    post_case = function()
      for _, buf in ipairs(created) do
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end,
  },
})

T["headings"] = MiniTest.new_set()

T["headings"]["extracts ATX headings from markdown cells, ignoring prose"] = function()
  local buf = make_buffer({
    "# %% [markdown]",
    "# # Title A",
    "# some prose",
    "# %% code",
    "x = 1",
    "# %% [markdown]",
    "# ## Sub B",
    "# ### Deep C",
  })

  local hs = toc.headings(buf)
  MiniTest.expect.equality(#hs, 3)
  MiniTest.expect.equality(hs[1], { level = 1, title = "Title A", cell_idx = 1, lnum = 1 })
  MiniTest.expect.equality(hs[2], { level = 2, title = "Sub B", cell_idx = 3, lnum = 6 })
  MiniTest.expect.equality(hs[3], { level = 3, title = "Deep C", cell_idx = 3, lnum = 6 })
end

T["headings"]["prepends the notebook title from metadata"] = function()
  local buf = make_buffer({
    "# %% [markdown]",
    "# # First",
  })
  state.get(buf).json = { metadata = { title = "My Book" } }

  local hs = toc.headings(buf)
  MiniTest.expect.equality(#hs, 2)
  MiniTest.expect.equality(hs[1], { level = 0, title = "My Book", cell_idx = 0, lnum = 1 })
  MiniTest.expect.equality(hs[2].title, "First")
end

T["headings"]["returns an empty list when there are no headings"] = function()
  local buf = make_buffer({ "# %% code", "x = 1" })
  MiniTest.expect.equality(toc.headings(buf), {})
end

T["pick"] = MiniTest.new_set()

T["pick"]["lists indented headings and jumps to the chosen cell"] = function()
  local buf = make_buffer({
    "# %% [markdown]",
    "# # First",
    "# %% code",
    "x = 1",
    "# %% [markdown]",
    "# ## Second",
  })

  local real_select = vim.ui.select
  local seen
  vim.ui.select = function(items, opts, on_choice)
    seen = { items = items, prompt = opts.prompt }
    on_choice(items[2])
  end

  vim.api.nvim_set_current_buf(buf)
  toc.pick(buf)
  vim.ui.select = real_select

  MiniTest.expect.equality(#seen.items, 2)
  MiniTest.expect.equality(seen.items[1].label, "First")
  MiniTest.expect.equality(seen.items[2].label, "  Second")
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 5)
end

T["pick"]["notifies when the notebook has no headings"] = function()
  local buf = make_buffer({ "# %% code", "x = 1" })
  local real_select, real_notify = vim.ui.select, vim.notify
  local called, note = false, nil
  vim.ui.select = function()
    called = true
  end
  vim.notify = function(msg)
    note = msg
  end
  toc.pick(buf)
  vim.ui.select, vim.notify = real_select, real_notify

  MiniTest.expect.equality(called, false)
  MiniTest.expect.equality(
    type(note) == "string" and note:find("no markdown", 1, true) ~= nil,
    true
  )
end

return T

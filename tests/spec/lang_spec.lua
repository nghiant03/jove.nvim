---@diagnostic disable: duplicate-set-field
local MiniTest = require("mini.test")
local lang = require("jove.lang")
local state = require("jove.state")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      lang._reset()
    end,
  },
})

local function capture_notify(fn)
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  local ok = pcall(fn)
  vim.notify = orig
  MiniTest.expect.equality(ok, true)
  return notes
end

T["get"] = MiniTest.new_set()

T["get"]["returns the default for nil"] = function()
  MiniTest.expect.equality(lang.get(nil).id, "python")
end

T["get"]["is case-insensitive"] = function()
  MiniTest.expect.equality(lang.get("R").id, "r")
  MiniTest.expect.equality(lang.get("JavaScript").id, "javascript")
end

T["get"]["knows the built-in languages"] = function()
  MiniTest.expect.equality(lang.get("python").fmt, "py")
  MiniTest.expect.equality(lang.get("julia").fmt, "jl")
  MiniTest.expect.equality(lang.get("r").fmt, "R")
  MiniTest.expect.equality(lang.get("javascript").comment, "//")
  MiniTest.expect.equality(lang.get("typescript").fmt, "ts")
end

T["get"]["falls back to python with a one-time warning for unknown ids"] = function()
  local notes = capture_notify(function()
    MiniTest.expect.equality(lang.get("cobol").id, "python")
    MiniTest.expect.equality(lang.get("cobol").comment, "#")
    lang.get("cobol")
  end)
  MiniTest.expect.equality(#notes, 1)
  MiniTest.expect.equality(notes[1].level, vim.log.levels.WARN)
  MiniTest.expect.equality(notes[1].msg:find("cobol", 1, true) ~= nil, true)
end

T["for_notebook"] = MiniTest.new_set()

T["for_notebook"]["reads kernelspec.language"] = function()
  local json = { metadata = { kernelspec = { language = "Julia" } } }
  MiniTest.expect.equality(lang.for_notebook(json).id, "julia")
end

T["for_notebook"]["falls back to python without metadata"] = function()
  MiniTest.expect.equality(lang.for_notebook(nil).id, "python")
  MiniTest.expect.equality(lang.for_notebook({}).id, "python")
  MiniTest.expect.equality(lang.for_notebook({ metadata = {} }).id, "python")
end

T["for_buffer"] = MiniTest.new_set()

T["for_buffer"]["uses st.lang and defaults to python"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  MiniTest.expect.equality(lang.for_buffer(buf).id, "python")
  state.get(buf).lang = "javascript"
  MiniTest.expect.equality(lang.for_buffer(buf).comment, "//")
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["register"] = MiniTest.new_set()

T["register"]["adds a custom language"] = function()
  lang.register("scala", { fmt = "scala", comment = "//", servers = { "metals" } })
  local spec = lang.get("scala")
  MiniTest.expect.equality(spec.id, "scala")
  MiniTest.expect.equality(spec.filetype, "scala")
  MiniTest.expect.equality(spec.fmt, "scala")
  MiniTest.expect.equality(spec.comment, "//")
  MiniTest.expect.equality(spec.servers, { "metals" })
  local notes = capture_notify(function()
    lang.get("scala")
  end)
  MiniTest.expect.equality(#notes, 0)
end

T["ids"] = MiniTest.new_set()

T["ids"]["lists sorted registry ids including the defaults"] = function()
  local ids = lang.ids()
  MiniTest.expect.equality(ids[1] < ids[#ids], true)
  local set = {}
  for _, id in ipairs(ids) do
    set[id] = true
  end
  for _, id in ipairs({ "python", "julia", "r", "javascript", "typescript" }) do
    MiniTest.expect.equality(set[id], true)
  end
end

return T

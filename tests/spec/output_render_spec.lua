---@diagnostic disable: duplicate-set-field
local MiniTest = require("mini.test")
local render = require("jove.output.render")
local ansi = require("jove.ansi")

local original_parse = ansi.parse
local calls
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      calls = 0
      ansi.parse = function(...)
        calls = calls + 1
        return original_parse(...)
      end
    end,
    post_case = function()
      ansi.parse = original_parse
    end,
  },
})

local function text(value, continues)
  return { kind = "text", text = value, continues = continues }
end

local function expect_fresh(chunks, cache)
  local lines, images, updated = render.build_lines(chunks, cache)
  local fresh_lines, fresh_images = render.build_lines(chunks)
  MiniTest.expect.equality(lines, fresh_lines)
  MiniTest.expect.equality(images, fresh_images)
  return updated
end

T["unchanged output does not reparse ANSI or rebuild lines"] = function()
  local chunks = { text("\27[31mred"), text("still red\27[0m") }
  local lines, images, cache = render.build_lines(chunks)
  local next_lines, next_images = render.build_lines(chunks, cache)
  MiniTest.expect.equality(calls, 2)
  MiniTest.expect.equality(next_lines == lines, true)
  MiniTest.expect.equality(next_images == images, true)
end

T["appends parse only new chunks with the previous ANSI state"] = function()
  local chunks = { text("\27[31mred") }
  local _, _, cache = render.build_lines(chunks)
  chunks[2] = text("also red\27[0m")
  local lines = render.build_lines(chunks, cache)
  MiniTest.expect.equality(calls, 2)
  MiniTest.expect.equality(lines[1][1][2], lines[2][1][2])
  expect_fresh(chunks, cache)
end

T["merged tails restore ANSI state before reparsing"] = function()
  local chunks = { text("\27[31mprefix"), text("red\27[0m") }
  local _, _, cache = render.build_lines(chunks)
  chunks[2].text = "red\27[0m\nplain"
  render.build_lines(chunks, cache)
  MiniTest.expect.equality(calls, 3)
  cache = expect_fresh(chunks, cache)
  chunks[2].text = "red\27[0m\nplain\nmore"
  expect_fresh(chunks, cache)
end

T["merged continuations restore the previous line without duplicating segments"] = function()
  local chunks = { text("prefix"), text("tail", true) }
  local _, _, cache = render.build_lines(chunks)
  for _, value in ipairs({ "tail!", "tail!\nnext", "\27[32mgreen\27[0m", "" }) do
    chunks[2].text = value
    cache = expect_fresh(chunks, cache)
  end
  chunks[2].text = "replaced"
  chunks[3] = text("final", true)
  cache = expect_fresh(chunks, cache)
  chunks[3].text = "final!"
  expect_fresh(chunks, cache)
end

T["incomplete escapes survive both tail merges and chunk boundaries"] = function()
  local chunks = { text("\27[3") }
  local _, _, cache = render.build_lines(chunks)
  chunks[1].text = "\27[31"
  cache = expect_fresh(chunks, cache)
  chunks[2] = text("mred\27[0m", true)
  cache = expect_fresh(chunks, cache)
  chunks[2].text = "mred\27[0m\nplain"
  expect_fresh(chunks, cache)
end

T["image indices survive continuation rollback and appended images"] = function()
  local chunks = {
    { kind = "image", mime = "image/png", fallback = "plot" },
    text("tail", true),
  }
  local _, _, cache = render.build_lines(chunks)
  chunks[2].text = "tail\nnext"
  cache = expect_fresh(chunks, cache)
  chunks[3] = { kind = "image", mime = "image/svg+xml" }
  cache = expect_fresh(chunks, cache)
  chunks[4] = text("more")
  expect_fresh(chunks, cache)
end

T["empty and replaced chunk lists reset the cache"] = function()
  local _, _, cache = render.build_lines({ text("old") })
  cache = expect_fresh({}, cache)
  local chunks = { text("new") }
  cache = expect_fresh(chunks, cache)
  chunks[1] = nil
  expect_fresh(chunks, cache)
end

T["mixed incremental updates match a fresh render"] = function()
  local chunks = {}
  local _, _, cache = render.build_lines(chunks)
  local fragments = { "plain", "\nnext", "\27[31mred", "\27[0m", "\27[", "32mgreen", "" }
  for i = 1, 80 do
    local value = fragments[(i - 1) % #fragments + 1]
    if i % 11 == 0 then
      chunks[#chunks + 1] = { kind = "image", mime = "image/png" }
    elseif i % 3 == 0 and #chunks > 0 and chunks[#chunks].kind == "text" then
      chunks[#chunks].text = chunks[#chunks].text .. value
      if i % 2 == 0 then
        chunks[#chunks + 1] = text("appended", true)
      end
    else
      chunks[#chunks + 1] = text(value, i % 2 == 0)
    end
    cache = expect_fresh(chunks, cache)
  end
end

return T

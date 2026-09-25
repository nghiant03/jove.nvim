local MiniTest = require("mini.test")
local ansi = require("jove.ansi")

local T = MiniTest.new_set()

---@param name string
---@return table
local function hl_attrs(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end

---@param n integer
---@return string
local function hex(n)
  return string.format("#%06x", n)
end

T["strip"] = MiniTest.new_set()

T["strip"]["removes CSI color sequences"] = function()
  MiniTest.expect.equality(ansi.strip("\27[0;31mred\27[0m"), "red")
end

T["strip"]["removes bold/underline and combined sequences"] = function()
  MiniTest.expect.equality(ansi.strip("\27[1mbold\27[22m and \27[4munder\27[24m"), "bold and under")
end

T["strip"]["removes cursor sequences and lone ESC"] = function()
  MiniTest.expect.equality(ansi.strip("a\27[2Kb\27c"), "abc")
end

T["strip"]["removes BEL-terminated OSC sequences"] = function()
  MiniTest.expect.equality(ansi.strip("\27]0;window title\7hello"), "hello")
end

T["strip"]["removes ST-terminated OSC sequences"] = function()
  MiniTest.expect.equality(ansi.strip("\27]2;window title\27\\rest"), "rest")
end

T["strip"]["removes OSC alongside CSI sequences"] = function()
  MiniTest.expect.equality(ansi.strip("\27]0;t\7\27[31mred\27[0m"), "red")
end

T["strip"]["removes carriage returns"] = function()
  MiniTest.expect.equality(ansi.strip("a\rb"), "ab")
end

T["strip"]["leaves plain text untouched"] = function()
  MiniTest.expect.equality(
    ansi.strip("Traceback (most recent call last)"),
    "Traceback (most recent call last)"
  )
end

T["strip"]["passes through non-strings"] = function()
  MiniTest.expect.equality(ansi.strip(nil), nil)
  MiniTest.expect.equality(ansi.strip(5), 5)
end

T["cr_concat"] = MiniTest.new_set()

T["cr_concat"]["appends plain text unchanged"] = function()
  MiniTest.expect.equality(ansi.cr_concat("foo", "bar\n"), "foobar\n")
end

T["cr_concat"]["carriage return overwrites the current line"] = function()
  MiniTest.expect.equality(ansi.cr_concat("", "\r 10%|one\r 20%|two"), " 20%|two")
end

T["cr_concat"]["overwrites the tail of existing text across events"] = function()
  MiniTest.expect.equality(ansi.cr_concat(" 10%|one", "\r 20%|two\n"), " 20%|two\n")
end

T["cr_concat"]["preserves earlier completed lines"] = function()
  MiniTest.expect.equality(ansi.cr_concat("first\nsecond", "\rthird"), "first\nthird")
end

T["cr_concat"]["CRLF collapses the line (jupyter classic semantics)"] = function()
  MiniTest.expect.equality(ansi.cr_concat("", "abc\r\ndef"), "\ndef")
end

T["parse"] = MiniTest.new_set()

T["parse"]["passes plain text through with no spans"] = function()
  local text, spans = ansi.parse("hello world")
  MiniTest.expect.equality(text, "hello world")
  MiniTest.expect.equality(spans, {})
end

T["parse"]["maps bold to a highlight group"] = function()
  local text, spans = ansi.parse("\27[1mbold\27[0m")
  MiniTest.expect.equality(text, "bold")
  MiniTest.expect.equality(#spans, 1)
  MiniTest.expect.equality({ spans[1][1], spans[1][2] }, { 0, 4 })
  MiniTest.expect.equality(hl_attrs(spans[1][3]).bold, true)
end

T["parse"]["maps basic foreground colors"] = function()
  local text, spans = ansi.parse("\27[31mred\27[0m plain")
  MiniTest.expect.equality(text, "red plain")
  MiniTest.expect.equality(#spans, 1)
  MiniTest.expect.equality({ spans[1][1], spans[1][2] }, { 0, 3 })
  MiniTest.expect.equality(hex(hl_attrs(spans[1][3]).fg), "#cd0000")
end

T["parse"]["maps bright foreground colors"] = function()
  local _, spans = ansi.parse("\27[91mx")
  MiniTest.expect.equality(hex(hl_attrs(spans[1][3]).fg), "#ff0000")
end

T["parse"]["maps basic background colors"] = function()
  local _, spans = ansi.parse("\27[42mx")
  MiniTest.expect.equality(hex(hl_attrs(spans[1][3]).bg), "#00cd00")
end

T["parse"]["maps 256-color foregrounds"] = function()
  local _, spans = ansi.parse("\27[38;5;34mgreen\27[0m\27[38;5;45mcyan\27[0m")
  MiniTest.expect.equality(#spans, 2)
  MiniTest.expect.equality(hex(hl_attrs(spans[1][3]).fg), "#00af00")
  MiniTest.expect.equality(hex(hl_attrs(spans[2][3]).fg), "#00d7ff")
end

T["parse"]["maps grayscale and low 256-color entries"] = function()
  local _, spans = ansi.parse("\27[38;5;5ma\27[0m\27[38;5;240mb")
  MiniTest.expect.equality(hex(hl_attrs(spans[1][3]).fg), "#cd00cd")
  MiniTest.expect.equality(hex(hl_attrs(spans[2][3]).fg), "#585858")
end

T["parse"]["maps truecolor foregrounds"] = function()
  local _, spans = ansi.parse("\27[38;2;255;0;128mhi")
  MiniTest.expect.equality(hex(hl_attrs(spans[1][3]).fg), "#ff0080")
end

T["parse"]["combines attributes in one sequence"] = function()
  local _, spans = ansi.parse("\27[1;38;5;33mx")
  local attrs = hl_attrs(spans[1][3])
  MiniTest.expect.equality(attrs.bold, true)
  MiniTest.expect.equality(hex(attrs.fg), "#0087ff")
end

T["parse"]["handles italic, underline, strikethrough, and reverse"] = function()
  local _, spans = ansi.parse("\27[3mi\27[0m\27[4mu\27[0m\27[9ms\27[0m\27[7mr")
  MiniTest.expect.equality(hl_attrs(spans[1][3]).italic, true)
  MiniTest.expect.equality(hl_attrs(spans[2][3]).underline, true)
  MiniTest.expect.equality(hl_attrs(spans[3][3]).strikethrough, true)
  MiniTest.expect.equality(hl_attrs(spans[4][3]).reverse, true)
end

T["parse"]["attribute-off codes end the run without resetting the rest"] = function()
  local text, spans = ansi.parse("\27[1;31mboth\27[22mred only")
  MiniTest.expect.equality(text, "bothred only")
  MiniTest.expect.equality(#spans, 2)
  MiniTest.expect.equality({ spans[1][1], spans[1][2] }, { 0, 4 })
  local attrs = hl_attrs(spans[2][3])
  MiniTest.expect.equality(attrs.bold, nil)
  MiniTest.expect.equality(hex(attrs.fg), "#cd0000")
end

T["parse"]["empty params reset the style"] = function()
  local text, spans = ansi.parse("\27[31mred\27[m plain")
  MiniTest.expect.equality(text, "red plain")
  MiniTest.expect.equality(#spans, 1)
end

T["parse"]["spans can cover newlines"] = function()
  local text, spans = ansi.parse("\27[31ma\nb\27[0m")
  MiniTest.expect.equality(text, "a\nb")
  MiniTest.expect.equality(#spans, 1)
  MiniTest.expect.equality({ spans[1][1], spans[1][2] }, { 0, 3 })
end

T["parse"]["drops OSC and cursor sequences like strip does"] = function()
  local text, spans = ansi.parse("\27]0;title\7\27[2K\27[31mred\27[0m")
  MiniTest.expect.equality(text, "red")
  MiniTest.expect.equality(#spans, 1)
  text = ansi.parse("\27]2;t\27\\rest")
  MiniTest.expect.equality(text, "rest")
end

T["parse"]["drops lone and Fe escapes"] = function()
  MiniTest.expect.equality(ansi.parse("a\27c"), "ac")
end

T["parse"]["style persists across calls via state"] = function()
  local state
  local t1, s1
  t1, s1, state = ansi.parse("\27[31mred")
  MiniTest.expect.equality(t1, "red")
  MiniTest.expect.equality(#s1, 1)
  local t2, s2 = ansi.parse(" more\27[0m plain", state)
  MiniTest.expect.equality(t2, " more plain")
  MiniTest.expect.equality(#s2, 1)
  MiniTest.expect.equality({ s2[1][1], s2[1][2] }, { 0, 5 })
  MiniTest.expect.equality(s2[1][3], s1[1][3])
end

T["parse"]["reassembles escape sequences split across calls"] = function()
  local state
  local t1, s1
  t1, s1, state = ansi.parse("a\27[38;5;")
  MiniTest.expect.equality(t1, "a")
  MiniTest.expect.equality(s1, {})
  local t2, s2 = ansi.parse("34mb\27[0m", state)
  MiniTest.expect.equality(t2, "b")
  MiniTest.expect.equality(#s2, 1)
  MiniTest.expect.equality(hex(hl_attrs(s2[1][3]).fg), "#00af00")
end

T["parse"]["trailing lone ESC is held for the next call"] = function()
  local state
  local t1
  t1, _, state = ansi.parse("abc\27")
  MiniTest.expect.equality(t1, "abc")
  MiniTest.expect.equality(ansi.parse("[31mx", state), "x")
end

T["parse"]["same attribute set reuses one highlight group"] = function()
  local _, s1 = ansi.parse("\27[31ma\27[0m")
  local _, s2 = ansi.parse("\27[31mb\27[0m")
  MiniTest.expect.equality(s1[1][3], s2[1][3])
end

T["parse"]["keras-style summary renders readable plain text"] = function()
  local text, spans =
    ansi.parse('\27[1mModel: "sequential"\27[0m\n│ conv2d (\27[38;5;33mConv2D\27[0m) │')
  MiniTest.expect.equality(text, 'Model: "sequential"\n│ conv2d (Conv2D) │')
  MiniTest.expect.equality(#spans, 2)
  MiniTest.expect.equality(hl_attrs(spans[1][3]).bold, true)
  MiniTest.expect.equality(hex(hl_attrs(spans[2][3]).fg), "#0087ff")
end

return T

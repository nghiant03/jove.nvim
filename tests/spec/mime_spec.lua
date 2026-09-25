local MiniTest = require("mini.test")
local mime = require("jove.mime")

local T = MiniTest.new_set()

---@param cond any
local function expect_truthy(cond)
  MiniTest.expect.equality(cond == true, true)
end

---@param chunks table[]
---@param kind string
---@return table?
local function first_of_kind(chunks, kind)
  for _, c in ipairs(chunks) do
    if c.kind == kind then
      return c
    end
  end
  return nil
end

T["ordering"] = MiniTest.new_set()

T["ordering"]["text/plain first, images last, unsupported noted"] = function()
  local chunks = mime.render({
    kind = "display_data",
    mime = {
      ["image/gif"] = "GIF8",
      ["text/html"] = "<b>hi</b>",
      ["application/json"] = '{"a":1}',
      ["text/plain"] = "plain",
    },
  })
  local order = vim
    .iter(chunks)
    :map(function(c)
      return (c.kind == "text" or c.kind == "note") and c.mime or c.kind
    end)
    :totable()
  MiniTest.expect.equality(order, {
    "text/plain",
    "text/html",
    "application/json",
    "image/gif",
  })
end

T["ordering"]["text/plain bundled with an image becomes the image's fallback"] = function()
  local chunks = mime.render({
    kind = "display_data",
    mime = { ["image/png"] = "iVBORw0KGgo=", ["text/plain"] = "<Figure size 100x100>" },
  })
  MiniTest.expect.equality(#chunks, 1)
  MiniTest.expect.equality(chunks[1], {
    kind = "image",
    mime = "image/png",
    data = "iVBORw0KGgo=",
    fallback = "<Figure size 100x100>",
  })
end

T["ordering"]["text/plain without an image stays a standalone chunk"] = function()
  local chunks = mime.render({
    kind = "execute_result",
    mime = { ["text/plain"] = "42" },
  })
  MiniTest.expect.equality(#chunks, 1)
  MiniTest.expect.equality(chunks[1], { kind = "text", mime = "text/plain", text = "42" })
end

T["ordering"]["sorts multiple text/* mimes alphabetically"] = function()
  local chunks = mime.render({
    kind = "display_data",
    mime = { ["text/html"] = "h", ["text/latex"] = "l", ["text/plain"] = "p" },
  })
  local mimes = vim
    .iter(chunks)
    :map(function(c)
      return c.mime
    end)
    :totable()
  MiniTest.expect.equality(mimes, { "text/plain", "text/html", "text/latex" })
end

T["ordering"]["text/html falls back to tag-stripped plain text"] = function()
  local chunks =
    mime.render({ kind = "display_data", mime = { ["text/html"] = "<b>bold</b><br/>x &amp; y" } })
  MiniTest.expect.equality(#chunks, 1)
  MiniTest.expect.equality(chunks[1].kind, "text")
  MiniTest.expect.equality(chunks[1].mime, "text/html")
  MiniTest.expect.equality(chunks[1].text, "bold\nx & y")
end

T["ordering"]["image/png|jpeg become image chunks with base64 data preserved"] = function()
  local chunks = mime.render({
    kind = "execute_result",
    mime = { ["image/png"] = "iVBORw0KGgo=", ["image/jpeg"] = "/9j/4AAQ" },
  })
  MiniTest.expect.equality(#chunks, 2)
  MiniTest.expect.equality(chunks[1], { kind = "image", mime = "image/png", data = "iVBORw0KGgo=" })
  MiniTest.expect.equality(chunks[2], { kind = "image", mime = "image/jpeg", data = "/9j/4AAQ" })
end

T["ordering"]["image/svg+xml becomes a text note (no direct svg support)"] = function()
  local chunks = mime.render({ kind = "display_data", mime = { ["image/svg+xml"] = "<svg/>" } })
  MiniTest.expect.equality(#chunks, 1)
  MiniTest.expect.equality(chunks[1].kind, "note")
  expect_truthy(chunks[1].text:find("svg", 1, true) ~= nil)
end

T["ordering"]["unknown mimes become an unsupported note"] = function()
  local chunks = mime.render({ kind = "display_data", mime = { ["application/x-foo"] = "bar" } })
  MiniTest.expect.equality(#chunks, 1)
  MiniTest.expect.equality(chunks[1].kind, "note")
  MiniTest.expect.equality(chunks[1].text, "[unsupported mime application/x-foo]")
end

T["ordering"]["non-string payloads become a note instead of erroring"] = function()
  local chunks = mime.render({ kind = "display_data", mime = { ["application/json"] = { a = 1 } } })
  MiniTest.expect.equality(#chunks, 1)
  MiniTest.expect.equality(chunks[1].kind, "note")
end

T["stream"] = MiniTest.new_set()

T["stream"]["renders the text/plain payload raw"] = function()
  local chunks =
    mime.render({ kind = "stream", name = "stdout", mime = { ["text/plain"] = "1\n2\n" } })
  MiniTest.expect.equality(#chunks, 1)
  MiniTest.expect.equality(chunks[1].kind, "text")
  MiniTest.expect.equality(chunks[1].text, "1\n2\n")
  MiniTest.expect.equality(chunks[1].hl_group, nil)
end

T["error"] = MiniTest.new_set()

T["error"]["ename: evalue chunk first, stripped traceback after, ErrorMsg hl"] = function()
  local chunks = mime.render({
    kind = "error",
    ename = "ValueError",
    evalue = "bad input",
    traceback = {
      "\27[0;31m---------------------------------------------------------------------------\27[0m",
      "\27[0;31mValueError\27[0m                                 Traceback (most recent call last)",
      "somewhere in the cell",
    },
  })
  MiniTest.expect.equality(#chunks, 2)
  MiniTest.expect.equality(chunks[1].text, "ValueError: bad input")
  MiniTest.expect.equality(chunks[1].hl_group, "ErrorMsg")
  MiniTest.expect.equality(chunks[2].hl_group, "ErrorMsg")
  MiniTest.expect.equality(
    chunks[2].text,
    "---------------------------------------------------------------------------\n"
      .. "ValueError                                 Traceback (most recent call last)\n"
      .. "somewhere in the cell"
  )
  expect_truthy(chunks[2].text:find("\27", 1, true) == nil)
end

T["error"]["falls back to mime text/plain when no traceback"] = function()
  local chunks = mime.render({
    kind = "error",
    ename = "ZeroDivisionError",
    evalue = "division by zero",
    mime = { ["text/plain"] = "\27[31mzero division detail\27[0m" },
  })
  MiniTest.expect.equality(#chunks, 2)
  local tb = chunks[2]
  MiniTest.expect.equality(tb.text, "zero division detail")
end

T["error"]["renders a note when there are no details at all"] = function()
  local chunks = mime.render({ kind = "error" })
  MiniTest.expect.equality(#chunks, 1)
  MiniTest.expect.equality(chunks[1].kind, "note")
  MiniTest.expect.equality(chunks[1].hl_group, "ErrorMsg")
end

T["misc"] = MiniTest.new_set()

T["misc"]["unknown kinds render generically from the mime bundle"] = function()
  local chunks = mime.render({ kind = "mystery", mime = { ["text/plain"] = "x" } })
  MiniTest.expect.equality(#chunks, 1)
  MiniTest.expect.equality(first_of_kind(chunks, "text").text, "x")
end

T["misc"]["empty params render to no chunks"] = function()
  MiniTest.expect.equality(mime.render({}), {})
  MiniTest.expect.equality(mime.render(nil), {})
end

T["html_table"] = MiniTest.new_set()

local STYLED_TABLE = [[
<style>.dataframe td { color: red; }</style>
<table border="1" class="dataframe">
  <thead><tr><th>a</th><th>long</th></tr></thead>
  <tbody>
    <tr><td>1</td><td>xy &amp; z</td></tr>
    <tr><td>22</td><td>w</td></tr>
  </tbody>
</table>
]]

T["html_table"]["renders padded columns with a header separator"] = function()
  local lines = mime.html_table(STYLED_TABLE)
  MiniTest.expect.equality(lines, {
    "a   long",
    "──  ──────",
    "1   xy & z",
    "22  w",
  })
end

T["html_table"]["strips style blocks and decodes entities"] = function()
  local lines = mime.html_table(STYLED_TABLE)
  MiniTest.expect.equality(table.concat(lines, "\n"):find("dataframe", 1, true) == nil, true)
  MiniTest.expect.equality(lines[3]:find("&amp;", 1, true) == nil, true)
  MiniTest.expect.equality(lines[3]:find("xy & z", 1, true) ~= nil, true)
end

T["html_table"]["returns nil when there is no table"] = function()
  MiniTest.expect.equality(mime.html_table("<b>hi</b>"), nil)
  MiniTest.expect.equality(mime.html_table(""), nil)
  MiniTest.expect.equality(mime.html_table(nil), nil)
end

T["html_table"]["returns full rows so the float can show every row"] = function()
  local rows = {}
  for i = 1, 30 do
    rows[#rows + 1] = ("<tr><td>%d</td><td>x</td></tr>"):format(i)
  end
  local lines = mime.html_table("<table>" .. table.concat(rows) .. "</table>")
  expect_truthy(#lines == 30)
  MiniTest.expect.equality(lines[#lines], "30  x")
  expect_truthy(lines[15]:find("15", 1, true) ~= nil)
end

T["html_table"]["render prefers table layout over tag-stripping"] = function()
  local chunks = mime.render({ kind = "display_data", mime = { ["text/html"] = STYLED_TABLE } })
  MiniTest.expect.equality(#chunks, 1)
  MiniTest.expect.equality(chunks[1].kind, "text")
  MiniTest.expect.equality(chunks[1].mime, "text/html")
  expect_truthy(chunks[1].text:find("─", 1, true) ~= nil)
end

return T

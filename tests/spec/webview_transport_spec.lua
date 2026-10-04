local MiniTest = require("mini.test")
local transport = require("jove.webview.transport")
local T = MiniTest.new_set()

local function make()
  local out = { output = {}, input = {}, graphics = {}, placed = {} }
  local relay = transport.new(123, { 10, 20 }, {
    output = function(data)
      out.output[#out.output + 1] = data
    end,
    input = function(data)
      out.input[#out.input + 1] = data
    end,
    graphics = function(data)
      out.graphics[#out.graphics + 1] = data
    end,
    placed = function(cols, rows)
      out.placed[#out.placed + 1] = { cols, rows }
    end,
  })
  relay:resize(80, 24)
  return relay, out
end

T["feed"] = MiniTest.new_set()
T["kitty"] = MiniTest.new_set()

T["feed"]["preserves fragmented ANSI sequences and Unicode text"] = function()
  local relay, out = make()
  local text = "\27[?1049h\27[31mhello 世界\27[0m\r\n\27]2;title\7\27P>|answer\27\\"
  for i = 1, #text do
    relay:feed(text:sub(i, i))
  end
  MiniTest.expect.equality(table.concat(out.output), text)
  MiniTest.expect.equality(relay.pending, "")
end

T["feed"]["answers pixel queries using the current viewport and cell dimensions"] = function()
  local relay, out = make()
  relay:feed("\27[1")
  relay:feed("6t\27[14t")
  MiniTest.expect.equality(out.input, { "\27[6;20;10t", "\27[4;480;800t" })
  relay:resize(50, 10)
  relay:feed("\27[14t")
  MiniTest.expect.equality(out.input[3], "\27[4;200;500t")
end

T["kitty"]["relays complete frames atomically with a session-local virtual placement"] = function()
  local relay, out = make()
  local first = "\27_Ga=T,f=32,o=z,s=800,v=480,t=d,i=1,p=1,C=1,z=0,q=2,m=1;AAAA\27\\"
  for i = 1, #first do
    relay:feed(first:sub(i, i))
  end
  MiniTest.expect.equality(out.graphics, {})
  relay:feed("\27_Gm=0;BBBB\27\\")
  MiniTest.expect.equality(#out.graphics, 1)
  MiniTest.expect.equality(
    out.graphics[1],
    "\27_Ga=T,t=d,q=2,U=1,i=123,c=80,r=24,f=32,o=z,s=800,v=480,m=1;AAAA\27\\\27_Gm=0;BBBB\27\\"
  )
  MiniTest.expect.equality(out.placed, { { 80, 24 } })
  MiniTest.expect.equality(out.output, {})
end

T["kitty"]["restricts global browser deletes to the session image"] = function()
  local relay, out = make()
  relay:feed("\27_Ga=d,d=A,q=2\27\\")
  MiniTest.expect.equality(out.graphics, { "\27_Ga=d,d=I,i=123,q=2\27\\" })
end

T["kitty"]["answers graphics queries locally and advertises only inline transport"] = function()
  local relay, out = make()
  relay:feed("\27_Gi=4207,a=q,t=d,f=24,s=1,v=1;AAAA\27\\")
  relay:feed("\27_Gi=299,a=q,t=s,f=32,s=1,v=1;AAAA\27\\")
  MiniTest.expect.equality(out.input, { "\27_Gi=4207;OK\27\\", "\27_Gi=299;ENOTSUP\27\\" })
  MiniTest.expect.equality(out.graphics, {})
end

return T

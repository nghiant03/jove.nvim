local MiniTest = require("mini.test")
local document = require("jove.webview.document")
local T = MiniTest.new_set()

local function render(bundle)
  return document.from_outputs({ { kind = "display_data", mime = bundle } })
end

local function specification(html)
  return vim.json.decode(
    html:match('<script id="jove%-spec" type="application/json">(.-)</script>')
  )
end

T["from_outputs"] = MiniTest.new_set()

T["from_outputs"]["renders Plotly JSON instead of its notebook-dependent HTML fallback"] = function()
  local spec = {
    data = { { type = "scatter", x = { 1, 2 }, y = { 3, 4 } } },
    layout = { title = { text = "Example" } },
    config = { scrollZoom = true, responsive = false },
    frames = { { name = "next", data = { { y = { 5, 6 } } } } },
  }
  local html = assert(render({
    ["application/vnd.plotly.v1+json"] = spec,
    ["text/html"] = "require(['plotly'], ...)",
  }))
  MiniTest.expect.equality(specification(html), spec)
  MiniTest.expect.equality(html:find("Plotly.newPlot", 1, true) ~= nil, true)
  MiniTest.expect.equality(html:find("Plotly.addFrames", 1, true) ~= nil, true)
  MiniTest.expect.equality(html:find("require(['plotly']", 1, true), nil)
end

T["from_outputs"]["accepts serialized specifications and escapes HTML-sensitive chart data"] = function()
  local spec = { data = {}, layout = { title = "</script><script>example()</script>" } }
  local html = assert(render({ ["application/vnd.plotly.v1+json"] = vim.json.encode(spec) }))
  MiniTest.expect.equality(specification(html), spec)
  MiniTest.expect.equality(html:find(spec.layout.title, 1, true), nil)
end

for _, case in ipairs({
  { "vegalite", 4, 5, 6 },
  { "vegalite", 5, 5, 6 },
  { "vegalite", 6, 6, 7 },
  { "vega", 5, 5, 6 },
  { "vega", 6, 6, 7 },
}) do
  local kind, version, vega, embed = unpack(case)
  T["from_outputs"][("loads compatible libraries for %s v%d"):format(kind, version)] = function()
    local spec = { mark = "point", data = { values = { { x = 1, y = 2 } } } }
    local html = assert(render({ [("application/vnd.%s.v%d+json"):format(kind, version)] = spec }))
    MiniTest.expect.equality(specification(html), spec)
    MiniTest.expect.equality(html:find("vega@" .. vega .. "/", 1, true) ~= nil, true)
    MiniTest.expect.equality(html:find("vega-embed@" .. embed .. "/", 1, true) ~= nil, true)
    if kind == "vegalite" then
      MiniTest.expect.equality(html:find("vega-lite@" .. version .. "/", 1, true) ~= nil, true)
    end
  end
end

T["from_outputs"]["retains same-cell HTML initialization and skips trailing text"] = function()
  local html = assert(document.from_outputs({
    { mime = { ["text/html"] = { "<script>", "window.ready=true;</script>" } } },
    { mime = { ["text/html"] = "<button onclick='this.textContent=ready'>Test</button>" } },
    { kind = "stream", mime = { ["text/plain"] = "done" } },
  }))
  MiniTest.expect.equality(
    html,
    "<script>window.ready=true;</script>\n<button onclick='this.textContent=ready'>Test</button>"
  )
end

T["from_outputs"]["selects the latest rich output"] = function()
  local html = assert(document.from_outputs({
    { mime = { ["text/html"] = "older" } },
    { mime = { ["application/vnd.plotly.v1+json"] = { data = {} } } },
    { kind = "stream", mime = { ["text/plain"] = "done" } },
  }))
  MiniTest.expect.equality(html:find("Plotly.newPlot", 1, true) ~= nil, true)
end

T["from_outputs"]["explains missing widget support instead of opening a text fallback"] = function()
  local html, err = render({
    ["application/vnd.jupyter.widget-view+json"] = { model_id = "abc" },
    ["text/html"] = "<b>Widget loading</b>",
    ["text/plain"] = "FigureWidget()",
  })
  MiniTest.expect.equality(html, nil)
  MiniTest.expect.equality(err:find("kernel comms", 1, true) ~= nil, true)
end

T["from_outputs"]["lists unrecognized MIME types"] = function()
  local html, err = render({ ["application/x-example"] = "data", ["text/plain"] = "fallback" })
  MiniTest.expect.equality(html, nil)
  MiniTest.expect.equality(err:find("application/x-example, text/plain", 1, true) ~= nil, true)
end

T["from_outputs"]["reports malformed specifications without throwing"] = function()
  local html, err = render({ ["application/vnd.plotly.v1+json"] = "not JSON" })
  MiniTest.expect.equality(html, nil)
  MiniTest.expect.equality(
    err:find("could not render application/vnd.plotly.v1+json", 1, true) ~= nil,
    true
  )
end

T["register_renderer"] = MiniTest.new_set()

T["register_renderer"]["adds and replaces a library-specific HTML renderer"] = function()
  local webview = require("jove.webview")
  webview.register_renderer("application/x-jove-test", function(value)
    return "<b>" .. value .. "</b>"
  end)
  MiniTest.expect.equality(render({ ["application/x-jove-test"] = "example" }), "<b>example</b>")
  webview.register_renderer("application/x-jove-test", function()
    return "replacement"
  end)
  MiniTest.expect.equality(render({ ["application/x-jove-test"] = "example" }), "replacement")
end

return T

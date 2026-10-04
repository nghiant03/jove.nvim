-- Convert Jupyter rich MIME bundles into standalone browser documents.
local M = {}

---@type table<string, fun(value: any): string>
local renderers = {}
local order = {}
local widget_mime = "application/vnd.jupyter.widget-view+json"

---@param mime string
---@param renderer fun(value: any): string  Returns standalone HTML.
function M.register(mime, renderer)
  assert(type(mime) == "string" and mime ~= "", "expected a MIME type")
  assert(type(renderer) == "function", "expected an HTML renderer")
  if not renderers[mime] then
    table.insert(order, 1, mime)
  end
  renderers[mime] = renderer
end

---@param value any
---@return table
local function spec_of(value)
  if type(value) == "string" then
    value = vim.json.decode(value)
  end
  assert(type(value) == "table", "expected a JSON specification")
  return value
end

---@param spec table
---@param scripts string[]
---@param run string
---@return string
local function document(spec, scripts, run)
  -- JSON inside a script element must not contain a literal closing script tag.
  local json = vim.json.encode(spec):gsub("<", "\\u003c")
  local parts = {
    '<!doctype html><html><head><meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    "<title>Jove output</title>",
    "<style>body{margin:0;background:white;color:#222}#jove-view{min-height:480px}",
    "#jove-error{white-space:pre-wrap;padding:16px;font:14px monospace}</style></head><body>",
    '<div id="jove-view"></div><pre id="jove-error" hidden></pre>',
    '<script>function joveError(error){const el=document.getElementById("jove-error");',
    "el.hidden=false;el.textContent=String(error && error.message || error);}</script>",
  }
  for _, url in ipairs(scripts) do
    parts[#parts + 1] = ('<script src="%s" onerror="joveError(\'Could not load %s. Check network access.\')"></script>'):format(
      url,
      url
    )
  end
  parts[#parts + 1] = '<script id="jove-spec" type="application/json">' .. json .. "</script>"
  parts[#parts + 1] = '<script>(async function(){try{const spec=JSON.parse(document.getElementById("jove-spec").textContent);'
    .. run
    .. "}catch(error){joveError(error);}})();</script></body></html>"
  return table.concat(parts, "\n")
end

M.register("application/vnd.plotly.v1+json", function(value)
  local spec = spec_of(value)
  assert(type(spec.data) == "table", "Plotly specification has no data array")
  return document(
    spec,
    { "https://cdn.plot.ly/plotly-3.6.0.min.js" },
    [[
    if (!window.Plotly) throw new Error("Could not load Plotly. Check network access to cdn.plot.ly.");
    const plot = await Plotly.newPlot("jove-view", spec.data, spec.layout || {},
      Object.assign({responsive:true}, spec.config || {}));
    if (spec.frames && spec.frames.length) await Plotly.addFrames(plot, spec.frames);
  ]]
  )
end)

for _, version in ipairs({ 4, 5, 6 }) do
  local major = version
  M.register(("application/vnd.vegalite.v%d+json"):format(major), function(value)
    local vega = major >= 6 and 6 or 5
    local embed = major >= 6 and 7 or 6
    return document(spec_of(value), {
      ("https://cdn.jsdelivr.net/npm/vega@%d/build/vega.min.js"):format(vega),
      ("https://cdn.jsdelivr.net/npm/vega-lite@%d/build/vega-lite.min.js"):format(major),
      ("https://cdn.jsdelivr.net/npm/vega-embed@%d/build/vega-embed.min.js"):format(embed),
    }, [[await vegaEmbed("#jove-view", spec, {mode:"vega-lite"});]])
  end)
end

for _, version in ipairs({ 5, 6 }) do
  local major = version
  M.register(("application/vnd.vega.v%d+json"):format(major), function(value)
    return document(spec_of(value), {
      ("https://cdn.jsdelivr.net/npm/vega@%d/build/vega.min.js"):format(major),
      ("https://cdn.jsdelivr.net/npm/vega-embed@%d/build/vega-embed.min.js"):format(
        major == 6 and 7 or 6
      ),
    }, [[await vegaEmbed("#jove-view", spec, {mode:"vega"});]])
  end)
end

---@param value any
---@return string?
local function html_of(value)
  if type(value) == "string" then
    return value
  elseif type(value) == "table" and vim.islist(value) then
    return table.concat(value, "")
  end
end

--- Select the latest renderable output, preferring rich specifications over HTML
--- fallbacks. HTML initialization emitted earlier in the same cell is retained.
---@param outputs table[]
---@return string? html, string? err
function M.from_outputs(outputs)
  local seen = {}
  for i = #outputs, 1, -1 do
    local bundle = outputs[i].mime or {}
    for mime in pairs(bundle) do
      seen[mime] = true
    end
    for _, mime in ipairs(order) do
      if bundle[mime] ~= nil then
        local ok, html = pcall(renderers[mime], bundle[mime])
        if not ok or type(html) ~= "string" or html == "" then
          return nil, ("could not render %s: %s"):format(mime, tostring(html))
        end
        return html
      end
    end
    if bundle[widget_mime] ~= nil then
      return nil,
        "this output is a Jupyter widget; live widgets require a widget manager and kernel comms, which Jove does not yet support. For Plotly, use fig.show(renderer='plotly_mimetype') on a Figure instead of FigureWidget"
    end
    local html = html_of(bundle["text/html"])
    if html then
      local parts = {}
      for j = 1, i - 1 do
        local earlier = html_of((outputs[j].mime or {})["text/html"])
        if earlier then
          parts[#parts + 1] = earlier
        end
      end
      parts[#parts + 1] = html
      return table.concat(parts, "\n")
    end
  end
  local types = vim.tbl_keys(seen)
  table.sort(types)
  return nil,
    "no supported webview output in this cell (MIME types: " .. table.concat(types, ", ") .. ")"
end

return M

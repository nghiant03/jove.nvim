---@diagnostic disable: duplicate-set-field, missing-fields, need-check-nil, param-type-mismatch
local MiniTest = require("mini.test")
local persist = require("jove.persist")
local cell = require("jove.cell")

local T = MiniTest.new_set()

---@param cond any
local function expect_truthy(cond)
  MiniTest.expect.equality(cond == true, true)
end

T["to_nbformat"] = MiniTest.new_set()

T["to_nbformat"]["name and text from the mime bundle"] = function()
  local out = persist.to_nbformat({
    cell = "h",
    kind = "stream",
    name = "stderr",
    mime = { ["text/plain"] = "boom\n" },
  })
  MiniTest.expect.equality(out.output_type, "stream")
  MiniTest.expect.equality(out.name, "stderr")
  MiniTest.expect.equality(out.text, "boom\n")
end

T["to_nbformat"]["data passthrough and metadata after execute"] = function()
  local out =
    persist.to_nbformat({ cell = "h", kind = "execute_result", mime = { ["text/plain"] = "49" } })
  MiniTest.expect.equality(out.output_type, "execute_result")
  MiniTest.expect.equality(out.data["text/plain"], "49")
  MiniTest.expect.equality(out.metadata, {})
  MiniTest.expect.equality(out.execution_count, vim.NIL)
end

T["to_nbformat"]["bridge execution_count passthrough after execute"] = function()
  local out = persist.to_nbformat({
    cell = "h",
    kind = "execute_result",
    mime = { ["text/plain"] = "49" },
    execution_count = 5,
  })
  MiniTest.expect.equality(out.execution_count, 5)
  local bad = persist.to_nbformat({ kind = "execute_result", execution_count = "5" })
  MiniTest.expect.equality(bad.execution_count, vim.NIL)
end

T["to_nbformat"]["display_data and error keep ANSI traceback raw"] = function()
  local dd = persist.to_nbformat({
    cell = "h",
    kind = "display_data",
    mime = { ["text/html"] = "<b>x</b>" },
  })
  MiniTest.expect.equality(dd.output_type, "display_data")
  MiniTest.expect.equality(dd.data["text/html"], "<b>x</b>")

  local tb = { "\27[0;31mZeroDivisionError\27[0m", "division by zero" }
  local err = persist.to_nbformat({
    cell = "h",
    kind = "error",
    ename = "ZeroDivisionError",
    evalue = "division by zero",
    traceback = tb,
  })
  MiniTest.expect.equality(err.output_type, "error")
  MiniTest.expect.equality(err.ename, "ZeroDivisionError")
  MiniTest.expect.equality(err.evalue, "division by zero")
  MiniTest.expect.equality(err.traceback, tb)
end

T["to_nbformat"]["unknown kind to nil"] = function()
  MiniTest.expect.equality(persist.to_nbformat({ kind = "mystery" }) == nil, true)
  MiniTest.expect.equality(persist.to_nbformat({}) == nil, true)
end

T["to_nbformat"]["encodes object-typed fields as JSON objects, not arrays"] = function()
  local result = vim.json.encode(
    persist.to_nbformat({ kind = "execute_result", mime = { ["text/plain"] = "1" } })
  )
  expect_truthy(result:find('"metadata":{}', 1, true) ~= nil)
  expect_truthy(result:find('"data":{', 1, true) ~= nil)

  local empty = vim.json.encode(persist.to_nbformat({ kind = "execute_result" }))
  expect_truthy(empty:find('"data":{}', 1, true) ~= nil)
  expect_truthy(empty:find('"metadata":{}', 1, true) ~= nil)

  local dd = vim.json.encode(persist.to_nbformat({ kind = "display_data" }))
  expect_truthy(dd:find('"data":{}', 1, true) ~= nil)
  expect_truthy(dd:find('"metadata":{}', 1, true) ~= nil)

  local err = vim.json.encode(persist.to_nbformat({ kind = "error", ename = "E" }))
  expect_truthy(err:find('"traceback":[]', 1, true) ~= nil)
end

T["to_raw"] = MiniTest.new_set()

T["to_raw"]["preserves rich JSON specifications through notebook output round trips"] = function()
  local bundle = {
    ["application/vnd.plotly.v1+json"] = {
      data = { { x = { 1, 2 }, y = { 3, 4 } } },
      layout = { title = "Saved figure" },
    },
    ["application/vnd.vegalite.v5+json"] = { mark = "point" },
    ["application/vnd.jupyter.widget-view+json"] = { model_id = "abc" },
    ["application/json"] = { "JSON", "array" },
    ["text/html"] = { "<b>", "fallback</b>" },
  }
  for _, kind in ipairs({ "display_data", "execute_result" }) do
    local raw = persist.to_raw({ output_type = kind, data = bundle })
    local expected = vim.deepcopy(bundle)
    expected["text/html"] = "<b>fallback</b>"
    MiniTest.expect.equality(raw.mime, expected)
    MiniTest.expect.equality(persist.to_nbformat(raw).data, expected)
    raw.mime["application/vnd.plotly.v1+json"].layout.title = "Changed"
    MiniTest.expect.equality(bundle["application/vnd.plotly.v1+json"].layout.title, "Saved figure")
  end
end

T["to_raw"]["string text and line-list text both join to a string after execute"] = function()
  local a = persist.to_raw({ output_type = "stream", name = "stdout", text = "42\n" })
  MiniTest.expect.equality(a.kind, "stream")
  MiniTest.expect.equality(a.name, "stdout")
  MiniTest.expect.equality(a.mime["text/plain"], "42\n")

  local b = persist.to_raw({ output_type = "stream", name = "stdout", text = { "42\n" } })
  MiniTest.expect.equality(b.mime["text/plain"], "42\n")

  local c = persist.to_raw({ output_type = "stream", text = { "one\n", "two" } })
  MiniTest.expect.equality(c.mime["text/plain"], "one\ntwo")
end

T["to_raw"]["list values normalized to strings for mime.render in data bundles"] = function()
  local r = persist.to_raw({
    output_type = "execute_result",
    data = { ["text/plain"] = { "49\n" }, ["text/html"] = "<b>49</b>" },
  })
  MiniTest.expect.equality(r.kind, "execute_result")
  MiniTest.expect.equality(r.mime["text/plain"], "49\n")
  MiniTest.expect.equality(r.mime["text/html"], "<b>49</b>")
end

T["to_raw"]["ename/evalue/traceback pass through raw in error"] = function()
  local tb = { "\27[0;31merr\27[0m" }
  local r = persist.to_raw({ output_type = "error", ename = "E", evalue = "v", traceback = tb })
  MiniTest.expect.equality(r.kind, "error")
  MiniTest.expect.equality(r.ename, "E")
  MiniTest.expect.equality(r.evalue, "v")
  MiniTest.expect.equality(r.traceback, tb)
end

T["to_raw"]["unknown type to nil"] = function()
  MiniTest.expect.equality(persist.to_raw({ output_type = "mystery" }) == nil, true)
  MiniTest.expect.equality(persist.to_raw({}) == nil, true)
end

T["merge_into"] = MiniTest.new_set()

local NB = {
  cells = {
    {
      cell_type = "code",
      source = { "x = 41\n", "x + 1" },
      outputs = { { output_type = "stream", text = "old" } },
    },
    { cell_type = "code", source = { "y = 7\n", "y * 7" }, outputs = {} },
    {
      cell_type = "code",
      source = { "z = 1\n", "z + 1" },
      outputs = { { output_type = "stream", text = "keep me" } },
    },
    { cell_type = "markdown", source = { "# not code" } },
  },
}

T["merge_into"]["session outputs replace matched cells, unmatched keep preserved"] = function()
  local store = {
    [cell.hash_source(NB.cells[1].source)] = {
      raw = { { cell = "h", kind = "execute_result", mime = { ["text/plain"] = "session-1" } } },
    },
    [cell.hash_source(NB.cells[2].source)] = {
      raw = {
        { cell = "h", kind = "stream", name = "stdout", mime = { ["text/plain"] = "s\n" } },
        { cell = "h", kind = "error", ename = "E", evalue = "v", traceback = { "tb" } },
      },
    },
  }
  local nb = vim.deepcopy(NB)
  local merged = persist.merge_into(nb, store)
  MiniTest.expect.equality(merged, 2)

  MiniTest.expect.equality(nb.cells[1].outputs[1].output_type, "execute_result")
  MiniTest.expect.equality(nb.cells[1].outputs[1].data["text/plain"], "session-1")
  MiniTest.expect.equality(nb.cells[1].execution_count, vim.NIL)
  MiniTest.expect.equality(#nb.cells[2].outputs, 2)
  MiniTest.expect.equality(nb.cells[2].outputs[1].output_type, "stream")
  MiniTest.expect.equality(nb.cells[2].outputs[2].output_type, "error")
  MiniTest.expect.equality(nb.cells[2].execution_count, vim.NIL)

  MiniTest.expect.equality(nb.cells[3].outputs[1].text, "keep me")
  MiniTest.expect.equality(merged == 4, false)
end

T["merge_into"]["seen-but-cleared hash writes empty outputs"] = function()
  local nb = vim.deepcopy(NB)
  local seen_hashes = {
    [cell.hash_source(NB.cells[1].source)] = true,
    [cell.hash_source(NB.cells[2].source)] = true,
  }
  local merged = persist.merge_into(nb, {}, seen_hashes)
  MiniTest.expect.equality(merged, 2)
  MiniTest.expect.equality(#nb.cells[1].outputs, 0)
  MiniTest.expect.equality(nb.cells[1].execution_count, vim.NIL)
  MiniTest.expect.equality(#nb.cells[2].outputs, 0)

  MiniTest.expect.equality(nb.cells[3].outputs[1].text, "keep me")
  MiniTest.expect.equality(nb.cells[3].execution_count == nil, true)
end

T["merge_into"]["precedence: session outputs beat tombstone"] = function()
  local nb = vim.deepcopy(NB)
  local h1 = cell.hash_source(NB.cells[1].source)
  local store = {
    [h1] = {
      raw = {
        { cell = h1, kind = "stream", name = "stdout", mime = { ["text/plain"] = "ran again\n" } },
      },
    },
  }
  local seen_hashes = { [h1] = true }
  persist.merge_into(nb, store, seen_hashes)
  MiniTest.expect.equality(nb.cells[1].outputs[1].output_type, "stream")
  MiniTest.expect.equality(nb.cells[1].outputs[1].text, "ran again\n")
end

T["merge_into"]["run meta count replaces null on cells and execute_result outputs"] = function()
  local nb = vim.deepcopy(NB)
  local h1 = cell.hash_source(NB.cells[1].source)
  local store = {
    [h1] = {
      raw = { { cell = h1, kind = "execute_result", mime = { ["text/plain"] = "session-1" } } },
    },
  }
  local meta = { [h1] = { count = 12, elapsed_ms = 3.5 } }
  persist.merge_into(nb, store, nil, meta)
  MiniTest.expect.equality(nb.cells[1].execution_count, 12)
  MiniTest.expect.equality(nb.cells[1].outputs[1].execution_count, 12)
  MiniTest.expect.equality(nb.cells[2].execution_count == nil, true)
end

T["merge_into"]["run count persists with no store/seen for meta only cell"] = function()
  local nb = vim.deepcopy(NB)
  local h1 = cell.hash_source(NB.cells[1].source)
  local meta = { [h1] = { count = 4 } }
  local merged = persist.merge_into(nb, nil, nil, meta)
  MiniTest.expect.equality(merged, 1)
  MiniTest.expect.equality(nb.cells[1].execution_count, 4)
  MiniTest.expect.equality(nb.cells[1].outputs[1].text, "old")
  MiniTest.expect.equality(nb.cells[2].execution_count == nil, true)
end

T["merge_into"]["cell and execute_result outputs have null execution_count when persists_exec_count is false"] = function()
  local nb = vim.deepcopy(NB)
  local h1 = cell.hash_source(NB.cells[1].source)
  local store = {
    [h1] = {
      raw = {
        {
          cell = h1,
          kind = "execute_result",
          mime = { ["text/plain"] = "session-1" },
          execution_count = 5,
        },
      },
    },
  }
  local meta = { [h1] = { count = 5 } }
  local merged = persist.merge_into(nb, store, nil, meta, false)
  MiniTest.expect.equality(merged, 1)
  MiniTest.expect.equality(nb.cells[1].execution_count, vim.NIL)
  MiniTest.expect.equality(nb.cells[1].outputs[1].execution_count, vim.NIL)
end

T["merge_into"]["empty store or malformed notebook then untouched"] = function()
  local nb = vim.deepcopy(NB)
  MiniTest.expect.equality(persist.merge_into(nb, {}), 0)
  MiniTest.expect.equality(persist.merge_into(nb, nil), 0)
  MiniTest.expect.equality(nb.cells[1].outputs[1].text, "old")
  MiniTest.expect.equality(persist.merge_into({ cells = "nope" }, nil), 0)
  MiniTest.expect.equality(persist.merge_into(nil, nil), 0)
end

return T

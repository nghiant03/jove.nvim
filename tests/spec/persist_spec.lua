-- persist_spec.lua: native output persistence (Phase 6).
-- Unit tests cover the pure nbformat<->raw-params mappings and the
-- hash-matched merge. Integration tests run the REAL jupytext flow through
-- buffer.read/write (buffer_spec precedent): read fixture -> session
-- outputs -> write -> merged JSON on disk -> checksum self-suppression ->
-- reload re-attaches outputs.
local MiniTest = require("mini.test")
local persist = require("jove.persist")
local cell = require("jove.cell")
local state = require("jove.state")
local buffer = require("jove.buffer")

local T = MiniTest.new_set()

---mini.test has no truthy expectation; assert identity against true.
---@param cond any
local function expect_truthy(cond)
  MiniTest.expect.equality(cond == true, true)
end

local FIXTURE = vim.fs.joinpath(vim.fn.getcwd(), "tests", "fixtures", "outputs.ipynb")

---Read a file back from disk synchronously (test-side helper only).
---@param path string
---@return string?
local function read_disk(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local data = fd:read("*a")
  fd:close()
  return data
end

---Copy the fixture into a fresh temp dir; never touches the repo.
---@return string path
local function tmp_copy_fixture()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.joinpath(dir, "outputs.ipynb")
  expect_truthy(vim.uv.fs_copyfile(FIXTURE, path))
  return path
end

---Open `path` through BufReadCmd and wait for the async read to settle.
---@return integer buf
local function open_notebook(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  local settled = vim.wait(30000, function()
    local st = state.peek(buf)
    return st ~= nil and st.path ~= nil and st.json ~= nil and not vim.bo[buf].modified
  end, 10)
  expect_truthy(settled)
  return buf
end

---Map a notebook's code cells to {index = hash}.
---@param nb table
---@return table
local function code_hashes(nb)
  local out = {}
  for i, c in ipairs(nb.cells) do
    if c.cell_type == "code" then
      out[i] = cell.hash_source(c.source)
    end
  end
  return out
end

T["to_nbformat"] = MiniTest.new_set()

T["to_nbformat"]["stream: name + text from the mime bundle"] = function()
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

T["to_nbformat"]["execute_result: data passthrough + metadata"] = function()
  local out =
    persist.to_nbformat({ cell = "h", kind = "execute_result", mime = { ["text/plain"] = "49" } })
  MiniTest.expect.equality(out.output_type, "execute_result")
  MiniTest.expect.equality(out.data["text/plain"], "49")
  MiniTest.expect.equality(out.metadata, {})
  MiniTest.expect.equality(out.execution_count, vim.NIL)
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

T["to_nbformat"]["unknown kind -> nil"] = function()
  MiniTest.expect.equality(persist.to_nbformat({ kind = "mystery" }) == nil, true)
  MiniTest.expect.equality(persist.to_nbformat({}) == nil, true)
end

-- Encode-level assertions: table equality can't catch empty Lua tables
-- encoding as `[]` where nbformat requires `{}` (object) — only the encoded
-- JSON can.
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

  -- traceback/outputs are arrays: `[]` is valid there.
  local err = vim.json.encode(persist.to_nbformat({ kind = "error", ename = "E" }))
  expect_truthy(err:find('"traceback":[]', 1, true) ~= nil)
end

T["to_raw"] = MiniTest.new_set()

T["to_raw"]["stream: string text and line-list text both join to a string"] = function()
  local a = persist.to_raw({ output_type = "stream", name = "stdout", text = "42\n" })
  MiniTest.expect.equality(a.kind, "stream")
  MiniTest.expect.equality(a.name, "stdout")
  MiniTest.expect.equality(a.mime["text/plain"], "42\n")

  local b = persist.to_raw({ output_type = "stream", name = "stdout", text = { "42\n" } })
  MiniTest.expect.equality(b.mime["text/plain"], "42\n")

  local c = persist.to_raw({ output_type = "stream", text = { "one\n", "two" } })
  MiniTest.expect.equality(c.mime["text/plain"], "one\ntwo")
end

T["to_raw"]["data bundles: list values normalized to strings for mime.render"] = function()
  local r = persist.to_raw({
    output_type = "execute_result",
    data = { ["text/plain"] = { "49\n" }, ["text/html"] = "<b>49</b>" },
  })
  MiniTest.expect.equality(r.kind, "execute_result")
  MiniTest.expect.equality(r.mime["text/plain"], "49\n")
  MiniTest.expect.equality(r.mime["text/html"], "<b>49</b>")
end

T["to_raw"]["error: ename/evalue/traceback pass through raw"] = function()
  local tb = { "\27[0;31merr\27[0m" }
  local r = persist.to_raw({ output_type = "error", ename = "E", evalue = "v", traceback = tb })
  MiniTest.expect.equality(r.kind, "error")
  MiniTest.expect.equality(r.ename, "E")
  MiniTest.expect.equality(r.evalue, "v")
  MiniTest.expect.equality(r.traceback, tb)
end

T["to_raw"]["unknown type -> nil"] = function()
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

T["merge_into"]["session outputs replace matched cells; unmatched keep preserved"] = function()
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

  -- Replaced with session content, converted to nbformat; the count is
  -- nulled alongside (session results carry no execution count).
  MiniTest.expect.equality(nb.cells[1].outputs[1].output_type, "execute_result")
  MiniTest.expect.equality(nb.cells[1].outputs[1].data["text/plain"], "session-1")
  MiniTest.expect.equality(nb.cells[1].execution_count, vim.NIL)
  MiniTest.expect.equality(#nb.cells[2].outputs, 2)
  MiniTest.expect.equality(nb.cells[2].outputs[1].output_type, "stream")
  MiniTest.expect.equality(nb.cells[2].outputs[2].output_type, "error")
  MiniTest.expect.equality(nb.cells[2].execution_count, vim.NIL)

  -- Cell 3 has no session outputs: whatever jupytext --update preserved stays.
  MiniTest.expect.equality(nb.cells[3].outputs[1].text, "keep me")
  -- Markdown cells never matched.
  MiniTest.expect.equality(merged == 4, false)
end

T["merge_into"]["tombstone: seen-but-cleared hash writes empty outputs"] = function()
  local nb = vim.deepcopy(NB)
  local seen_hashes = {
    [cell.hash_source(NB.cells[1].source)] = true, -- had outputs, cleared
    [cell.hash_source(NB.cells[2].source)] = true, -- had none, cleared anyway
  }
  local merged = persist.merge_into(nb, {}, seen_hashes)
  MiniTest.expect.equality(merged, 2)
  MiniTest.expect.equality(#nb.cells[1].outputs, 0)
  MiniTest.expect.equality(nb.cells[1].execution_count, vim.NIL)
  MiniTest.expect.equality(#nb.cells[2].outputs, 0)

  -- Unseen cells are untouched (disk truth).
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

T["merge_into"]["empty store / malformed notebook -> 0, untouched"] = function()
  local nb = vim.deepcopy(NB)
  MiniTest.expect.equality(persist.merge_into(nb, {}), 0)
  MiniTest.expect.equality(persist.merge_into(nb, nil), 0)
  MiniTest.expect.equality(nb.cells[1].outputs[1].text, "old")
  MiniTest.expect.equality(persist.merge_into({ cells = "nope" }, nil), 0)
  MiniTest.expect.equality(persist.merge_into(nil, nil), 0)
end

T["export (atomic write)"] = MiniTest.new_set()

T["export (atomic write)"]["merges, temp+renames, refreshes json + checksum"] = function()
  local path = tmp_copy_fixture()
  local bytes = read_disk(path)
  local nb = vim.json.decode(bytes)
  local hashes = code_hashes(nb)

  -- Session outputs for the stream cell and the result cell.
  local buf = vim.api.nvim_create_buf(false, true)
  local st = state.get(buf)
  st.path = path
  st.json = nb
  st.outputs = {
    [hashes[2]] = {
      raw = {
        {
          cell = hashes[2],
          kind = "stream",
          name = "stdout",
          mime = { ["text/plain"] = "session\n" },
        },
      },
    },
    [hashes[3]] = {
      raw = {
        { cell = hashes[3], kind = "execute_result", mime = { ["text/plain"] = "session-2" } },
      },
    },
  }

  expect_truthy(persist.export(buf, bytes))

  -- Merged bytes are on disk atomically (no temp leftovers).
  local merged_bytes = read_disk(path)
  MiniTest.expect.equality(vim.fn.sha256(merged_bytes), st.last_write)
  local leftovers = vim.fn.glob(path .. ".jove-*.tmp", false, true)
  MiniTest.expect.equality(#leftovers, 0)

  -- On-disk JSON has the session outputs on matched cells; the error cell
  -- (absent from the session) keeps its preserved outputs.
  local nb2 = vim.json.decode(merged_bytes)
  MiniTest.expect.equality(nb2.cells[2].outputs[1].text, "session\n")
  MiniTest.expect.equality(nb2.cells[3].outputs[1].data["text/plain"], "session-2")
  MiniTest.expect.equality(nb2.cells[4].outputs[1].output_type, "error")
  MiniTest.expect.equality(nb2.cells[4].outputs[1].ename, "ZeroDivisionError")
  -- st.json refreshed to the merged notebook.
  MiniTest.expect.equality(state.peek(buf).json.cells[2].outputs[1].text, "session\n")

  -- Second export after wiping the session store: the hashes seen this
  -- session (marked by the first export) are TOMBSTONED — deletion persists.
  state.get(buf).outputs = nil
  expect_truthy(persist.export(buf, nil))
  local nb3 = vim.json.decode(read_disk(path))
  MiniTest.expect.equality(#nb3.cells[2].outputs, 0)
  MiniTest.expect.equality(nb3.cells[2].execution_count, vim.NIL)
  MiniTest.expect.equality(#nb3.cells[3].outputs, 0)
  -- Unseen cell 4 still keeps its preserved outputs.
  MiniTest.expect.equality(nb3.cells[4].outputs[1].output_type, "error")
  MiniTest.expect.equality(vim.fn.sha256(read_disk(path)), state.peek(buf).last_write)

  vim.api.nvim_buf_delete(buf, { force = true })
end

T["export (atomic write)"]["copy-before-merge: failed encode leaves st.json untouched"] = function()
  local path = tmp_copy_fixture()
  local original = read_disk(path)
  local buf = vim.api.nvim_create_buf(false, true)
  local st = state.get(buf)
  st.path = path
  local nb = vim.json.decode(original)
  nb.metadata.boom = function() end -- vim.json.encode cannot serialize this
  st.json = nb
  local h = cell.hash_source(nb.cells[2].source)
  st.outputs = {
    [h] = {
      raw = { { cell = h, kind = "stream", name = "stdout", mime = { ["text/plain"] = "x\n" } } },
    },
  }

  MiniTest.expect.equality(persist.export(buf, nil), false)
  -- merge_into mutated only the copy: st.json is the same table, unmutated.
  MiniTest.expect.equality(st.json == nb, true)
  MiniTest.expect.equality(type(st.json.metadata.boom), "function")
  -- Disk untouched.
  MiniTest.expect.equality(read_disk(path), original)

  vim.api.nvim_buf_delete(buf, { force = true })
end

T["export (atomic write)"]["non-jove buffer: silent no-op"] = function()
  -- Fresh scratch buffer with no jove state (never the possibly-reused
  -- current buffer: the suite shares one nvim instance across specs).
  local scratch = vim.api.nvim_create_buf(false, true)
  MiniTest.expect.equality(persist.export(scratch, nil), false)
  vim.api.nvim_buf_delete(scratch, { force = true })
end

T["import"] = MiniTest.new_set()

T["import"]["maps json outputs to raw params keyed by content hash"] = function()
  local path = tmp_copy_fixture()
  local buf = vim.api.nvim_create_buf(false, true)
  local st = state.get(buf)
  st.path = path
  st.json = vim.json.decode(read_disk(path))

  -- Capture what output.import receives (stub the real renderer).
  local received
  local output = require("jove.output")
  local orig_import, orig_clear = output.import, output.clear
  output.import = function(_, by_hash)
    received = by_hash
  end
  output.clear = function() end
  persist.import(buf)
  output.import, output.clear = orig_import, orig_clear

  local hashes = code_hashes(st.json)
  MiniTest.expect.equality(received[hashes[2]][1].kind, "stream")
  MiniTest.expect.equality(received[hashes[2]][1].mime["text/plain"], "42\n")
  MiniTest.expect.equality(received[hashes[3]][1].kind, "execute_result")
  MiniTest.expect.equality(received[hashes[4]][1].kind, "error")
  MiniTest.expect.equality(
    table.concat(received[hashes[4]][1].traceback, "\n"):find("ZeroDivisionError", 1, true) ~= nil,
    true
  )
  -- The output-less cell contributes nothing.
  MiniTest.expect.equality(received[hashes[5]] == nil, true)

  vim.api.nvim_buf_delete(buf, { force = true })
end

---Wait until the buffer's write flow settled (last_write matches disk).
---@param buf integer
---@param path string
local function wait_write_settled(buf, path)
  local settled = vim.wait(30000, function()
    local s = state.peek(buf)
    if not (s and s.last_write) then
      return false
    end
    local bytes = read_disk(path)
    return bytes ~= nil and vim.fn.sha256(bytes) == s.last_write and not vim.bo[buf].modified
  end, 10)
  expect_truthy(settled)
end

---Wait until a reload replaced the buffer's st.json (fresh parsed table).
---@param buf integer
---@param old_json table
local function wait_reload(buf, old_json)
  local settled = vim.wait(30000, function()
    local s = state.peek(buf)
    return s ~= nil and s.json ~= nil and s.json ~= old_json
  end, 10)
  expect_truthy(settled)
end

---Wait until the disk JSON satisfies `cond` AND matches st.last_write (a
---plain checksum wait is ambiguous: it also passes on the previous write's
---consistent state while a new write flow is still in flight).
---@param buf integer
---@param path string
---@param cond fun(nb: table): boolean
local function wait_disk_cond(buf, path, cond)
  local settled = vim.wait(30000, function()
    local s = state.peek(buf)
    if not (s and s.last_write) then
      return false
    end
    local bytes = read_disk(path)
    if not bytes or vim.fn.sha256(bytes) ~= s.last_write then
      return false
    end
    local ok, nb = pcall(vim.json.decode, bytes)
    return ok and cond(nb) and not vim.bo[buf].modified
  end, 10)
  expect_truthy(settled)
end

T["end-to-end (real jupytext)"] = MiniTest.new_set()

T["end-to-end (real jupytext)"]["read -> edit -> write -> reload: outputs survive"] = function()
  local path = tmp_copy_fixture()
  local buf = open_notebook(path)
  local st = state.get(buf)

  -- Read imported the fixture outputs, keyed by content hash.
  local hashes = code_hashes(st.json)
  MiniTest.expect.equality(st.outputs ~= nil and st.outputs[hashes[2]] ~= nil, true)
  MiniTest.expect.equality(st.outputs[hashes[3]] ~= nil, true)
  MiniTest.expect.equality(st.outputs[hashes[4]] ~= nil, true)
  MiniTest.expect.equality(st.outputs[hashes[5]], nil) -- output-less cell

  -- Session outputs: replace cell 2's and add one for a cell we are about to
  -- edit (hash rematching is the P3 fix under test). Cell 4's error outputs
  -- stay session-untouched so we can watch jupytext --update preserve them.
  local edited_lines = { "y = 21\n", "y * 7" }
  local edited = vim.deepcopy(st.json.cells[3])
  edited.source = edited_lines
  local new_hash = cell.hash_source(edited_lines)
  st.outputs[hashes[2]] = {
    raw = { { cell = hashes[2], kind = "execute_result", mime = { ["text/plain"] = "session-2" } } },
  }
  st.outputs[new_hash] = {
    raw = {
      {
        cell = new_hash,
        kind = "stream",
        name = "stdout",
        mime = { ["text/plain"] = "fresh out\n" },
      },
    },
  }

  -- Edit cell 3's body in the buffer (its hash changes to new_hash).
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local at
  for i, l in ipairs(lines) do
    if l == "y = 7" then
      at = i
      break
    end
  end
  expect_truthy(at ~= nil)
  vim.api.nvim_buf_set_lines(buf, at - 1, at, false, { "y = 21" })

  vim.cmd("write")
  local settled = vim.wait(30000, function()
    local s = state.peek(buf)
    if not (s and s.last_write) then
      return false
    end
    local bytes = read_disk(path)
    return bytes ~= nil and vim.fn.sha256(bytes) == s.last_write and not vim.bo[buf].modified
  end, 10)
  expect_truthy(settled)

  -- Disk: edited cell carries its session output under the NEW hash.
  local nb = vim.json.decode(read_disk(path))
  local after = code_hashes(nb)
  MiniTest.expect.equality(after[3], new_hash) -- hash rematched on disk
  MiniTest.expect.equality(nb.cells[3].outputs[1].output_type, "stream")
  MiniTest.expect.equality(nb.cells[3].outputs[1].text, "fresh out\n")
  MiniTest.expect.equality(nb.cells[2].outputs[1].data["text/plain"], "session-2")
  -- Untouched-by-session cell preserved its stored error outputs.
  MiniTest.expect.equality(nb.cells[4].outputs[1].output_type, "error")
  MiniTest.expect.equality(nb.cells[4].outputs[1].ename, "ZeroDivisionError")

  -- Checksum discipline: our merged write must look self-triggered.
  MiniTest.expect.equality(buffer.changed_shell(buf, path), true)

  -- Reload: outputs re-attach from disk (acceptance criterion).
  buffer.reload(buf)
  local reattached = vim.wait(30000, function()
    local s = state.peek(buf)
    return s and s.outputs and s.outputs[new_hash] ~= nil and #s.outputs[new_hash].raw > 0
  end, 10)
  expect_truthy(reattached)
  local entry = state.get(buf).outputs[new_hash]
  MiniTest.expect.equality(entry.raw[1].kind, "stream")
  MiniTest.expect.equality(entry.raw[1].mime["text/plain"], "fresh out\n")

  vim.api.nvim_buf_delete(buf, { force = true })
end

T["end-to-end (real jupytext)"]["clear -> write: deletion persists (disk-imported outputs)"] = function()
  local path = tmp_copy_fixture()
  local buf = open_notebook(path)
  local st = state.get(buf)
  local hashes = code_hashes(st.json)

  -- Session-clear the stream cell (imported from disk at read time, so it
  -- is in the tombstone seen-set).
  require("jove.output").clear(buf, hashes[2])
  MiniTest.expect.equality(st.outputs[hashes[2]] == nil, true)

  vim.cmd("write")
  wait_disk_cond(buf, path, function(nb)
    return #nb.cells[2].outputs == 0
  end)

  local nb = vim.json.decode(read_disk(path))
  MiniTest.expect.equality(#nb.cells[2].outputs, 0) -- deletion persisted
  MiniTest.expect.equality(nb.cells[2].execution_count, vim.NIL)
  -- Other cells untouched on disk.
  MiniTest.expect.equality(nb.cells[3].outputs[1].output_type, "execute_result")
  MiniTest.expect.equality(nb.cells[4].outputs[1].output_type, "error")
  MiniTest.expect.equality(buffer.changed_shell(buf, path), true)

  -- Reload: no resurrection (disk has no outputs for that cell anymore).
  local old_json = st.json
  buffer.reload(buf)
  wait_reload(buf, old_json)
  MiniTest.expect.equality(state.get(buf).outputs[hashes[2]] == nil, true)
  -- ...while the untouched cells still re-attach.
  MiniTest.expect.equality(state.get(buf).outputs[hashes[4]] ~= nil, true)

  vim.api.nvim_buf_delete(buf, { force = true })
end

T["end-to-end (real jupytext)"]["session-persisted then cleared -> tombstoned later"] = function()
  local path = tmp_copy_fixture()
  local buf = open_notebook(path)
  local st = state.get(buf)
  local hashes = code_hashes(st.json)

  -- Session outputs on the output-less cell 5; first write persists them
  -- (and marks the hash seen at export).
  st.outputs[hashes[5]] = {
    raw = {
      { cell = hashes[5], kind = "stream", name = "stdout", mime = { ["text/plain"] = "temp\n" } },
    },
  }
  vim.cmd("write")
  wait_write_settled(buf, path)
  local nb1 = vim.json.decode(read_disk(path))
  MiniTest.expect.equality(nb1.cells[5].outputs[1].text, "temp\n")

  -- Clear + write again: the seen-set (updated at the first export) makes
  -- this a tombstone, not a "keep whatever jupytext preserved".
  require("jove.output").clear(buf, hashes[5])
  vim.cmd("write")
  wait_disk_cond(buf, path, function(nb)
    return #nb.cells[5].outputs == 0
  end)
  local nb2 = vim.json.decode(read_disk(path))
  MiniTest.expect.equality(#nb2.cells[5].outputs, 0)
  MiniTest.expect.equality(nb2.cells[5].execution_count, vim.NIL)

  -- Reload: no resurrection.
  local old_json = state.get(buf).json
  buffer.reload(buf)
  wait_reload(buf, old_json)
  MiniTest.expect.equality(state.get(buf).outputs[hashes[5]] == nil, true)

  vim.api.nvim_buf_delete(buf, { force = true })
end

T["end-to-end (real jupytext)"]["clear -> save -> save again: second save is a no-op"] = function()
  local path = tmp_copy_fixture()
  local buf = open_notebook(path)
  local hashes = code_hashes(state.get(buf).json)

  require("jove.output").clear(buf, hashes[2])
  vim.cmd("write")
  wait_disk_cond(buf, path, function(nb)
    return #nb.cells[2].outputs == 0
  end)

  -- Second save: the tombstoned hash was pruned from the seen-set (and
  -- from_disk entries are skipped) — nothing to merge, no rewrite.
  -- Touch the buffer first (same-content set_lines bumps changedtick) so
  -- the buffer is modified and the settle below can only pass once this
  -- write flow's callback has actually run.
  local first_line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { first_line })
  expect_truthy(vim.bo[buf].modified)

  local export_results = {}
  local orig_export = persist.export
  persist.export = function(b, bytes)
    if b ~= buf then
      return orig_export(b, bytes) -- another buffer's flow: passthrough
    end
    export_results[#export_results + 1] = orig_export(b, bytes)
  end
  vim.cmd("write")
  wait_write_settled(buf, path)
  persist.export = orig_export

  MiniTest.expect.equality(#export_results, 1)
  MiniTest.expect.equality(export_results[1], false)
  -- Tombstone still on disk after the no-op save.
  local nb = vim.json.decode(read_disk(path))
  MiniTest.expect.equality(#nb.cells[2].outputs, 0)

  vim.api.nvim_buf_delete(buf, { force = true })
end

T["end-to-end (real jupytext)"]["pure open->save: no merged rewrite, counts intact"] = function()
  local path = tmp_copy_fixture()
  local buf = open_notebook(path)

  -- Spy on the export path (buffer.lua resolves persist.export per call).
  -- Installed AFTER open: earlier specs' async write flows may still be
  -- settling and must not count here.
  local export_results = {}
  local orig_export = persist.export
  persist.export = function(b, bytes)
    if b ~= buf then
      return orig_export(b, bytes) -- another buffer's flow: passthrough
    end
    export_results[#export_results + 1] = orig_export(b, bytes)
  end

  -- Touch the buffer (same-content set_lines bumps changedtick) so the
  -- settle below can only pass once this write's callback has run.
  local first_line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { first_line })
  vim.cmd("write")
  wait_write_settled(buf, path)
  persist.export = orig_export

  -- Open imported the disk outputs (from_disk entries) but nothing ran or
  -- was cleared: the export path must have found nothing to merge.
  MiniTest.expect.equality(#export_results, 1)
  MiniTest.expect.equality(export_results[1], false)

  -- On-disk execution counts are untouched (regression: they used to null
  -- out on every save via imported-from-disk store entries).
  local nb = vim.json.decode(read_disk(path))
  MiniTest.expect.equality(nb.cells[2].execution_count, 1)
  MiniTest.expect.equality(nb.cells[3].execution_count, 2)
  MiniTest.expect.equality(nb.cells[4].execution_count, 3)
  MiniTest.expect.equality(nb.cells[3].outputs[1].execution_count, 2)
  MiniTest.expect.equality(nb.cells[2].outputs[1].output_type, "stream")

  vim.api.nvim_buf_delete(buf, { force = true })
end

T["end-to-end (real jupytext)"]["session re-run of an imported cell nulls only its count"] = function()
  local path = tmp_copy_fixture()
  local buf = open_notebook(path)
  local hashes = code_hashes(state.get(buf).json)

  -- The cell actually runs in-session: output.push clears the from_disk
  -- provenance flag, so this cell (and only it) is rewritten on save.
  require("jove.output").push(buf, hashes[2], {
    cell = hashes[2],
    kind = "stream",
    name = "stdout",
    mime = { ["text/plain"] = "ran in session\n" },
  })
  vim.cmd("write")
  wait_write_settled(buf, path)

  local nb = vim.json.decode(read_disk(path))
  MiniTest.expect.equality(nb.cells[2].execution_count, vim.NIL) -- ran
  MiniTest.expect.equality(nb.cells[3].execution_count, 2) -- untouched
  MiniTest.expect.equality(nb.cells[4].execution_count, 3) -- untouched
  MiniTest.expect.equality(nb.cells[3].outputs[1].execution_count, 2)
  local texts = {}
  for _, o in ipairs(nb.cells[2].outputs) do
    if o.output_type == "stream" then
      texts[#texts + 1] = o.text
    end
  end
  expect_truthy(table.concat(texts):find("ran in session", 1, true) ~= nil)

  vim.api.nvim_buf_delete(buf, { force = true })
end

return T

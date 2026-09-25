local MiniTest = require("mini.test")
local state = require("jove.state")
local cell = require("jove.cell")
local output = require("jove.output")
local persist = require("jove.persist")
local convert = require("jove.convert")
local buffer = require("jove.buffer")
local bridge = require("jove.bridge")
local kernel = require("jove.kernel")
local jove = require("jove")
local eq = MiniTest.expect.equality
local buf, saved

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      saved = {
        read = convert.read,
        write = convert.write,
        atomic = convert.atomic_write,
        export = persist.export,
        open = io.open,
        new = bridge.new,
        config = vim.deepcopy(jove.config),
      }
      buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = "acwrite"
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %%", "print(1)" })
      state.get(buf).path = "tests/fixtures/smoke.ipynb"
      vim.bo[buf].modified = false
    end,
    post_case = function()
      convert.read, convert.write, convert.atomic_write = saved.read, saved.write, saved.atomic
      persist.export, io.open, bridge.new = saved.export, saved.open, saved.new
      jove.config = saved.config
      vim.api.nvim_buf_delete(buf, { force = true })
    end,
  },
})

T["output"] = MiniTest.new_set()

T["output"]["push and clear dirty the notebook, import does not"] = function()
  local hash = cell.all(buf)[1].hash
  local event = { kind = "stream", mime = { ["text/plain"] = "result" } }
  output.import(buf, { [hash] = { event } })
  eq(vim.bo[buf].modified, false)
  output.clear(buf, hash)
  eq(vim.bo[buf].modified, true)
  vim.bo[buf].modified = false
  output.push(buf, hash, event)
  eq(vim.bo[buf].modified, true)
end

T["persist"] = MiniTest.new_set()

T["persist"]["empty disk outputs replace results and stale execution counts"] = function()
  local st = state.get(buf)
  local hash = cell.all(buf)[1].hash
  output.push(buf, hash, { kind = "stream", mime = { ["text/plain"] = "stale" } })
  st.exec = { meta = { [hash] = { count = 99 } } }
  st.json =
    { cells = { { cell_type = "code", source = "print(1)", outputs = {}, execution_count = 2 } } }
  persist.import(buf)
  eq(st.outputs, nil)
  eq(st.exec.meta, {})
  eq(persist.export(buf), false)
  eq(st.json.cells[1].execution_count, 2)
end

T["persist"]["duplicate code cells keep distinct persisted results"] = function()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %%", "print(1)", "# %%", "print(1)" })
  local cells = cell.all(buf)
  eq(cells[1].hash == cells[2].hash, false)
  for i, c in ipairs(cells) do
    output.push(buf, c.hash, { kind = "stream", mime = { ["text/plain"] = tostring(i) } })
  end
  local nb = {
    cells = {
      { cell_type = "code", source = "print(1)" },
      { cell_type = "code", source = "print(1)" },
    },
  }
  eq(persist.merge_into(nb, state.get(buf).outputs), 2)
  eq(nb.cells[1].outputs[1].text, "1")
  eq(nb.cells[2].outputs[1].text, "2")
end

T["persist"]["output export failure leaves a clean-text buffer dirty"] = function()
  local done
  convert.write = function(_, _, cb)
    done = cb
  end
  persist.export = function()
    return false, "disk full"
  end
  buffer.write(buf, state.get(buf).path)
  done('{"cells":[]}', nil)
  eq(
    vim.wait(1000, function()
      return vim.bo[buf].modified
    end),
    true
  )
end

T["reload"] = MiniTest.new_set()

T["reload"]["rejects edits and output events arriving during conversion"] = function()
  for _, mutate in ipairs({
    function()
      vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "local edit" })
    end,
    function()
      output.push(
        buf,
        cell.all(buf)[1].hash,
        { kind = "stream", mime = { ["text/plain"] = "new" } }
      )
    end,
  }) do
    local done
    convert.read = function(_, cb)
      done = cb
    end
    buffer.reload(buf)
    mutate()
    done({ "# %%", "disk replacement" })
    vim.wait(30, function()
      return false
    end)
    eq(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1], "local edit")
    eq(vim.bo[buf].modified, true)
  end
end

T["reload"]["auto reload refuses unsaved notebook state"] = function()
  jove.config.auto_reload = true
  local called = false
  convert.read = function()
    called = true
  end
  vim.bo[buf].modified = true
  buffer.changed_shell(buf, state.get(buf).path)
  vim.wait(30, function()
    return false
  end)
  eq(called, false)
end

T["atomic_write"] = MiniTest.new_set()

T["atomic_write"]["write and close failures never replace the original file"] = function()
  for _, fail in ipairs({ "write", "close" }) do
    local path = vim.fn.tempname()
    vim.fn.writefile({ "original" }, path)
    -- selene: allow(incorrect_standard_library_use)
    io.open = function()
      return {
        write = function()
          if fail == "write" then
            return nil, "disk full"
          end
          return true
        end,
        close = function()
          if fail == "close" then
            return nil, "flush failed"
          end
          return true
        end,
      }
    end
    local ok, err = convert.atomic_write(path, "replacement")
    -- selene: allow(incorrect_standard_library_use)
    io.open = saved.open
    eq(ok, false)
    eq(type(err), "string")
    eq(vim.fn.readfile(path), { "original" })
    vim.fn.delete(path)
  end
end

T["output"]["payload cap accounts for unsupported MIME and empty events"] = function()
  jove.config.output.max_bytes = 1024
  local hash = cell.all(buf)[1].hash
  output.push(
    buf,
    hash,
    { kind = "display_data", mime = { ["application/unknown"] = string.rep("x", 2048) } }
  )
  local entry = state.get(buf).outputs[hash]
  eq(entry.truncated, true)
  eq(#entry.raw, 1)
  for _ = 1, 100 do
    output.push(buf, hash, { kind = "stream", mime = {} })
  end
  eq(#entry.raw, 1)
  eq(entry.raw[1].name, "stderr")
end

T["kernel"] = MiniTest.new_set()

T["kernel"]["shutdown disposes a handle without a running kernel"] = function()
  local stopped = false
  state.get(buf).kernel = { bridge = {
    stop = function()
      stopped = true
    end,
  } }
  kernel.shutdown(buf)
  eq(state.get(buf).kernel, nil)
  eq(stopped, true)
end

T["kernel"]["failed start releases the slot for another init"] = function()
  local stopped = 0
  bridge.new = function()
    return {
      on = function()
        return function() end
      end,
      start = function(_, cb)
        cb(true)
      end,
      stop = function()
        stopped = stopped + 1
      end,
      request = function(_, method, _, cb)
        if method == "list_kernelspecs" then
          cb({ kernelspecs = { python3 = { language = "python" } } })
        elseif method == "start_kernel" then
          cb(nil, "start failed")
        end
      end,
    }
  end
  state.get(buf).json = { metadata = { kernelspec = { name = "python3" } } }
  kernel.init(buf)
  eq(state.get(buf).kernel, nil)
  kernel.init(buf)
  eq(stopped, 2)
end

T["atomic_write"]["replacement preserves symlinks and permissions"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path, link = dir .. "/target", dir .. "/link"
  vim.fn.writefile({ "original" }, path)
  assert(vim.uv.fs_chmod(path, 384)) -- 0600
  assert(vim.uv.fs_symlink(path, link))
  local ok, err = convert.atomic_write(link, "replacement")
  eq(err, nil)
  eq(ok, true)
  eq(vim.uv.fs_lstat(link).type, "link")
  eq(vim.uv.fs_stat(path).mode % 512, 384)
  eq(vim.fn.readfile(path), { "replacement" })
  vim.fn.delete(dir, "rf")
end

T["hash"] = MiniTest.new_set()

T["hash"]["nbformat source arrays match multiline buffers without stripping literal spaces"] = function()
  local source = { 'text = """hello  \n', 'world"""\n', "print(text)" }
  vim.api.nvim_buf_set_lines(
    buf,
    0,
    -1,
    false,
    { "# %%", 'text = """hello  ', 'world"""', "print(text)", "" }
  )
  eq(cell.hash_source(source), cell.all(buf)[1].hash)
  eq(
    cell.hash_source(table.concat(source):gsub("hello  ", "hello")) == cell.all(buf)[1].hash,
    false
  )
end

return T

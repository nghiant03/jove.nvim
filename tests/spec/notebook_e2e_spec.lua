local MiniTest = require("mini.test")
local state = require("jove.state")
local cell = require("jove.cell")
local execute = require("jove.execute")
local jove = require("jove")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
local fixture = vim.fs.joinpath(root, "tests", "fixtures", "smoke.ipynb")
local original_config, original_buf, directory
local buffers, bridges = {}, {}

local function await(predicate, timeout)
  MiniTest.expect.equality(vim.wait(timeout or 30000, predicate, 20), true)
end

local function require_dependencies()
  local python = require("jove.bridge").resolve_python(jove.config.bridge_python)
  local result = vim
    .system({
      python,
      "-c",
      "import jupyter_client, ipykernel; "
        .. "assert 'python3' in jupyter_client.kernelspec.KernelSpecManager().find_kernel_specs()",
    })
    :wait()
  if result.code ~= 0 or vim.fn.executable(jove.config.jupytext) ~= 1 then
    local reason =
      "notebook E2E requires jupytext, jupyter_client, ipykernel and a python3 kernelspec"
    if vim.env.JOVE_TEST_STRICT == "1" then
      error(reason .. ": " .. (result.stderr or ""))
    end
    MiniTest.skip(reason)
  end
end

local function open_notebook(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  buffers[#buffers + 1] = buf
  await(function()
    local st = state.peek(buf)
    return st ~= nil and st.json ~= nil and st.path == path and vim.bo[buf].filetype == "python"
  end)
  MiniTest.expect.equality(vim.bo[buf].buftype, "acwrite")
  MiniTest.expect.equality(vim.bo[buf].modified, false)
  return buf
end

local function has_result(buf, hash)
  local st = state.peek(buf)
  local entry = st and st.outputs and st.outputs[hash]
  for _, output in ipairs(entry and entry.raw or {}) do
    if output["kind"] == "execute_result" and (output["mime"] or {})["text/plain"] == "42" then
      return true
    end
  end
  return false
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      original_config = vim.deepcopy(jove.config)
      original_buf = vim.api.nvim_get_current_buf()
      buffers, bridges = {}, {}
      directory = nil
      require_dependencies()
      jove.config.auto_kernel = false
      jove.config.auto_import_outputs = true
      jove.config.auto_export_outputs = true
      jove.config.persist_exec_counts = true
      jove.config.lsp.auto_attach = false
      jove.config.output.images = false
      directory = vim.fn.tempname()
      vim.fn.mkdir(directory, "p")
    end,
    post_case = function()
      for _, buf in ipairs(buffers) do
        local st = state.peek(buf)
        if st and st.kernel then
          if not vim.tbl_contains(bridges, st.kernel.bridge) then
            bridges[#bridges + 1] = st.kernel.bridge
          end
          st.kernel._last_name = nil
          st.kernel = nil
        end
      end
      for _, bridge in ipairs(bridges) do
        bridge:stop()
      end
      for _, buf in ipairs(buffers) do
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
      local stopped = vim.wait(10000, function()
        for _, bridge in ipairs(bridges) do
          if bridge:is_alive() then
            return false
          end
        end
        return true
      end, 20)
      if original_buf and vim.api.nvim_buf_is_valid(original_buf) then
        vim.api.nvim_set_current_buf(original_buf)
      end
      jove.config = original_config
      if directory then
        vim.fn.delete(directory, "rf")
      end
      MiniTest.expect.equality(stopped, true)
    end,
  },
})

T["commands open execute save and reopen a real notebook"] = function()
  local path = vim.fs.joinpath(directory, "notebook.ipynb")
  MiniTest.expect.equality(vim.uv.fs_copyfile(fixture, path), true)
  local buf = open_notebook(path)
  local cells = cell.all(buf)
  MiniTest.expect.equality(#state.get(buf).json.cells, 3)
  MiniTest.expect.equality(cells[#cells - 2].kind, "markdown")
  local target = cells[#cells]
  vim.api.nvim_buf_set_lines(buf, target.start_lnum, target.end_lnum, false, { "21 * 2" })
  cells = cell.all(buf)
  target = cells[#cells]
  local hash = target.hash
  vim.api.nvim_win_set_cursor(0, { target.start_lnum + 1, 0 })

  vim.cmd("Jove init-kernel")
  local bridge = state.get(buf).kernel.bridge
  bridges[#bridges + 1] = bridge
  await(function()
    local st = state.peek(buf)
    return st and st.kernel and st.kernel.status == "idle"
  end, 60000)
  vim.cmd("Jove run-cell")
  await(function()
    return execute.status(buf, hash) == "ok"
  end, 60000)
  await(function()
    return has_result(buf, hash)
  end, 15000)
  local count = execute.meta(buf, hash).count
  MiniTest.expect.equality(type(count), "number")
  MiniTest.expect.equality(count > 0, true)

  vim.cmd("write")
  await(function()
    return state.get(buf).last_write ~= nil and not vim.bo[buf].modified
  end)
  local saved = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  MiniTest.expect.equality(#saved.cells, 3)
  MiniTest.expect.equality(saved.metadata.kernelspec.name, "python3")
  MiniTest.expect.equality(table.concat(saved.cells[3].source), "21 * 2")
  MiniTest.expect.equality(saved.cells[3].execution_count, count)
  MiniTest.expect.equality(saved.cells[3].outputs[1].output_type, "execute_result")
  MiniTest.expect.equality(saved.cells[3].outputs[1].data["text/plain"], "42")

  vim.cmd("Jove shutdown-kernel")
  await(function()
    return not bridge:is_alive()
  end, 10000)
  vim.cmd("bwipeout")
  MiniTest.expect.equality(state.peek(buf), nil)
  local reopened = open_notebook(path)
  MiniTest.expect.equality(reopened ~= buf, true)
  local reopened_cells = cell.all(reopened)
  MiniTest.expect.equality(reopened_cells[#reopened_cells].hash, hash)
  await(function()
    return has_result(reopened, hash)
  end)
  MiniTest.expect.equality(state.get(reopened).outputs[hash].from_disk, true)
  MiniTest.expect.equality(state.get(reopened).json.cells[3].execution_count, count)
  MiniTest.expect.equality(state.get(reopened).kernel, nil)
end

return T

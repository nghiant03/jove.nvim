local MiniTest = require("mini.test")
local convert = require("jove.convert")

local T = MiniTest.new_set()

---@param cond any
local function expect_truthy(cond)
  MiniTest.expect.equality(cond == true, true)
end

local FIXTURE = vim.fs.joinpath(vim.fn.getcwd(), "tests", "fixtures", "smoke.ipynb")
local JS_FIXTURE = vim.fs.joinpath(vim.fn.getcwd(), "tests", "fixtures", "smoke_js.ipynb")

---@return string path
local function tmp_copy_fixture()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.joinpath(dir, "smoke.ipynb")
  local ok = vim.uv.fs_copyfile(FIXTURE, path)
  expect_truthy(ok)
  return path
end

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

---@param fn fun(cb: fun(result: any, err: string?))
---@return any, string?
local function async_call(fn)
  local done, result, err = false, nil, nil
  fn(function(res, e)
    done, result, err = true, res, e
  end)
  expect_truthy(vim.wait(30000, function()
    return done
  end, 5))
  return result, err
end

T["read"] = MiniTest.new_set()

T["read"]["returns py:percent lines from a real notebook"] = function()
  local lines, err = async_call(function(cb)
    return convert.read(FIXTURE, cb)
  end)
  MiniTest.expect.equality(err, nil)
  expect_truthy(type(lines) == "table" and #lines > 0)
  MiniTest.expect.equality(lines[1], "# ---")
  local has_cell_marker = false
  for _, l in ipairs(lines) do
    if l:match("^# %%") then
      has_cell_marker = true
      break
    end
  end
  expect_truthy(has_cell_marker)
end

T["read"]["fails gracefully on a non-notebook file"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.joinpath(dir, "garbage.ipynb")
  local fd = assert(io.open(path, "wb"))
  fd:write("this is not a notebook")
  fd:close()

  local lines, err = async_call(function(cb)
    return convert.read(path, cb)
  end)
  expect_truthy(lines == nil)
  expect_truthy(type(err) == "string" and #err > 0)
end

T["read"]["js:percent lines from a javascript notebook"] = function()
  local lines, err = async_call(function(cb)
    return convert.read(JS_FIXTURE, cb, { fmt = "js" })
  end)
  MiniTest.expect.equality(err, nil)
  expect_truthy(type(lines) == "table" and #lines > 0)
  MiniTest.expect.equality(lines[1], "// ---")
  local has_cell_marker = false
  for _, l in ipairs(lines) do
    if l:match("^// %%") then
      has_cell_marker = true
      break
    end
  end
  expect_truthy(has_cell_marker)
end

T["write"] = MiniTest.new_set()

T["write"]["round-trips without changing the py:percent text"] = function()
  local path = tmp_copy_fixture()
  local lines = async_call(function(cb)
    return convert.read(path, cb)
  end)
  expect_truthy(type(lines) == "table")

  local bytes, werr = async_call(function(cb)
    return convert.write(path, lines, cb)
  end)
  MiniTest.expect.equality(werr, nil)
  expect_truthy(type(bytes) == "string" and #bytes > 0)

  local reread = async_call(function(cb)
    return convert.read(path, cb)
  end)
  MiniTest.expect.equality(reread, lines)
end

T["write"]["jupytext writes the file, Lua only reads it back"] = function()
  local path = tmp_copy_fixture()
  local lines = async_call(function(cb)
    return convert.read(path, cb)
  end)
  expect_truthy(type(lines) == "table")

  local bytes, werr = async_call(function(cb)
    return convert.write(path, lines, cb)
  end)
  MiniTest.expect.equality(werr, nil)

  local disk = read_disk(path)
  expect_truthy(disk ~= nil)
  MiniTest.expect.equality(bytes, disk)

  local ok, nb = pcall(vim.json.decode, disk)
  expect_truthy(ok)
  MiniTest.expect.equality(#nb.cells, 3)
end

T["write"]["converts via stdout and writes atomically"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.joinpath(dir, "fresh.ipynb")

  local lines = async_call(function(cb)
    return convert.read(FIXTURE, cb)
  end)
  expect_truthy(type(lines) == "table")

  local bytes, werr = async_call(function(cb)
    return convert.write(path, lines, cb)
  end)
  MiniTest.expect.equality(werr, nil)
  expect_truthy(type(bytes) == "string" and #bytes > 0)

  local disk = read_disk(path)
  expect_truthy(disk ~= nil)
  MiniTest.expect.equality(bytes, disk)
  local ok, nb = pcall(vim.json.decode, disk)
  expect_truthy(ok)
  expect_truthy(#nb.cells > 0)

  local entries = vim.fn.readdir(dir)
  MiniTest.expect.equality(#entries, 1)
  MiniTest.expect.equality(entries[1], "fresh.ipynb")
end

T["write"]["js:percent round-trips a javascript notebook"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.joinpath(dir, "smoke_js.ipynb")
  expect_truthy(vim.uv.fs_copyfile(JS_FIXTURE, path))

  local lines = async_call(function(cb)
    return convert.read(path, cb, { fmt = "js" })
  end)
  expect_truthy(type(lines) == "table")

  local bytes, werr = async_call(function(cb)
    return convert.write(path, lines, cb, { fmt = "js" })
  end)
  MiniTest.expect.equality(werr, nil)
  expect_truthy(type(bytes) == "string" and #bytes > 0)

  local reread = async_call(function(cb)
    return convert.read(path, cb, { fmt = "js" })
  end)
  MiniTest.expect.equality(reread, lines)

  local ok, nb = pcall(vim.json.decode, bytes)
  expect_truthy(ok)
  MiniTest.expect.equality(nb.metadata.kernelspec.language, "javascript")
end

T["version"] = MiniTest.new_set()

T["version"]["returns non-nil"] = function()
  expect_truthy(convert.version() ~= nil)
end

return T

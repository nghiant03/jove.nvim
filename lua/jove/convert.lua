-- Asynchronous jupytext conversion with atomic writes for new notebooks.
-- version() is synchronous for health checks.
local M = {}

local function jupytext_bin()
  local cfg = require("jove").config
  return cfg.jupytext or "jupytext"
end

---Read a file fully via libuv without blocking the editor.
---@param path string
---@param cb fun(bytes: string?, err: string?)
local function read_file(path, cb)
  vim.uv.fs_open(path, "r", 438, function(err, fd)
    if err or not fd then
      return cb(nil, (err and tostring(err)) or ("cannot open " .. path))
    end
    vim.uv.fs_fstat(fd, function(ferr, stat)
      if ferr or not stat then
        vim.uv.fs_close(fd, function() end)
        return cb(nil, (ferr and tostring(ferr)) or ("cannot stat " .. path))
      end
      vim.uv.fs_read(fd, stat.size, 0, function(rerr, data)
        vim.uv.fs_close(fd, function() end)
        if rerr then
          return cb(nil, tostring(rerr))
        end
        cb(data, nil)
      end)
    end)
  end)
end

---Write bytes atomically: temp file in the same dir, then rename over `path`.
---
---Every step is checked: a short write or failed close (e.g. full disk
---surfacing at flush time) removes the temp file and reports an error
---instead of renaming a partial file over a good one. An existing symlinked
---destination is written through (the rename targets the resolved path, so
---the symlink itself survives), and an existing destination's permission
---bits are copied onto the temp file before the rename.
---@param path string
---@param bytes string
---@return boolean, string?  -- ok, error
function M.atomic_write(path, bytes)
  local target = vim.uv.fs_realpath(path) or path
  local temp_fd, tmp = vim.uv.fs_mkstemp(target .. ".jove-XXXXXX")
  if not temp_fd then
    return false, tostring(tmp)
  end
  local closed, close_err = vim.uv.fs_close(temp_fd)
  if not closed then
    os.remove(tmp)
    return false, tostring(close_err)
  end
  local fd, ferr = io.open(tmp, "wb")
  if not fd then
    os.remove(tmp)
    return false, ferr or ("cannot create " .. tmp)
  end
  local wok, werr = fd:write(bytes)
  if not wok then
    fd:close()
    os.remove(tmp)
    return false, tostring(werr or ("cannot write " .. tmp))
  end
  local cok, cerr = fd:close()
  if not cok then
    os.remove(tmp)
    return false, tostring(cerr or ("cannot close " .. tmp))
  end
  -- A permission-copy failure must not silently broaden file access.
  local stat = vim.uv.fs_stat(target)
  if stat then
    local mok, merr = vim.uv.fs_chmod(tmp, stat.mode % 4096)
    if not mok then
      os.remove(tmp)
      return false, tostring(merr)
    end
  end
  local ok, rerr = os.rename(tmp, target)
  if not ok then
    os.remove(tmp)
    return false, rerr or ("cannot rename " .. tmp)
  end
  return true
end

---Run jupytext with stdin and invoke `cb(stdout, stderr, code)` on completion.
---@param args string[]
---@param stdin string
---@param cb fun(stdout: string?, stderr: string?, code: integer)
local function run(args, stdin, cb)
  local cmd = vim.list_extend({ jupytext_bin() }, args)
  vim.system(cmd, { stdin = stdin, text = true }, function(res)
    cb(res.stdout, res.stderr, res.code)
  end)
end

---Split jupytext stdout into buffer lines (single trailing newline trimmed so
---vim.split doesn't add a phantom blank line).
---@param out string
---@return string[]
local function split_lines(out)
  if out:sub(-1) == "\n" then
    out = out:sub(1, -2)
  end
  return vim.split(out, "\n", { plain = true })
end

---Read .ipynb at `path` and return py:percent lines, asynchronously.
---Callbacks may run in a fast-event context; schedule buffer or window API calls.
---@param path string
---@param cb fun(lines: string[]?, err: string?)
function M.read(path, cb)
  read_file(path, function(data, err)
    if not data then
      return cb(nil, err)
    end
    run(
      { "--from", "ipynb", "--to", "py:percent", "--output", "-" },
      data,
      function(stdout, stderr, code)
        if code ~= 0 then
          return cb(nil, ((stderr ~= "" and stderr) or "jupytext read failed"))
        end
        cb(split_lines(stdout or ""), nil)
      end
    )
  end)
end

---Convert py:percent buffer text back to ipynb JSON at `path`, asynchronously.
---When `path` already exists, jupytext --update --output <path> merges and
---writes the file itself; we only read the bytes back. For new files, jupytext prints
---the notebook to stdout and Lua writes the bytes atomically (temp file +
---rename). The callback receives the on-disk bytes on success.
---@param path string
---@param lines string[]
---@param cb fun(bytes: string?, err: string?)
function M.write(path, lines, cb)
  local stdin = table.concat(lines, "\n") .. "\n"

  if vim.uv.fs_stat(path) == nil then
    run(
      { "--from", "py:percent", "--to", "ipynb", "--output", "-" },
      stdin,
      function(stdout, stderr, code)
        if code ~= 0 then
          return cb(nil, ((stderr ~= "" and stderr) or "jupytext write failed"))
        end
        local bytes = stdout or ""
        local ok, werr = M.atomic_write(path, bytes)
        if not ok then
          return cb(nil, werr)
        end
        cb(bytes, nil)
      end
    )
    return
  end

  -- --update only triggers the input/output merge when the destination is an
  -- existing file on disk; jupytext then writes `path` itself and we just
  -- read the fresh bytes back for cache refresh.
  run(
    { "--from", "py:percent", "--to", "ipynb", "--update", "--output", path },
    stdin,
    function(_, stderr, code)
      if code ~= 0 then
        return cb(nil, ((stderr ~= "" and stderr) or "jupytext write failed"))
      end
      read_file(path, function(data, rerr)
        if not data then
          return cb(nil, rerr)
        end
        cb(data, nil)
      end)
    end
  )
end

---Return jupytext --version string, or nil.
---Synchronous by design: only used by :checkhealth. Timeout-bounded so a
---wedged jupytext binary cannot hang the health check.
---@return string?
function M.version()
  local ok, res = pcall(function()
    return vim.system({ jupytext_bin(), "--version" }, { text = true, timeout = 5000 }):wait()
  end)
  if not ok or res.code ~= 0 then
    return nil
  end
  return vim.trim(res.stdout or "")
end

return M

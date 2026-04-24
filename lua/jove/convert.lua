-- convert.lua: jupytext CLI wrappers (stdio only, no temp files).
local M = {}

local function jupytext_bin()
  local cfg = require("jove").config
  return cfg.jupytext or "jupytext"
end

---Run jupytext with stdin and capture stdout/stderr.
---@param args string[]
---@param stdin string
---@return vim.SystemCompleted
local function run(args, stdin)
  local cmd = { jupytext_bin() }
  vim.list_extend(cmd, args)
  return vim.system(cmd, { stdin = stdin, text = true }):wait()
end

---Read .ipynb at `path` and return py:percent lines.
---@param path string
---@return string[]?, string?
function M.read(path)
  local fd, ferr = io.open(path, "rb")
  if not fd then
    return nil, ferr or ("cannot open " .. path)
  end
  local data = fd:read("*a")
  fd:close()

  local res = run(
    { "--from", "ipynb", "--to", "py:percent", "--output", "-" },
    data
  )
  if res.code ~= 0 then
    return nil, (res.stderr ~= "" and res.stderr) or "jupytext read failed"
  end

  local out = res.stdout or ""
  -- Trim a single trailing newline so vim.split doesn't add a phantom blank line.
  if out:sub(-1) == "\n" then
    out = out:sub(1, -2)
  end
  return vim.split(out, "\n", { plain = true }), nil
end

---Convert py:percent buffer text back to ipynb JSON, preserving metadata via --update.
---@param path string  existing .ipynb path (used as --update target)
---@param lines string[]
---@return string?, string?  -- ipynb JSON bytes, error
function M.write(path, lines)
  local stdin = table.concat(lines, "\n") .. "\n"

  local args
  if vim.uv.fs_stat(path) then
    -- --update merges new code into existing JSON, preserving outputs/ids/metadata.
    args = {
      "--from",
      "py:percent",
      "--to",
      "ipynb",
      "--update",
      path,
      "--output",
      "-",
    }
  else
    args = { "--from", "py:percent", "--to", "ipynb", "--output", "-" }
  end

  local res = run(args, stdin)
  if res.code ~= 0 then
    return nil, (res.stderr ~= "" and res.stderr) or "jupytext write failed"
  end
  return res.stdout, nil
end

---Return jupytext --version string, or nil.
---@return string?
function M.version()
  local ok, res = pcall(function()
    return vim.system({ jupytext_bin(), "--version" }, { text = true }):wait()
  end)
  if not ok or res.code ~= 0 then
    return nil
  end
  return vim.trim(res.stdout or "")
end

return M

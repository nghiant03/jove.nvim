-- Dependency and configuration checks.
local M = {}

local h = vim.health

---@return string
local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

---@param code integer?  exit code (nil on timeout/kill)
---@param stderr string
---@return "ok"|"missing" status
---@return string detail  human-readable, actionable on failure
function M.check_import_result(code, stderr)
  if code == 0 then
    return "ok", "jupyter_client + ipykernel importable"
  end
  local detail = vim.trim(stderr or "")
  if detail == "" then
    detail = "import failed"
  end
  return "missing", detail
end

---@param cmd string[]
---@param timeout integer
---@param env table?  Extra environment variables merged into the current
---    environment (explicitly merged: the child must keep $PATH etc.).
---@return {code: integer?, stdout: string, stderr: string}
local function run(cmd, timeout, env)
  local opts = { timeout = timeout, text = true }
  if env then
    opts.env = vim.tbl_extend("force", vim.fn.environ(), env)
  end
  local ok, res = pcall(vim.system, cmd, opts)
  if not ok or not res then
    return { code = -1, stdout = "", stderr = "cannot spawn " .. tostring(cmd[1]) }
  end
  local done = res:wait()
  return {
    code = done.code,
    stdout = done.stdout or "",
    stderr = done.stderr or "",
  }
end

function M.check()
  h.start("jove")

  if vim.fn.has("nvim-0.11") ~= 1 then
    h.error(("Neovim >= 0.11 required (found %s)."):format(tostring(vim.version())))
  else
    h.ok("Neovim " .. tostring(vim.version()))
  end

  local ver = require("jove.convert").version()
  if ver then
    h.ok("jupytext: " .. ver)
  else
    h.error("`jupytext` not found on $PATH (pip install jupytext)")
  end

  local bridge = require("jove.bridge")
  local cfg = require("jove").config
  local python = bridge.resolve_python(cfg.bridge_python)

  local vres = run({ python, "-c", "import sys; print(sys.version.split()[0])" }, 5000)
  if vres.code == 0 and vim.trim(vres.stdout) ~= "" then
    h.ok(("bridge python: %s (v%s)"):format(python, vim.trim(vres.stdout)))
  else
    h.warn(
      ("bridge python %q not runnable; set `jove.bridge_python` to a working interpreter"):format(
        python
      )
    )
  end

  local ires = run({ python, "-c", "import jupyter_client, ipykernel" }, 10000)
  local status, detail = M.check_import_result(ires.code, ires.stderr)
  if status == "ok" then
    h.ok(detail .. " (via " .. python .. ")")
  else
    h.error(
      (
        "jupyter_client/ipykernel not importable via %s (%s) — run: %s -m pip install "
        .. "jupyter_client ipykernel. If your Python lives in a virtualenv or conda env, "
        .. "point `jove.bridge_python` at its interpreter."
      ):format(python, detail, python)
    )
  end

  local pythonpath = vim.fs.joinpath(plugin_root(), "python")
  local existing = vim.fn.environ().PYTHONPATH
  if existing and existing ~= "" then
    local sep = vim.uv.os_uname().sysname:find("Windows", 1, true) and ";" or ":"
    pythonpath = pythonpath .. sep .. existing
  end
  local sres = run({ python, "-c", "import jove_bridge" }, 10000, { PYTHONPATH = pythonpath })
  if sres.code == 0 then
    h.ok("bridge sidecar importable (python/jove_bridge)")
  else
    h.error(
      (
        "bridge sidecar `jove_bridge` not importable with PYTHONPATH=%s — the plugin's "
        .. "python/ package must be intact"
      ):format(pythonpath)
    )
  end

  local ok_snacks, snacks = pcall(require, "snacks")
  if ok_snacks and type(snacks) == "table" and snacks.image ~= nil then
    h.info("snacks.image detected (optional; enables inline image outputs)")
  else
    h.info(
      "snacks.image not detected (optional; enables inline image outputs — install folke/snacks.nvim)"
    )
  end

  if vim.g.loaded_jupytext == 1 or package.loaded["jupytext"] then
    h.error("jupytext.nvim is loaded; jove.nvim refuses to attach handlers. Disable one.")
  else
    h.ok("no conflicting .ipynb plugin detected")
  end

  if vim.g.loaded_molten == 1 or vim.fn.exists(":MoltenInit") == 2 then
    h.warn("molten-nvim is loaded; jove no longer uses it — remove it (see README migration)")
  end
end

return M

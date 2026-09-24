-- Language registry: maps notebook kernelspec languages to the buffer
-- conventions jove needs (filetype, jupytext percent-format stem, comment
-- leader) plus the known LSP server names used for docs and health hints.

local M = {}

---@class jove.Lang
---@field id string          Kernelspec language id (lowercased), e.g. "python".
---@field filetype string    Filetype set on the notebook buffer.
---@field fmt string         Jupytext percent-format stem, e.g. "py" -> "py:percent".
---@field comment string     Comment leader of the percent format, e.g. "#" or "//".
---@field servers string[]   Known LSP server names for this language (health/docs hints).

---@type table<string, jove.Lang>
local registry = {
  python = {
    id = "python",
    filetype = "python",
    fmt = "py",
    comment = "#",
    servers = { "pyright", "basedpyright", "ruff" },
  },
  julia = {
    id = "julia",
    filetype = "julia",
    fmt = "jl",
    comment = "#",
    servers = { "julials" },
  },
  r = {
    id = "r",
    filetype = "r",
    fmt = "R",
    comment = "#",
    servers = { "r_language_server" },
  },
  javascript = {
    id = "javascript",
    filetype = "javascript",
    fmt = "js",
    comment = "//",
    servers = { "ts_ls" },
  },
  typescript = {
    id = "typescript",
    filetype = "typescript",
    fmt = "ts",
    comment = "//",
    servers = { "ts_ls" },
  },
}

---@type jove.Lang
M.default = registry.python

local warned_unknown = {}

function M._reset()
  warned_unknown = {}
end

---Register (or override) a language. All fields except id are optional and
---fall back to the python defaults for the missing pieces.
---@param id string          Kernelspec language id, e.g. "scala".
---@param spec {filetype: string?, fmt: string?, comment: string?, servers: string[]?}
function M.register(id, spec)
  vim.validate("id", id, "string")
  vim.validate("spec", spec, "table")
  local key = id:lower()
  ---@type jove.Lang
  registry[key] = {
    id = key,
    filetype = spec.filetype or key,
    fmt = spec.fmt or "py",
    comment = spec.comment or "#",
    servers = spec.servers or {},
  }
end

---Resolve a kernelspec language id to its spec; unknown ids fall back to
---python with a one-time warning.
---@param id string?
---@return jove.Lang
function M.get(id)
  if not id then
    return M.default
  end
  local key = tostring(id):lower()
  local spec = registry[key]
  if spec then
    return spec
  end
  if not warned_unknown[key] then
    warned_unknown[key] = true
    vim.notify(
      (
        "[jove] unknown notebook language %q; falling back to python "
        .. "(register it with require('jove.lang').register)"
      ):format(key),
      vim.log.levels.WARN
    )
  end
  return M.default
end

---Resolve the language of a parsed .ipynb JSON document.
---@param json table?
---@return jove.Lang
function M.for_notebook(json)
  local l = json
    and json.metadata
    and json.metadata.kernelspec
    and json.metadata.kernelspec.language
  return M.get(l)
end

---Resolve the language of a jove buffer (set on read; python before that).
---@param buf integer
---@return jove.Lang
function M.for_buffer(buf)
  local entry = require("jove.state").peek(buf)
  return M.get(entry and entry.lang or nil)
end

---@return string[]
function M.ids()
  local ids = {}
  for id in pairs(registry) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  return ids
end

return M

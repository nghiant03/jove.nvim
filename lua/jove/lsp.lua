-- LSP integration for notebook buffers.
--
-- Jove buffers carry the language's filetype, so servers enabled via
-- vim.lsp.enable()/nvim-lspconfig attach on their own (root detection uses
-- the .ipynb's directory). This module adds the opt-in `lsp.auto_attach`
-- path: start the servers the user declared in `lsp.servers[lang]`, reusing
-- their vim.lsp.config entries (jove never invents cmd/root_dir).

local lang = require("jove.lang")
local state = require("jove.state")

local M = {}

-- Test seam (see AGENTS.md): specs inject fakes here; do not use elsewhere.
local impl = {
  get_clients = vim.lsp.get_clients,
  start = vim.lsp.start,
  config = function(name)
    local ok, conf = pcall(function()
      return vim.lsp.config[name]
    end)
    if ok and type(conf) == "table" and conf.cmd ~= nil then
      return conf
    end
    return nil
  end,
}

M._impl = impl

local warned_missing = {}

function M._reset()
  warned_missing = {}
end

---Attach one configured server to the buffer unless a client with the same
---name is already attached.
---@param buf integer
---@param name string
function M._attach_one(buf, name)
  if #impl.get_clients({ bufnr = buf, name = name }) > 0 then
    return
  end
  local conf = impl.config(name)
  if conf == nil then
    if not warned_missing[name] then
      warned_missing[name] = true
      vim.notify(
        (
          "[jove] lsp.servers lists %q but no vim.lsp.config entry exists; "
          .. "install nvim-lspconfig or define vim.lsp.config[%q] yourself"
        ):format(name, name),
        vim.log.levels.WARN
      )
    end
    return
  end
  local ok, err = pcall(impl.start, conf, { bufnr = buf })
  if not ok then
    vim.notify(
      ("[jove] failed to start LSP server %q: %s"):format(name, tostring(err)),
      vim.log.levels.WARN
    )
  end
end

---Attach the servers configured for the buffer's language. No-op unless
---`lsp.auto_attach` is set; called after the notebook filetype is resolved.
---@param buf integer
function M.attach(buf)
  local cfg = require("jove").config.lsp
  if not (cfg and cfg.auto_attach) then
    return
  end
  local entry = state.peek(buf)
  local spec = lang.get(entry and entry.lang or nil)
  local names = type(cfg.servers) == "table" and cfg.servers[spec.id] or nil
  if type(names) ~= "table" then
    return
  end
  for _, name in ipairs(names) do
    if type(name) == "string" then
      M._attach_one(buf, name)
    end
  end
end

return M

-- health.lua: :checkhealth jove
local M = {}

local h = vim.health

function M.check()
  h.start("jove")

  if vim.fn.has("nvim-0.10") ~= 1 then
    h.error("Neovim >= 0.10 required (vim.system with stdio).")
  else
    h.ok("Neovim " .. tostring(vim.version()))
  end

  local convert = require("jove.convert")
  local ver = convert.version()
  if ver then
    h.ok("jupytext: " .. ver)
  else
    h.error("`jupytext` not found on $PATH (pip install jupytext)")
  end

  if vim.fn.exists(":MoltenInit") == 2 then
    h.ok("molten-nvim detected")
  else
    h.warn("molten-nvim not loaded; cell execution and outputs will be unavailable")
  end

  if package.loaded["copilot"] or vim.fn.exists(":Copilot") == 2 then
    h.ok("copilot detected (will attach as native python)")
  else
    h.info("copilot not detected (optional)")
  end

  if vim.g.loaded_jupytext == 1 or package.loaded["jupytext"] then
    h.error("jupytext.nvim is loaded; jove.nvim refuses to attach handlers. Disable one.")
  else
    h.ok("no conflicting .ipynb plugin detected")
  end
end

return M

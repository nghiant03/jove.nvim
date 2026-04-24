-- buffer.lua: BufReadCmd / BufWriteCmd handlers.
local convert = require("ipynb.convert")
local outputs = require("ipynb.outputs")
local kernel = require("ipynb.kernel")

local M = {}

---Detect filetype from kernelspec.language in the .ipynb JSON.
---@param json table?
---@return string
local function filetype_for(json)
  local lang = json
    and json.metadata
    and json.metadata.kernelspec
    and json.metadata.kernelspec.language
  if not lang then
    return "python"
  end
  lang = tostring(lang):lower()
  local map = { python = "python", julia = "julia", r = "r", javascript = "javascript" }
  return map[lang] or "python"
end

---Parse the raw .ipynb JSON from disk; returns nil on failure.
---@param path string
---@return table?
local function read_json(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local data = fd:read("*a")
  fd:close()
  local ok, json = pcall(vim.json.decode, data)
  if not ok then
    return nil
  end
  return json
end

---BufReadCmd handler.
---@param buf integer
---@param path string
function M.read(buf, path)
  local cfg = require("ipynb").config

  if not vim.uv.fs_stat(path) then
    -- New file: empty py:percent buffer, defer JSON creation to first write.
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].filetype = "python"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# %%", "" })
    vim.bo[buf].modified = false
    return
  end

  local lines, err = convert.read(path)
  if not lines then
    vim.notify("[ipynb] read failed: " .. (err or "?"), vim.log.levels.ERROR)
    return
  end

  local json = read_json(path)
  local ft = filetype_for(json)

  vim.bo[buf].buftype = "acwrite"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  vim.bo[buf].modified = false

  -- Stash the parsed JSON for outputs.lua to reuse without re-reading disk.
  vim.b[buf].ipynb_json = json
  vim.b[buf].ipynb_path = path

  -- Schedule kernel + output import after BufRead* autocmds settle.
  if cfg.auto_kernel then
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then
        kernel.init(buf)
        if cfg.auto_import_outputs then
          outputs.import(buf)
        end
      end
    end)
  end
end

---BufWriteCmd handler.
---@param buf integer
---@param path string
function M.write(buf, path)
  local cfg = require("ipynb").config
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local bytes, err = convert.write(path, lines)
  if not bytes then
    vim.notify("[ipynb] write failed: " .. (err or "?"), vim.log.levels.ERROR)
    return
  end

  local fd, ferr = io.open(path, "wb")
  if not fd then
    vim.notify("[ipynb] cannot write " .. path .. ": " .. (ferr or "?"), vim.log.levels.ERROR)
    return
  end
  fd:write(bytes)
  fd:close()

  vim.bo[buf].modified = false

  -- Refresh cached JSON for downstream consumers.
  local json = vim.json.decode(bytes)
  vim.b[buf].ipynb_json = json

  vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })

  if cfg.auto_export_outputs then
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then
        outputs.export(buf)
      end
    end)
  end
end

return M

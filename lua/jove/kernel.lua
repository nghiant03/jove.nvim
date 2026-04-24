-- kernel.lua: auto-init molten from notebook metadata or active venv.
local M = {}

local function molten_loaded()
  return vim.fn.exists(":MoltenInit") == 2
end

---Return the kernelspec.name from the buffer's cached JSON, if any.
---@param buf integer
---@return string?
local function kernelspec_name(buf)
  local json = vim.b[buf].jove_json
  if type(json) ~= "table" then
    return nil
  end
  local ks = json.metadata and json.metadata.kernelspec
  if ks and type(ks.name) == "string" and ks.name ~= "" then
    return ks.name
  end
  return nil
end

---Best-effort guess of the active python environment name.
---@return string?
local function active_env_name()
  local conda = vim.env.CONDA_DEFAULT_ENV
  if conda and conda ~= "" then
    return conda
  end
  local venv = vim.env.VIRTUAL_ENV
  if venv and venv ~= "" then
    return vim.fs.basename(venv)
  end
  return nil
end

---List molten-known kernels, or {} if molten missing.
---@return string[]
local function available_kernels()
  if not molten_loaded() then
    return {}
  end
  local ok, list = pcall(vim.fn.MoltenAvailableKernels)
  if not ok or type(list) ~= "table" then
    return {}
  end
  return list
end

---Has molten already been initialized for this buffer?
---@param buf integer
---@return boolean
local function already_initialized(buf)
  if not molten_loaded() then
    return false
  end
  local ok, kernels = pcall(vim.fn.MoltenRunningKernels, true)
  if not ok or type(kernels) ~= "table" then
    return false
  end
  return #kernels > 0 and vim.api.nvim_get_current_buf() == buf
end

---Initialize molten for the given buffer using the best-matching kernel.
---@param buf integer
function M.init(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  if not molten_loaded() then
    return
  end
  if already_initialized(buf) then
    return
  end

  local available = available_kernels()
  if #available == 0 then
    return
  end

  local function has(name)
    for _, k in ipairs(available) do
      if k == name then
        return true
      end
    end
    return false
  end

  local candidates = {}
  local from_meta = kernelspec_name(buf)
  if from_meta then
    table.insert(candidates, from_meta)
  end
  local from_env = active_env_name()
  if from_env then
    table.insert(candidates, from_env)
  end
  -- Final fallback: a "python3" kernel if molten knows it.
  table.insert(candidates, "python3")

  for _, name in ipairs(candidates) do
    if has(name) then
      local ok, err = pcall(vim.cmd, ("MoltenInit %s"):format(name))
      if ok then
        return
      else
        vim.notify(
          ("[jove] MoltenInit %s failed: %s"):format(name, tostring(err)),
          vim.log.levels.WARN
        )
      end
    end
  end
end

return M

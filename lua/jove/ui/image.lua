-- Optional snacks.image integration for inline image outputs.

local M = {}

local MIME_EXT = { ["image/png"] = "png", ["image/jpeg"] = "jpg" }

---@type table<integer, table<string, table<string, table>>>
local placed = {}

local notified = false
local group = nil

local function ensure_wipeout_cleanup()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup("jove_image", { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    pattern = "*",
    callback = function(ev)
      M.clear(ev.buf)
    end,
  })
end

---@return table? snacks
local function load()
  pcall(require, "snacks")
  local ok, snacks = pcall(require, "snacks.image")
  if ok and type(snacks) == "table" then
    return snacks
  end
  return nil
end

---@return boolean
function M.available()
  return load() ~= nil
end

---@return boolean
function M.enabled()
  local cfg = require("jove").config
  if not (cfg.output and cfg.output.images) then
    return false
  end
  return M.available()
end

function M.notify_missing()
  if notified then
    return
  end
  notified = true
  vim.notify("snacks.image enables inline image outputs", vim.log.levels.INFO)
end

---@param chunk table  { mime = <str>, data = <base64 str> }
---@return string? path
function M.decode(chunk)
  if type(chunk) ~= "table" or type(chunk.data) ~= "string" then
    return nil
  end
  if chunk.image_path and vim.fn.filereadable(chunk.image_path) == 1 then
    return chunk.image_path
  end
  local ok, decoded = pcall(vim.base64.decode, chunk.data)
  if not ok or type(decoded) ~= "string" then
    return nil
  end
  local dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "jove-images")
  vim.fn.mkdir(dir, "p")
  local path =
    vim.fs.joinpath(dir, ("%s.%s"):format(vim.fn.sha256(chunk.data), MIME_EXT[chunk.mime] or "bin"))
  local fd = vim.uv.fs_open(path, "w", 384) -- 0600
  if not fd then
    return nil
  end
  local written = vim.uv.fs_write(fd, decoded, 0)
  vim.uv.fs_close(fd)
  if written ~= #decoded then
    pcall(vim.uv.fs_unlink, path)
    return nil
  end
  chunk.image_path = path
  return path
end

---@param buf integer
---@param row integer  1-based buffer line the image anchors at
---@param path string
---@param col integer?  0-based column the grid is padded to (blank anchors only)
---@return table? placement  snacks placement handle on success
local function place(buf, row, path, col)
  local snacks = load()
  if not snacks then
    return nil
  end
  if type(snacks.supports) == "function" and not snacks.supports(path) then
    return nil
  end
  local placement = snacks.placement
  if type(placement) ~= "table" or type(placement.new) ~= "function" then
    return nil
  end
  local cfg = require("jove").config
  local opts = { pos = { row, col or 0 }, inline = true }
  if cfg.output and type(cfg.output.image_max_width) == "number" then
    opts.max_width = cfg.output.image_max_width
  end
  if cfg.output and type(cfg.output.image_max_height) == "number" then
    opts.max_height = cfg.output.image_max_height
  end
  local ok2, handle = pcall(placement.new, buf, path, opts)
  if ok2 then
    return handle
  end
  return nil
end

---@param buf integer        Target buffer (cell buffer or output float).
---@param cell_hash string   Identity used for placement bookkeeping.
---@param image_chunks table List of { chunk = <image chunk>, index = <int>, row = <int>?, col = <int>? };
---@param opts table?        { base_row = <int, 1-based buffer row for index 0; default 1> }
---@return table<integer, boolean> placed  set of `index` values that got a live placement
function M.render(buf, cell_hash, image_chunks, opts)
  ensure_wipeout_cleanup()
  local placed_idx = {}
  opts = opts or {}
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
    return placed_idx
  end
  local cfg = require("jove").config
  if not (cfg.output and cfg.output.images) then
    return placed_idx
  end
  if not M.available() then
    M.notify_missing()
    return placed_idx
  end

  local base_row = opts.base_row or 1
  local for_buf = placed[buf] or {}
  local for_cell = for_buf[cell_hash] or {}
  local chunks = image_chunks or {}
  for i = #chunks, 1, -1 do
    local entry = chunks[i]
    local path = M.decode(entry.chunk)
    if path then
      local key = ("%d:%s"):format(entry.index, path)
      if for_cell[key] then
        placed_idx[entry.index] = true
      else
        local row = entry.row or (base_row + entry.index)
        local handle = place(buf, row, path, entry.col)
        if handle then
          for_cell[key] = handle
          placed_idx[entry.index] = true
        end
      end
    end
  end
  placed[buf] = for_buf
  for_buf[cell_hash] = for_cell
  return placed_idx
end

---@param buf integer
---@param cell_hash string?
function M.clear(buf, cell_hash)
  local for_buf = placed[buf]
  if not for_buf then
    return
  end
  local function close_cell(for_cell)
    for _, handle in pairs(for_cell) do
      if type(handle) == "table" and type(handle.close) == "function" then
        pcall(handle.close, handle)
      end
    end
  end
  if cell_hash then
    if for_buf[cell_hash] then
      close_cell(for_buf[cell_hash])
      for_buf[cell_hash] = nil
    end
  else
    for _, for_cell in pairs(for_buf) do
      close_cell(for_cell)
    end
    placed[buf] = nil
  end
end

return M

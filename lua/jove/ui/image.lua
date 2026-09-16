-- ui/image.lua: optional snacks.image integration for inline image outputs.
--
-- snacks is loaded on demand: availability is probed with
-- pcall on every use so the plugin can appear mid-session. Without it (or with
-- config `output.images = false`) output.lua renders a text placeholder and we
-- notify at most once per session with an install hint.
local M = {}

local MIME_EXT = { ["image/png"] = "png", ["image/jpeg"] = "jpg" }

-- Placement bookkeeping: placed[buf] = { [cell_hash] = { ["<index>:<path>"] = placement } }
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

---Load snacks.image, requiring the parent "snacks" first when needed: the
---submodule reads the global `Snacks` at load time, which only the parent's
---init sets — so a bare require fails when snacks is installed but its
---setup() has not run yet.
---@return table? snacks
local function load()
  pcall(require, "snacks")
  local ok, snacks = pcall(require, "snacks.image")
  if ok and type(snacks) == "table" then
    return snacks
  end
  return nil
end

---True when snacks.image is loadable right now.
---@return boolean
function M.available()
  return load() ~= nil
end

---True when image rendering is both enabled in config and possible.
---@return boolean
function M.enabled()
  local cfg = require("jove").config
  if not (cfg.output and cfg.output.images) then
    return false
  end
  return M.available()
end

---One-time-per-session INFO hint when images are wanted but snacks is absent.
function M.notify_missing()
  if notified then
    return
  end
  notified = true
  vim.notify("snacks.image enables inline image outputs", vim.log.levels.INFO)
end

---Decode a base64 image chunk to a temp file, cached on the chunk itself so
---each chunk is written to disk at most once per session.
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

---Place one image via snacks.image.placement (feature-detected so snacks API
---drift degrades to the text placeholder instead of an error).
---@param buf integer
---@param row integer  1-based buffer line the image anchors at
---@param path string
---@return table? placement  snacks placement handle on success
local function place(buf, row, path)
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
  local ok2, handle = pcall(placement.new, buf, path, {
    pos = { row, 0 },
    inline = true,
  })
  if ok2 then
    return handle
  end
  return nil
end

---Place image chunks on `buf`.
---@param buf integer        Target buffer (cell buffer or output float).
---@param cell_hash string   Identity used for placement bookkeeping.
---@param image_chunks table List of { chunk = <image chunk>, index = <int>, row = <int>? };
---   `row` is an explicit 1-based anchor line: inline outputs anchor every
---   image at the cell's last real line because virt_lines have no buffer row
---   of their own. Without `row` the anchor is `opts.base_row + index` (the
---   output float, where the placeholder is a real line).
---@param opts table?        { base_row = <int, 1-based buffer row for index 0; default 1> }
function M.render(buf, cell_hash, image_chunks, opts)
  ensure_wipeout_cleanup()
  opts = opts or {}
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local cfg = require("jove").config
  if not (cfg.output and cfg.output.images) then
    return -- user opted out: output.lua keeps the text placeholder, stay silent
  end
  if not M.available() then
    M.notify_missing()
    return
  end

  local base_row = opts.base_row or 1
  local for_buf = placed[buf] or {}
  local for_cell = for_buf[cell_hash] or {}
  for _, entry in ipairs(image_chunks or {}) do
    local path = M.decode(entry.chunk)
    if path then
      local key = ("%d:%s"):format(entry.index, path)
      if not for_cell[key] then
        local row = entry.row or (base_row + entry.index)
        local handle = place(buf, row, path)
        if handle then
          for_cell[key] = handle
        end
      end
    end
  end
  placed[buf] = for_buf
  for_buf[cell_hash] = for_cell
end

---Close placement handles and forget the records (records also die with the
---buffer via BufWipeout).
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

-- ui/image.lua: optional snacks.image integration for inline image outputs.
--
-- snacks is NEVER required at module load time: availability is probed with
-- pcall on every use so the plugin can appear mid-session. Without it (or with
-- config `output.images = false`) output.lua renders a text placeholder and we
-- notify at most once per session with an install hint.
local M = {}

local MIME_EXT = { ["image/png"] = "png", ["image/jpeg"] = "jpg" }

-- Placement bookkeeping: placed[buf] = { [cell_hash] = { ["<index>:<path>"] = true } }
---@type table<integer, table<string, table<string, boolean>>>
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

---True when snacks.image is loadable right now.
---@return boolean
function M.available()
  local ok = pcall(require, "snacks.image")
  return ok
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
  vim.fn.writefile({ decoded }, path, "b")
  chunk.image_path = path
  return path
end

---Feature-detect a usable snacks.image placement function and call it.
---@param buf integer
---@param row integer  1-based buffer line for the image
---@param path string
---@return boolean
local function place(buf, row, path)
  local ok, snacks = pcall(require, "snacks.image")
  if not ok or type(snacks) ~= "table" then
    return false
  end
  if type(snacks.place_at) == "function" then
    return pcall(snacks.place_at, buf, row - 1, 0, path, {})
  elseif type(snacks.place) == "function" then
    return pcall(snacks.place, { buf = buf, row = row - 1, col = 0, src = path })
  end
  return false
end

---Place image chunks on `buf`.
---@param buf integer        Target buffer (cell buffer or output float).
---@param cell_hash string   Identity used for placement bookkeeping.
---@param image_chunks table List of { chunk = <image chunk>, index = <int> };
---   `index` is the 1-based line offset from `opts.base_row` where the chunk's
---   anchor line was rendered.
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
        local row = base_row + entry.index
        if place(buf, row, path) then
          for_cell[key] = true
        end
      end
    end
  end
  placed[buf] = for_buf
  for_buf[cell_hash] = for_cell
end

---Forget placement records (records die with the buffer via BufWipeout too).
---@param buf integer
---@param cell_hash string?
function M.clear(buf, cell_hash)
  local for_buf = placed[buf]
  if not for_buf then
    return
  end
  if cell_hash then
    for_buf[cell_hash] = nil
  else
    placed[buf] = nil
  end
end

return M

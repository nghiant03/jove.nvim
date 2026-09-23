-- Cell status rendering.
local cell = require("jove.cell")

local execute = require("jove.execute")

local chrome = require("jove.ui.chrome")

local M = {}

local ns = vim.api.nvim_create_namespace("jove_cell_status")

---@type table<integer, table>
local bufs = {}

---@param buf integer
---@return table
local function ensure(buf)
  local b = bufs[buf]
  if not b then
    b = { marks = {}, unsub = nil }
    bufs[buf] = b
  end
  return b
end

---@return boolean
local function conceal_headers()
  local ok, jove = pcall(require, "jove")
  local ui = ok and type(jove) == "table" and jove.config and jove.config.ui
  return type(ui) == "table" and ui.conceal_headers ~= false or type(ui) ~= "table"
end

---@param buf integer
---@param hash string
---@return integer?
local function cell_lnum(buf, hash)
  for _, c in ipairs(cell.all(buf)) do
    if c.hash == hash then
      if conceal_headers() and c.header then
        local body = c.header + 1
        return body <= c.end_lnum and body or c.header
      end
      return c.start_lnum
    end
  end
  return nil
end

---@param buf integer
---@param hash string
---@param status "queued"|"running"|"ok"|"error"
function M.on_status(buf, hash, status)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local b = bufs[buf]
  if not b or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local lnum = cell_lnum(buf, hash)
  if not lnum then
    if b.marks[hash] then
      pcall(vim.api.nvim_buf_del_extmark, buf, ns, b.marks[hash])
      b.marks[hash] = nil
    end
    return
  end

  local sign = require("jove").config.signs[status]
  if sign then
    local id = vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
      id = b.marks[hash],
      sign_text = sign .. " ",
      priority = 10,
    })
    b.marks[hash] = id
  end
end

---@param buf integer
function M.attach(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local b = ensure(buf)
  chrome.attach(buf)
  if b.unsub then
    return
  end
  b.unsub = execute.on_status(buf, function(hash, status)
    M.on_status(buf, hash, status)
  end)
end

vim.api.nvim_create_autocmd("BufWipeout", {
  group = vim.api.nvim_create_augroup("jove_ui", { clear = false }),
  pattern = "*",
  callback = function(ev)
    local b = bufs[ev.buf]
    if b then
      if b.unsub then
        pcall(b.unsub)
      end
      bufs[ev.buf] = nil
    end
    chrome.detach(ev.buf)
  end,
})

return M

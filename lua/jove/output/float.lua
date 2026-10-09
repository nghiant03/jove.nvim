-- Float viewer

local state = require("jove.state")
local cell = require("jove.cell")
local render = require("jove.output.render")

local M = {}

local ns = vim.api.nvim_create_namespace("jove-output")

---@param lines table[]  virt_lines from render.build_lines
---@param ft string      filetype of the notebook buffer (for treesitter)
---@return integer fbuf
local function build_buf(lines, ft)
  local plain = {}
  for i, line in ipairs(lines) do
    local parts = {}
    for _, seg in ipairs(line) do
      parts[#parts + 1] = seg[1]
    end
    plain[i] = table.concat(parts)
  end

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, plain)
  vim.bo[fbuf].buflisted = false
  vim.bo[fbuf].bufhidden = "wipe"
  for i, line in ipairs(lines) do
    local col = 0
    for _, seg in ipairs(line) do
      if seg[2] and #seg[1] > 0 then
        vim.api.nvim_buf_set_extmark(fbuf, ns, i - 1, col, {
          end_col = col + #seg[1],
          hl_group = seg[2],
        })
      end
      col = col + #seg[1]
    end
  end

  if ft ~= "" then
    vim.bo[fbuf].filetype = ft
    pcall(function()
      local lang = vim.treesitter.language.get_lang(ft)
      if lang then
        vim.treesitter.start(fbuf, lang)
      end
    end)
  end
  return fbuf
end

---@param fbuf integer
---@return integer? win
local function open_win(fbuf)
  local width = math.max(20, math.floor(vim.o.columns * 0.8))
  local height = math.max(5, math.floor(vim.o.lines * 0.8))
  local win_ui = require("jove.ui.win")
  local size = win_ui.mode("output") == "hsplit" and math.floor(vim.o.lines * 0.4)
    or math.floor(vim.o.columns * 0.5)
  local win = win_ui.open(fbuf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
  }, size, "output")
  if not win then
    return nil
  end
  vim.wo[win].wrap = false
  vim.wo[win].scrolloff = 2

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set(
    "n",
    "q",
    close,
    { buffer = fbuf, nowait = true, silent = true, desc = "Jove: Close Output Viewer" }
  )
  vim.keymap.set(
    "n",
    "<Esc>",
    close,
    { buffer = fbuf, nowait = true, silent = true, desc = "Jove: Close Output Viewer" }
  )
  return win
end

---@param buf integer
---@param lnum integer?  Defaults to the cursor line of the current window.
---@return integer? win
function M.open(buf, lnum)
  buf = (buf == 0 or buf == nil) and vim.api.nvim_get_current_buf() or buf
  local st = state.peek(buf)
  if not st or not st.outputs or not vim.api.nvim_buf_is_loaded(buf) then
    return nil
  end
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local c = cell.at(buf, lnum)
  if not c then
    return nil
  end
  local entry = st.outputs[c.hash]
  if not entry or #entry.chunks == 0 then
    return nil
  end

  local lines, images = render.build_lines(entry.chunks)
  local fbuf = build_buf(lines, vim.bo[buf].filetype)
  local win = open_win(fbuf)
  if not win then
    pcall(vim.api.nvim_buf_delete, fbuf, { force = true })
    return nil
  end

  if #images > 0 then
    pcall(require("jove.ui.image").render, fbuf, c.hash, images, { base_row = 0 })
  end
  return win
end

return M

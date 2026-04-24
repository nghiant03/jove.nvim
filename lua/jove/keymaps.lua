-- keymaps.lua: cell navigation + run helpers wrapping molten.
local M = {}

local CELL_PAT = "^# %%%%"

---Find the [start, end] line range (1-based, inclusive) of the cell at `lnum`.
---@param buf integer
---@param lnum integer  1-based
---@return integer, integer
local function cell_range(buf, lnum)
  local total = vim.api.nvim_buf_line_count(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, total, false)

  local start = 1
  for i = lnum, 1, -1 do
    if lines[i] and lines[i]:match(CELL_PAT) then
      start = i
      break
    end
  end

  local stop = total
  for i = start + 1, total do
    if lines[i]:match(CELL_PAT) then
      stop = i - 1
      break
    end
  end
  return start, stop
end

---Jump to the next/previous cell header from the cursor.
---@param dir 1|-1
local function jump(dir)
  local buf = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local total = vim.api.nvim_buf_line_count(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, total, false)

  local i = cur + dir
  while i >= 1 and i <= total do
    if lines[i]:match(CELL_PAT) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
    i = i + dir
  end
end

function M.next_cell()
  jump(1)
end

function M.prev_cell()
  jump(-1)
end

---Visually select the cell containing the cursor and call MoltenEvaluateVisual.
function M.run_cell()
  if vim.fn.exists(":MoltenEvaluateVisual") ~= 2 then
    vim.notify("[jove] molten not loaded", vim.log.levels.WARN)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local s, e = cell_range(buf, cur)
  -- Skip the `# %%` header line when selecting code body.
  local body_start = s + 1
  if body_start > e then
    return
  end
  vim.api.nvim_win_set_cursor(0, { body_start, 0 })
  vim.cmd(("normal! V%dG"):format(e))
  vim.cmd("MoltenEvaluateVisual")
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "nx", false)
end

---Run every cell from the top of the buffer up to (and including) the cursor.
function M.run_above()
  if vim.fn.exists(":MoltenEvaluateVisual") ~= 2 then
    vim.notify("[jove] molten not loaded", vim.log.levels.WARN)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local total = vim.api.nvim_buf_line_count(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, total, false)
  for i = 1, cur do
    if lines[i]:match(CELL_PAT) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      M.run_cell()
    end
  end
end

---Run every cell in the buffer.
function M.run_all()
  if vim.fn.exists(":MoltenEvaluateVisual") ~= 2 then
    vim.notify("[jove] molten not loaded", vim.log.levels.WARN)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local total = vim.api.nvim_buf_line_count(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, total, false)
  for i = 1, total do
    if lines[i]:match(CELL_PAT) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      M.run_cell()
    end
  end
end

---Apply user-configured keymaps. Called from setup().
---@param keymap table<string, string|false>
function M.apply(keymap)
  if not keymap then
    return
  end
  local opts = { silent = true, desc = nil }
  local function map(lhs, rhs, desc)
    if not lhs then
      return
    end
    opts.desc = desc
    vim.api.nvim_create_autocmd("FileType", {
      pattern = { "python", "julia", "r" },
      callback = function(ev)
        if vim.b[ev.buf].jove_path then
          vim.keymap.set("n", lhs, rhs, vim.tbl_extend("force", opts, { buffer = ev.buf }))
        end
      end,
    })
  end

  map(keymap.run_cell, M.run_cell, "jove: run cell")
  map(keymap.next_cell, M.next_cell, "jove: next cell")
  map(keymap.prev_cell, M.prev_cell, "jove: prev cell")
end

return M

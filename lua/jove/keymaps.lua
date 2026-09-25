-- Cell navigation and execution mappings.

local cell = require("jove.cell")
local execute = require("jove.execute")
local state = require("jove.state")

local M = {}

local follow_unsubs = {}

---@param buf integer
---@param hash string
---@return integer? lnum  cell start (header) matching the content hash
local function cell_start_by_hash(buf, hash)
  for _, c in ipairs(cell.all(buf)) do
    if c.hash == hash then
      return c.start_lnum
    end
  end
  return nil
end

---@param buf integer
---@param hash string
local function jump_to_hash(buf, hash)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    return
  end
  local target = cell_start_by_hash(buf, hash)
  if target then
    vim.api.nvim_win_set_cursor(win, { target, 0 })
    vim.api.nvim_win_call(win, function()
      vim.cmd("normal! zt")
    end)
  end
end

---@param dir 1|-1
local function jump(dir)
  local buf = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local target
  if dir == 1 then
    target = cell.next(buf, cur)
  else
    target = cell.prev(buf, cur)
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  end
end

function M.next_cell()
  jump(1)
end

function M.prev_cell()
  jump(-1)
end

function M.goto_running_cell()
  local buf = vim.api.nvim_get_current_buf()
  local running = execute.running(buf)
  if not running then
    vim.notify("[jove] no cell is currently executing", vim.log.levels.INFO)
    return
  end
  local target = cell_start_by_hash(buf, running.hash)
  if not target then
    local c = cell.at(buf, running.lnum)
    target = c and c.start_lnum or nil
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  end
end

---@param buf integer
---@return boolean
function M.is_following(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  return follow_unsubs[buf] ~= nil
end

function M.toggle_follow_running()
  local buf = vim.api.nvim_get_current_buf()
  local unsub = follow_unsubs[buf]
  if unsub then
    follow_unsubs[buf] = nil
    pcall(unsub)
    vim.notify("[jove] follow running cell: off", vim.log.levels.INFO)
    return
  end
  follow_unsubs[buf] = execute.on_status(buf, function(hash, status)
    if status == "running" then
      jump_to_hash(buf, hash)
    end
  end)
  local wipe_group = vim.api.nvim_create_augroup("jove_follow_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = wipe_group,
    buffer = buf,
    callback = function()
      local u = follow_unsubs[buf]
      follow_unsubs[buf] = nil
      if u then
        pcall(u)
      end
      pcall(vim.api.nvim_del_augroup_by_id, wipe_group)
    end,
  })
  vim.notify("[jove] follow running cell: on", vim.log.levels.INFO)
  local running = execute.running(buf)
  if running then
    jump_to_hash(buf, running.hash)
  end
end

function M.run_cell()
  execute.run_cell(vim.api.nvim_get_current_buf())
end

function M.run_above()
  execute.run_above(vim.api.nvim_get_current_buf())
end

function M.run_all()
  execute.run_all(vim.api.nvim_get_current_buf())
end

function M.run_selection()
  execute.run_selection(vim.api.nvim_get_current_buf())
end

function M.run_cell_and_advance()
  execute.run_cell_and_advance(vim.api.nvim_get_current_buf())
end

---@param buf integer
---@param mode string|string[]
---@param lhs string
---@param rhs string|function
---@param desc string
local function bmap(buf, mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, desc = desc })
end

---@param buf integer
local function attach(buf)
  for _, obj in ipairs({ { "ic", "i" }, { "ac", "a" } }) do
    local lhs, kind = obj[1], obj[2]
    for _, mode in ipairs({ "x", "o" }) do
      bmap(buf, mode, lhs, function()
        cell.textobj(kind)
      end, kind == "i" and "Jove: Select Cell Body" or "Jove: Select Whole Cell")
    end
  end

  bmap(buf, "n", "<Plug>(JoveRunCell)", M.run_cell, "Jove: Run Cell")
  bmap(buf, "n", "<Plug>(JoveRunAbove)", M.run_above, "Jove: Run Cells Above")
  bmap(buf, "n", "<Plug>(JoveRunAll)", M.run_all, "Jove: Run All Cells")
  bmap(buf, "x", "<Plug>(JoveRunSelection)", M.run_selection, "Jove: Run Selection")
  bmap(
    buf,
    "n",
    "<Plug>(JoveRunCellAndAdvance)",
    M.run_cell_and_advance,
    "Jove: Run Cell and Advance"
  )
  bmap(buf, "n", "<Plug>(JoveNextCell)", M.next_cell, "Jove: Next Cell")
  bmap(buf, "n", "<Plug>(JovePrevCell)", M.prev_cell, "Jove: Previous Cell")
  bmap(buf, "n", "<Plug>(JoveGotoRunningCell)", M.goto_running_cell, "Jove: Go to Running Cell")
  bmap(
    buf,
    "n",
    "<Plug>(JoveToggleFollowRunning)",
    M.toggle_follow_running,
    "Jove: Toggle Follow Running Cell"
  )

  local cfg = require("jove").config
  if cfg.cell_motions then
    for _, motion in ipairs({
      { "]c", M.next_cell, "<Plug>(JoveNextCell)", "Jove: Next Cell" },
      { "[c", M.prev_cell, "<Plug>(JovePrevCell)", "Jove: Previous Cell" },
    }) do
      local lhs, rhs, plug, desc = motion[1], motion[2], motion[3], motion[4]
      local taken = vim.api.nvim_buf_call(buf, function()
        return vim.fn.maparg(lhs, "n") ~= "" or vim.fn.hasmapto(plug, "n") == 1
      end)
      if not taken then
        bmap(buf, "n", lhs, rhs, desc)
      end
    end
  end

  require("jove.ui").attach(buf)
end

---@param buf integer
function M.on_filetype(buf)
  local entry = state.peek(buf)
  if entry and entry.path then
    attach(buf)
  end
end

return M

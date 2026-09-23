-- Cell navigation and execution mappings.
local cell = require("jove.cell")
local execute = require("jove.execute")
local state = require("jove.state")

local M = {}

-- buf -> unsubscribe fn while "follow running cell" is enabled.
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

---@param keymap table<string, string|false>
function M.apply(keymap)
  if not keymap then
    return
  end
  local group = vim.api.nvim_create_augroup("jove_keymaps", { clear = true })
  local opts = { silent = true }
  local patterns = { "python", "julia", "r", "javascript" }

  local function map(lhs, rhs, desc, mode)
    if not lhs then
      return
    end
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = patterns,
      desc = desc,
      callback = function(ev)
        local entry = state.peek(ev.buf)
        if entry and entry.path then
          vim.keymap.set(
            mode or "n",
            lhs,
            rhs,
            vim.tbl_extend("force", opts, { buffer = ev.buf, desc = desc })
          )
        end
      end,
    })
  end

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = patterns,
    desc = "jove: built-in cell text-objects, motions, run extras",
    callback = function(ev)
      local entry = state.peek(ev.buf)
      if entry and entry.path then
        for _, obj in ipairs({ { "ic", "i" }, { "ac", "a" } }) do
          local lhs, kind = obj[1], obj[2]
          for _, mode in ipairs({ "x", "o" }) do
            vim.keymap.set(
              mode,
              lhs,
              function()
                cell.textobj(kind)
              end,
              vim.tbl_extend("force", opts, {
                buffer = ev.buf,
                desc = kind == "i" and "Jove: Select Cell Body" or "Jove: Select Whole Cell",
              })
            )
          end
        end

        local cfg = require("jove").config
        if cfg.cell_motions then
          vim.keymap.set("n", "]c", M.next_cell, {
            buffer = ev.buf,
            silent = true,
            desc = "Jove: Next Cell",
          })
          vim.keymap.set("n", "[c", M.prev_cell, {
            buffer = ev.buf,
            silent = true,
            desc = "Jove: Previous Cell",
          })
        end
        if cfg.keymap.run_and_advance then
          vim.keymap.set("n", cfg.keymap.run_and_advance, M.run_cell_and_advance, {
            buffer = ev.buf,
            silent = true,
            desc = "Jove: Run Cell and Advance",
          })
        end
        if cfg.keymap.run_selection then
          vim.keymap.set("x", cfg.keymap.run_selection, M.run_selection, {
            buffer = ev.buf,
            silent = true,
            desc = "Jove: Run Selection",
          })
        end

        require("jove.ui").attach(ev.buf)
      end
    end,
  })

  map(keymap.run_cell, M.run_cell, "Jove: Run Cell")
  map(keymap.next_cell, M.next_cell, "Jove: Next Cell")
  map(keymap.prev_cell, M.prev_cell, "Jove: Previous Cell")
  map(keymap.goto_running_cell, M.goto_running_cell, "Jove: Go to Running Cell")
  map(keymap.toggle_follow_running, M.toggle_follow_running, "Jove: Toggle Follow Running Cell")
end

return M

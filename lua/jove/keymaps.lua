-- keymaps.lua: cell navigation + run helpers wrapping molten.
-- Navigation and run ranges come from the cached cell model in lua/jove/cell.lua
-- (one parse per buffer version, no per-cell full-buffer line fetches).
local cell = require("jove.cell")
local state = require("jove.state")

local M = {}

---Jump to the next/previous cell header from the cursor.
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

---Visually select the cell containing the cursor and call MoltenEvaluateVisual.
function M.run_cell()
  if vim.fn.exists(":MoltenEvaluateVisual") ~= 2 then
    vim.notify("[jove] molten not loaded", vim.log.levels.WARN)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local c = cell.at(buf, cur)
  if not c then
    return
  end
  -- Skip the `# %%` header line when selecting code body.
  local body_start = c.header and c.header + 1 or c.start_lnum
  if body_start > c.end_lnum then
    return
  end
  vim.api.nvim_win_set_cursor(0, { body_start, 0 })
  vim.cmd(("normal! V%dG"):format(c.end_lnum))
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
  for _, c in ipairs(cell.all(buf)) do
    if c.header and c.header <= cur then
      vim.api.nvim_win_set_cursor(0, { c.header, 0 })
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
  for _, c in ipairs(cell.all(buf)) do
    if c.header then
      vim.api.nvim_win_set_cursor(0, { c.header, 0 })
      M.run_cell()
    end
  end
end

---Apply user-configured keymaps. Called from setup().
---Idempotent: the augroup is created with clear=true so repeated setup() calls
---replace the previous autocmds instead of stacking duplicates.
---@param keymap table<string, string|false>
function M.apply(keymap)
  if not keymap then
    return
  end
  local group = vim.api.nvim_create_augroup("jove_keymaps", { clear = true })
  local opts = { silent = true }
  local patterns = { "python", "julia", "r", "javascript" }

  local function map(lhs, rhs, desc)
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
          vim.keymap.set("n", lhs, rhs, vim.tbl_extend("force", opts, { buffer = ev.buf }))
        end
      end,
    })
  end

  -- Built-in `ic`/`ac` cell text-objects: always on for jove buffers (not
  -- config-gated), registered alongside the user keymaps below.
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = patterns,
    desc = "jove: built-in cell text-objects (ic/ac)",
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
                desc = "jove: select cell " .. (kind == "i" and "body" or "whole"),
              })
            )
          end
        end
      end
    end,
  })

  map(keymap.run_cell, M.run_cell, "jove: run cell")
  map(keymap.next_cell, M.next_cell, "jove: next cell")
  map(keymap.prev_cell, M.prev_cell, "jove: prev cell")
end

return M

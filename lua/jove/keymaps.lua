-- keymaps.lua: cell navigation + run entry points over lua/jove/execute.lua.
-- Navigation and run ranges come from the cached cell model in lua/jove/cell.lua
-- (one parse per buffer version, no per-cell full-buffer line fetches).
-- Execution itself is the per-buffer FIFO queue in execute.lua (no molten,
-- no visual-mode hack).
local cell = require("jove.cell")
local execute = require("jove.execute")
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

---Run the cell containing the cursor (direct code send via execute.lua).
function M.run_cell()
  execute.run_cell(vim.api.nvim_get_current_buf())
end

---Run every code cell from the top of the buffer up to the cursor.
function M.run_above()
  execute.run_above(vim.api.nvim_get_current_buf())
end

---Run every code cell in the buffer.
function M.run_all()
  execute.run_all(vim.api.nvim_get_current_buf())
end

---Run the visual selection as one unit (x-mode mapping).
function M.run_selection()
  execute.run_selection(vim.api.nvim_get_current_buf())
end

---Run the cursor cell, then jump to the next cell header.
function M.run_cell_and_advance()
  execute.run_cell_and_advance(vim.api.nvim_get_current_buf())
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
          vim.keymap.set(mode or "n", lhs, rhs, vim.tbl_extend("force", opts, { buffer = ev.buf }))
        end
      end,
    })
  end

  -- Built-in per-buffer setup: `ic`/`ac` cell text-objects, `[c`/`]c` cell
  -- motions (cfg.cell_motions), run_and_advance + run_selection mappings.
  -- Registered as ONE FileType autocmd alongside the user keymaps below.
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
                desc = "jove: select cell " .. (kind == "i" and "body" or "whole"),
              })
            )
          end
        end

        local cfg = require("jove").config
        if cfg.cell_motions then
          vim.keymap.set("n", "]c", M.next_cell, {
            buffer = ev.buf,
            silent = true,
            desc = "jove: next cell",
          })
          vim.keymap.set("n", "[c", M.prev_cell, {
            buffer = ev.buf,
            silent = true,
            desc = "jove: prev cell",
          })
        end
        if cfg.keymap.run_and_advance then
          vim.keymap.set("n", cfg.keymap.run_and_advance, M.run_cell_and_advance, {
            buffer = ev.buf,
            silent = true,
            desc = "jove: run cell and advance",
          })
        end
        if cfg.keymap.run_selection then
          vim.keymap.set("x", cfg.keymap.run_selection, M.run_selection, {
            buffer = ev.buf,
            silent = true,
            desc = "jove: run selection",
          })
        end

        -- Status rendering (gutter signs + spinner) for this buffer.
        require("jove.ui").attach(ev.buf)
      end
    end,
  })

  map(keymap.run_cell, M.run_cell, "jove: run cell")
  map(keymap.next_cell, M.next_cell, "jove: next cell")
  map(keymap.prev_cell, M.prev_cell, "jove: prev cell")
end

return M

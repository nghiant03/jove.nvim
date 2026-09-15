-- Notebook outline from markdown-cell headings.
--
-- Markdown cells are stored by jupytext as `# %% [markdown]` followed by
-- comment-prefixed lines, so `# Header` in the source appears as
-- `# # Header` in the buffer. This module strips that comment prefix and
-- collects ATX headings (`#`..`######`) per cell for `:JoveToc`.
local state = require("jove.state")
local cell = require("jove.cell")

local M = {}

---@param buf integer?
---@return integer
local function norm_buf(buf)
  if buf == nil or buf == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return buf
end

---Strip the jupytext markdown comment marker from one body line.
---"# # Header" -> "# Header"; "# plain" -> "plain"; "#" -> "".
---@param line string
---@return string
local function strip_comment(line)
  if line:sub(1, 2) == "# " then
    return line:sub(3)
  end
  if line == "#" then
    return ""
  end
  if line:sub(1, 1) == "#" then
    return line:sub(2)
  end
  return line
end

---@class jove.TocEntry
---@field level integer      Heading level (1-6); 0 for the notebook title.
---@field title string
---@field cell_idx integer   Index into cell.all(buf); 0 for the title.
---@field lnum integer       Cell start line to jump to.

---Collect the outline for `buf`: an optional notebook-title entry followed by
---every markdown ATX heading, in buffer order.
---@param buf integer?
---@return jove.TocEntry[]
function M.headings(buf)
  buf = norm_buf(buf)
  local out = {}

  local entry = state.peek(buf)
  local title = entry and entry.json and entry.json.metadata and entry.json.metadata.title
  if type(title) == "string" and title ~= "" then
    out[#out + 1] = { level = 0, title = title, cell_idx = 0, lnum = 1 }
  end

  for idx, c in ipairs(cell.all(buf)) do
    if c.kind == "markdown" then
      local body_start = c.header and c.header + 1 or c.start_lnum
      local lines = vim.api.nvim_buf_get_lines(buf, body_start - 1, c.end_lnum, false)
      for _, raw in ipairs(lines) do
        local text = strip_comment(raw)
        local hashes, heading = text:match("^(#+)%s+(.+)$")
        if hashes and heading then
          out[#out + 1] = {
            level = #hashes,
            title = (heading:gsub("%s+$", "")),
            cell_idx = idx,
            lnum = c.start_lnum,
          }
        end
      end
    end
  end
  return out
end

---Show the outline in `vim.ui.select`; on confirm, jump to the heading's cell.
---@param buf integer?
function M.pick(buf)
  buf = norm_buf(buf)
  local headings = M.headings(buf)
  if #headings == 0 then
    vim.notify("[jove] no markdown headings in this notebook", vim.log.levels.INFO)
    return
  end

  local items = {}
  for _, h in ipairs(headings) do
    items[#items + 1] = {
      label = string.rep("  ", math.max(0, h.level - 1)) .. h.title,
      lnum = h.lnum,
      title = h.title,
      level = h.level,
    }
  end

  vim.ui.select(items, {
    prompt = "Table of contents",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    local target
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == buf then
        target = w
        break
      end
    end
    if not target then
      return
    end
    vim.api.nvim_set_current_win(target)
    local lnum = math.min(math.max(1, choice.lnum), vim.api.nvim_buf_line_count(buf))
    vim.api.nvim_win_set_cursor(target, { lnum, 0 })
    vim.cmd("normal! zz")
  end)
end

return M

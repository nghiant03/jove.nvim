-- Buffer events handlers.

local convert = require("jove.convert")
local persist = require("jove.persist")
local state = require("jove.state")
local kernel = require("jove.kernel")
local lang = require("jove.lang")

local M = {}

local read_seq = {}

---@type table<integer, {in_flight: boolean, dirty: boolean, pending_tick: integer?, pending_lines: string[]?}>
local flights = {}

---@param lines string[]
---@param comment string  comment leader of the buffer language ("#", "//", ...)
---@return string[]?, string[]
local function split_front(lines, comment)
  local fence = comment .. " ---"
  local first = lines[1]
  if not first or not first:match("^" .. vim.pesc(fence) .. "%s*$") then
    return nil, lines
  end
  for i = 2, #lines do
    if lines[i]:match("^" .. vim.pesc(fence) .. "%s*$") then
      local front = {}
      for j = 1, i do
        front[j] = lines[j]
      end
      local rest = {}
      for j = i + 1, #lines do
        rest[#rest + 1] = lines[j]
      end
      return front, rest
    end
  end
  return nil, lines
end

---@param path string
---@return table?
local function read_json(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local data = fd:read("*a")
  fd:close()
  local ok, json = pcall(vim.json.decode, data)
  if not ok then
    return nil
  end
  return json
end

---@param buf integer
---@param cursor [integer, integer]  -- 1-based lnum, 0-based col
---@param lines string[]
local function restore_cursor(buf, cursor, lines)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    return
  end
  local lnum = math.min(cursor[1], #lines)
  local col = math.max(0, math.min(cursor[2], #(lines[lnum] or "")))
  pcall(vim.api.nvim_win_set_cursor, win, { lnum, col })
end

---@param buf integer
---@param lines string[]
local function replace_lines(buf, lines)
  if (state.peek(buf) or {}).path ~= nil then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return
  end
  local undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = undolevels
end

---@param buf integer
---@param path string
---@param opts {preserve_cursor: boolean?, guard_tick: integer?}?
function M.read(buf, path, opts)
  opts = opts or {}
  local cfg = require("jove").config

  if not vim.uv.fs_stat(path) then
    vim.bo[buf].buftype = "acwrite"
    replace_lines(buf, { lang.default.comment .. " %%", "" })
    vim.bo[buf].modified = false
    local st = state.get(buf)
    st.path = path
    st.lang = lang.default.id
    vim.bo[buf].filetype = "python"
    require("jove.lsp").attach(buf)
    return
  end

  vim.bo[buf].buftype = "acwrite"

  local json = read_json(path)
  local spec = lang.for_notebook(json)

  local seq = (read_seq[buf] or 0) + 1
  read_seq[buf] = seq
  local initial_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local initial_rev = (state.peek(buf) or {}).content_rev or 0

  convert.read(path, function(lines, err)
    vim.schedule(function()
      if read_seq[buf] ~= seq or not vim.api.nvim_buf_is_valid(buf) then
        return
      end

      if not lines then
        vim.notify("[Jove] read failed: " .. (err or "?"), vim.log.levels.ERROR)
        return
      end

      if
        (opts.guard_tick and vim.b[buf].changedtick ~= opts.guard_tick)
        or not vim.deep_equal(initial_lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        or ((state.peek(buf) or {}).content_rev or 0) ~= initial_rev
      then
        vim.notify(
          "[Jove] reload skipped: the buffer was edited while reading",
          vim.log.levels.WARN
        )
        return
      end

      local cursor
      if opts.preserve_cursor then
        local win = vim.fn.bufwinid(buf)
        if win ~= -1 then
          cursor = vim.api.nvim_win_get_cursor(win)
        end
      end

      local front, rest = split_front(lines, spec.comment)

      local marker_prefix = spec.comment .. " %%"
      if rest[#rest] and rest[#rest]:sub(1, #marker_prefix) == marker_prefix then
        rest[#rest + 1] = ""
      end

      replace_lines(buf, rest)

      local st = state.get(buf)
      st.path = path
      st.json = json
      st.front_matter = front
      st.lang = spec.id

      vim.bo[buf].filetype = spec.filetype
      vim.bo[buf].modified = false

      require("jove.lsp").attach(buf)

      if cursor then
        restore_cursor(buf, cursor, rest)
      end

      if cfg.auto_kernel then
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buf) then
            kernel.init(buf)
          end
        end)
      end
      if cfg.auto_import_outputs then
        persist.import(buf)
      else
        require("jove.execute").reset(buf)
        require("jove.output").clear(buf, nil, { skip_dirty = true })
      end
    end)
  end, { fmt = spec.fmt })
end

---@param buf integer
---@param path string
---@param tick integer  -- changedtick captured at request time
---@param lines string[]  -- buffer lines captured at request time
---@param fmt string?  jupytext percent-format stem ("py", "js", ...)
local function start_write(buf, path, tick, lines, fmt)
  local cfg = require("jove").config
  local flight = flights[buf]
  flight.in_flight = true

  convert.write(path, lines, function(bytes, err)
    vim.schedule(function()
      flight.in_flight = false

      if not vim.api.nvim_buf_is_valid(buf) then
        flights[buf] = nil
        return
      end

      if not bytes then
        flight.dirty = false
        flight.pending_tick = nil
        flight.pending_lines = nil
        vim.notify("[Jove] write failed: " .. (err or "?"), vim.log.levels.ERROR)
        return
      end

      local st = state.get(buf)
      local ok_json, json = pcall(vim.json.decode, bytes)
      if ok_json then
        st.json = json
      end
      st.last_write = vim.fn.sha256(bytes)

      vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })

      local export_failed = false
      if cfg.auto_export_outputs and not flight.dirty then
        local _, export_err = persist.export(buf, bytes)
        export_failed = export_err ~= nil
      end

      if export_failed then
        vim.bo[buf].modified = true
      elseif vim.api.nvim_buf_get_changedtick(buf) == tick and not flight.dirty then
        vim.bo[buf].modified = false
      end

      if flight.dirty then
        flight.dirty = false
        local ptick = flight.pending_tick
        local plines = flight.pending_lines
        flight.pending_tick = nil
        flight.pending_lines = nil
        if ptick and plines then
          start_write(buf, path, ptick, plines, fmt)
        else
          flights[buf] = nil
        end
      else
        flights[buf] = nil
      end
    end)
  end, { fmt = fmt })
end

---@param buf integer
---@param path string
function M.write(buf, path)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local st = state.peek(buf)
  local spec = lang.get(st and st.lang or nil)
  local fence_prefix = spec.comment .. " --"
  if st and st.front_matter and not lines[1]:match("^" .. vim.pesc(fence_prefix)) then
    local merged = {}
    for _, l in ipairs(st.front_matter) do
      merged[#merged + 1] = l
    end
    for _, l in ipairs(lines) do
      merged[#merged + 1] = l
    end
    lines = merged
  end

  local flight = flights[buf]
  if flight and flight.in_flight then
    flight.dirty = true
    flight.pending_tick = tick
    flight.pending_lines = lines
    return
  end

  flights[buf] = { in_flight = false, dirty = false, pending_tick = nil, pending_lines = nil }
  start_write(buf, path, tick, lines, spec.fmt)
end

---@param a string
---@param b string
---@return boolean
local function same_file(a, b)
  local ra, rb = vim.uv.fs_realpath(a), vim.uv.fs_realpath(b)
  if ra and rb then
    return ra == rb
  end
  return vim.fn.fnamemodify(a, ":p") == vim.fn.fnamemodify(b, ":p")
end

---@param buf integer
---@param path string
---@return boolean?
function M.changed_shell(buf, path)
  local st = state.peek(buf)
  if not st or not st.path then
    return nil
  end
  if not same_file(st.path, path) then
    return nil
  end

  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local bytes = fd:read("*a")
  fd:close()

  if st.last_write and bytes and vim.fn.sha256(bytes) == st.last_write then
    return true
  end

  local cfg = require("jove").config
  if cfg.auto_reload then
    if vim.bo[buf].modified then
      vim.notify(
        ("[Jove] %s changed on disk; buffer has unsaved changes — :Jove reload to discard them"):format(
          path
        ),
        vim.log.levels.WARN
      )
      return true
    end
    local tick = vim.b[buf].changedtick
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then
        M.read(buf, st.path, { preserve_cursor = true, guard_tick = tick })
      end
    end)
    return false
  end

  return nil
end

---@param buf integer
function M.reload(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local st = state.peek(buf)
  local path = (st and st.path) or vim.api.nvim_buf_get_name(buf)
  if path == "" then
    vim.notify("[Jove] buffer has no notebook file to reload", vim.log.levels.WARN)
    return
  end
  M.read(buf, path, { preserve_cursor = true, guard_tick = vim.b[buf].changedtick })
end

return M

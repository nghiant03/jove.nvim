-- PTY output relay.

local kitty = require("jove.webview.kitty")

local M = {}

---@class jove.webview.Transport
---@field image_id integer
---@field cell integer[]
---@field cols integer
---@field rows integer
---@field pending string
---@field frame string[]?
---@field frame_cols integer?
---@field frame_rows integer?
---@field output fun(data: string)
---@field input fun(data: string)
---@field graphics fun(data: string)
---@field placed fun(cols: integer?, rows: integer?)
local Transport = {}
Transport.__index = Transport

---@param image_id integer
---@param cell integer[]
---@param callbacks { output: fun(data: string), input: fun(data: string), graphics: fun(data: string), placed: fun(cols: integer?, rows: integer?) }
---@return jove.webview.Transport
function M.new(image_id, cell, callbacks)
  return setmetatable({
    image_id = image_id,
    cell = cell,
    cols = 1,
    rows = 1,
    pending = "",
    output = callbacks.output,
    input = callbacks.input,
    graphics = callbacks.graphics,
    placed = callbacks.placed,
  }, Transport)
end

---@param cols integer
---@param rows integer
function Transport:resize(cols, rows)
  self.cols, self.rows = cols, rows
end

---@param sequence string  Complete APC, including its terminator.
function Transport:kitty(sequence)
  local body = sequence:sub(4, -3)
  local header, payload = body:match("^([^;]*);(.*)$")
  header = header or body
  local keys = {}
  for key, value in header:gmatch("([%a])=([^,]+)") do
    keys[key] = value
  end
  if keys.a == "q" then
    -- Only inline images are used. Never advertise file/shared-memory transport.
    local reply = keys.t == "d" and "OK" or "ENOTSUP"
    self.input(("\27_Gi=%s;%s\27\\"):format(keys.i or "0", reply))
    return
  end
  if keys.a == "d" then
    self.frame = nil
    self.graphics(kitty.delete(self.image_id))
    self.placed(nil)
    return
  end
  if keys.a == "T" and keys.t == "d" then
    local width, height = tonumber(keys.s), tonumber(keys.v)
    if not width or not height or width <= 0 or height <= 0 then
      return
    end
    self.frame_cols = math.min(math.ceil(width / self.cell[1]), self.cols, kitty.MAX_CELLS)
    self.frame_rows = math.min(math.ceil(height / self.cell[2]), self.rows, kitty.MAX_CELLS)
    local params = {
      "a=T",
      "t=d",
      "q=2",
      "U=1",
      "i=" .. self.image_id,
      "c=" .. self.frame_cols,
      "r=" .. self.frame_rows,
    }
    for _, key in ipairs({ "f", "o", "s", "v", "m" }) do
      if keys[key] then
        params[#params + 1] = key .. "=" .. keys[key]
      end
    end
    sequence = "\27_G" .. table.concat(params, ",") .. ";" .. (payload or "") .. "\27\\"
    self.frame = {}
  elseif keys.a or not keys.m then
    return
  end
  if not self.frame then
    return
  end
  self.frame[#self.frame + 1] = sequence
  if keys.m ~= "1" then
    self.graphics(table.concat(self.frame))
    self.frame = nil
    self.placed(self.frame_cols, self.frame_rows)
  end
end

---@param data string
function Transport:feed(data)
  self.pending = self.pending .. data
  while self.pending ~= "" do
    local s = self.pending
    local esc = s:find("\27", 1, true)
    if not esc then
      self.output(s)
      self.pending = ""
      return
    end
    if esc > 1 then
      self.output(s:sub(1, esc - 1))
      self.pending = s:sub(esc)
    else
      if #s < 2 then
        return
      end
      local kind = s:sub(2, 2)
      local last
      if kind == "_" or kind == "]" or kind == "P" or kind == "^" or kind == "X" then
        local st = s:find("\27\\", 3, true)
        local bel = kind == "]" and s:find("\7", 3, true) or nil
        last = bel and (not st or bel < st) and bel or st and st + 1
      elseif kind == "[" then
        last = s:find("[@-~]", 3)
      else
        last = 2
      end
      if not last then
        return
      end
      local seq = s:sub(1, last)
      self.pending = s:sub(last + 1)
      if seq:sub(1, 3) == "\27_G" then
        self:kitty(seq)
      elseif seq == "\27[16t" then
        self.input(("\27[6;%d;%dt"):format(self.cell[2], self.cell[1]))
      elseif seq == "\27[14t" then
        self.input(("\27[4;%d;%dt"):format(self.rows * self.cell[2], self.cols * self.cell[1]))
      else
        self.output(seq)
      end
    end
  end
end

return M

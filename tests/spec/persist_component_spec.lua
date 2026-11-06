local MiniTest = require("mini.test")
local persist = require("jove.persist")

local buffers = {}
local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      for _, buf in ipairs(buffers) do
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
      buffers = {}
    end,
  },
})

T["export"] = MiniTest.new_set()

T["export"]["non-jove buffer: silent no-op"] = function()
  local scratch = vim.api.nvim_create_buf(false, true)
  buffers[#buffers + 1] = scratch
  MiniTest.expect.equality(persist.export(scratch, nil), false)
end

return T

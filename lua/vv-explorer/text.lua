-- vv-explorer 用户可见文本的轻量格式化

local M = {}

---@param count integer
---@return string
function M.items(count)
  return ('%d %s'):format(count, count == 1 and 'item' or 'items')
end

return M

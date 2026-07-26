-- 文件传输原语：统一保护自包含目录并生成不覆盖现有文件的目标路径

local Fs = require('vv-utils.fs')

local M = {}

---@param paths string[]
---@param dest_dir string
---@param mode 'cut'|'copy'
---@return { last_dest: string?, completed: integer, failed: string[] }
function M.apply(paths, dest_dir, mode)
  local result = {
    last_dest = nil,
    completed = 0,
    failed = {},
  }

  for _, source in ipairs(paths) do
    if dest_dir == source or dest_dir:sub(1, #source + 1) == source .. '/' then
      result.failed[#result.failed + 1] = 'skip: ' .. source .. ' → inside itself'
      goto continue
    end

    local dest = Fs.unique_dest(dest_dir .. '/' .. vim.fs.basename(source))
    local ok, err = pcall(function()
      if mode == 'cut' then
        Fs.rename(source, dest)
        Fs.sync_buffers(source, dest)
      else
        Fs.copy(source, dest)
      end
    end)
    if ok then
      result.last_dest = dest
      result.completed = result.completed + 1
    else
      result.failed[#result.failed + 1] = tostring(err)
    end

    ::continue::
  end

  return result
end

return M

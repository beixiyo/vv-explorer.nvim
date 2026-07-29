-- filter prompt 的路径候选
--
-- 复用 explorer 已构建且遵守当前 hidden/ignored/custom 策略的索引，不重新扫描磁盘

local Filter = require('vv-explorer.filter')
local PathCompletion = require('vv-utils.path_completion')

local M = {}

---@param state table
---@return VVCompletionDescriptor
function M.descriptor(state)
  return {
    trigger_characters = { '/', '.', ',', '!', '\\' },
    enabled = function()
      local current = state.filter
      return current and current.active and (current.mode == 'fuzzy' or current.mode == 'glob')
    end,
    complete = function(context, defaults)
      local current = state.filter
      if not current or not current.active or current.mode == 'regex' then return nil end
      if not current.index or context.line == '' then return { start_col = 0, items = {} } end

      local rels = current.index_rels
      if not rels then
        rels = Filter.build_rels(current.index, state.root.path)
        current.index_rels = rels
      end

      if current.mode == 'glob' then
        local result = PathCompletion.glob_from_paths(context.line, rels, {
          cursor = context.cursor[2],
          max_items = defaults.max_items,
          is_directory = function(relative)
            local absolute = vim.fs.joinpath(state.root.path, relative)
            return current.is_dir_map and current.is_dir_map[absolute] == true
          end,
        })
        for index, item in ipairs(result.items) do item.rank = index end
        result.pre_filtered = true
        return result
      end

      local matched = Filter.match(
        current.index,
        rels,
        state.root.path,
        context.line,
        current.mode,
        defaults.max_items
      )
      local items = {}
      for index, relative in ipairs(matched.rels) do
        local absolute = matched.abs[index]
        local directory = current.is_dir_map and current.is_dir_map[absolute] == true
        items[#items + 1] = {
          word = relative .. (directory and '/' or ''),
          abbr = relative .. (directory and '/' or ''),
          kind = directory and 'Folder' or 'File',
          rank = index,
        }
      end

      return {
        start_col = 0,
        items = items,
        pre_filtered = true,
      }
    end,
  }
end

return M

-- 拖放 action：接收已解析路径并更新 explorer 视图

local Tree = require('vv-explorer.tree')
local Render = require('vv-explorer.render')
local Transfer = require('vv-explorer.actions.transfer')

local M = {}

---@param Actions table
---@param H table
---@param context table
function M.attach(Actions, H, context)
  ---@param state table
  ---@param paths string[]
  ---@param dest_dir string
  function Actions.drop_into(state, paths, dest_dir)
    H.ensure_state_fields(state)
    local result = Transfer.apply(paths, dest_dir, 'copy')

    if #result.failed > 0 then
      vim.notify('vv-explorer: drop errors:\n' .. table.concat(result.failed, '\n'), vim.log.levels.ERROR)
    elseif result.completed > 0 then
      vim.notify(('Dropped %d item(s) → %s'):format(result.completed, vim.fn.fnamemodify(dest_dir, ':.')))
    end

    context.after_fs_change(state)
    if result.last_dest then
      Tree.expand_to(state.root, result.last_dest)
      Render.render(state)
      H.focus_path(state, result.last_dest)
    end
  end

  ---@param state table
  ---@param paths string[]
  function Actions.drop_paste(state, paths)
    local node = H.node_under_cursor(state)
    Actions.drop_into(state, paths, context.dir_context(state, node))
  end
end

return M

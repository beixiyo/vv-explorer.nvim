-- 文件操作组合层：共享上下文只包含无状态函数，具体行为由子模块负责

local Tree = require('vv-explorer.tree')
local Render = require('vv-explorer.render')
local Chain = require('vv-explorer.actions.chain')

local M = {}

---@param Actions table
---@param H table
function M.attach(Actions, H)
  ---@param state table
  ---@param node table?
  ---@return string path
  local function dir_context(state, node)
    if not node or node == state.root then return state.root.path end
    if node.is_dir then return node.path end
    return vim.fs.dirname(node.path)
  end

  ---@param state table
  local function after_fs_change(state)
    Tree.refresh(state.root)
    state.selection = {}
    Chain.reset(state)
    H.invalidate_filter_index(state)
    if state.git and state.git.refresh then state.git.refresh() end
    Render.render(state)
  end

  local context = {
    after_fs_change = after_fs_change,
    dir_context = dir_context,
    target_node = function(state) return Chain.target_node(state, H) end,
  }

  Chain.attach(Actions, H)
  require('vv-explorer.actions.mutations').attach(Actions, H, context)
  require('vv-explorer.actions.clipboard').attach(Actions, H, context)
  require('vv-explorer.actions.drop').attach(Actions, H, context)
end

return M

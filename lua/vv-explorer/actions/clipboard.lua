-- 剪贴板：cut/copy 标记与 paste 生命周期

local Tree = require('vv-explorer.tree')
local Render = require('vv-explorer.render')
local Transfer = require('vv-explorer.actions.transfer')
local Text = require('vv-explorer.text')

local M = {}

---@param Actions table
---@param H table
---@param context table
function M.attach(Actions, H, context)
  ---@param state table
  ---@param mode 'cut'|'copy'
  local function mark(state, mode)
    H.ensure_state_fields(state)
    local node = context.target_node(state)
    local selected = H.selected_paths(state)

    if #selected > 0 then
      state.clipboard = { mode = mode, paths = selected }
      state.selection = {}
    elseif node and node ~= state.root then
      local path = node.path
      local clipboard = state.clipboard
      if clipboard and clipboard.mode == mode then
        local found
        for index, current in ipairs(clipboard.paths) do
          if current == path then
            found = index
            break
          end
        end

        if found then
          table.remove(clipboard.paths, found)
          if #clipboard.paths == 0 then state.clipboard = nil end
        else
          clipboard.paths[#clipboard.paths + 1] = path
        end
      else
        state.clipboard = { mode = mode, paths = { path } }
      end
    else
      return
    end

    Render.render(state)
    local label = mode == 'cut' and 'Cut' or 'Copy'
    local count = state.clipboard and #state.clipboard.paths or 0
    if count > 0 then vim.notify(('%s %s'):format(label, Text.items(count))) end
  end

  function Actions.cut_mark(state) mark(state, 'cut') end
  function Actions.copy_mark(state) mark(state, 'copy') end

  function Actions.paste(state)
    H.ensure_state_fields(state)
    if not state.clipboard or #state.clipboard.paths == 0 then
      vim.notify('vv-explorer: clipboard empty', vim.log.levels.WARN)
      return
    end

    local dest_dir = context.dir_context(state, context.target_node(state))
    local mode = state.clipboard.mode
    local result = Transfer.apply(state.clipboard.paths, dest_dir, mode)

    if #result.failed > 0 then
      vim.notify('vv-explorer: paste errors:\n' .. table.concat(result.failed, '\n'), vim.log.levels.ERROR)
    end
    if result.last_dest then state.clipboard = nil end

    context.after_fs_change(state)
    if result.last_dest then
      Tree.expand_to(state.root, result.last_dest)
      Render.render(state)
      H.focus_path(state, result.last_dest)
    end
  end
end

return M

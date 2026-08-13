-- 确认动作生命周期回归：删除 A→B→A、latest-wins 与源窗口关闭

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local utils = vim.fn.fnamemodify(root, ':h') .. '/vv-utils.nvim'
package.path = utils .. '/lua/?.lua;' .. utils .. '/lua/?/init.lua;' .. root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local confirmations = {}
package.preload['vv-utils.confirm'] = function()
  return {
    open = function(opts)
      local confirmation = { opts = opts, close_count = 0 }
      confirmations[#confirmations + 1] = confirmation
      return {
        close = function()
          confirmation.close_count = confirmation.close_count + 1
        end,
      }
    end,
  }
end

package.preload['vv-explorer.tree'] = function()
  return { refresh = function() end }
end
package.preload['vv-explorer.render'] = function()
  return { render = function() end }
end
package.preload['vv-explorer.preview'] = function()
  return { clear_if_deleted = function() end }
end
package.preload['vv-explorer.trash'] = function()
  return {
    enabled = function() return false end,
    trash = function() error('trash should not be used') end,
  }
end
package.preload['vv-explorer.lsp'] = function()
  return { will_rename_clients = function() return {} end, did_rename = function() end }
end
package.preload['vv-utils.loading'] = function()
  return { start = function() return function() end end }
end

local calls = { refresh = 0 }
local Actions = {}
local Helpers = {
  node_under_cursor = function(state) return state.cursor_node end,
  row_under_cursor = function() return {} end,
  selected_paths = function(state) return state.selected_paths or {} end,
  ensure_state_fields = function(state) state.selection = state.selection or {} end,
}
local context = {
  target_node = function(state) return state.cursor_node end,
  dir_context = function(state) return state.root.path end,
  after_fs_change = function() calls.refresh = calls.refresh + 1 end,
}
require('vv-explorer.actions.mutations').attach(Actions, Helpers, context)

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(('%s: expected %s, got %s'):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local temporary = vim.fn.tempname()
assert(vim.fn.mkdir(temporary .. '/a', 'p') == 1, 'root A should be created')
assert(vim.fn.mkdir(temporary .. '/b', 'p') == 1, 'root B should be created')
local target = temporary .. '/a/target.txt'
vim.fn.writefile({ 'payload' }, target)

local source_buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, source_buffer)
local state = {
  buf = source_buffer,
  win = vim.api.nvim_get_current_win(),
  root = { path = temporary .. '/a' },
  cursor_node = { path = target, name = 'target.txt' },
  selection = {},
}

-- A→B→A 必须拒绝旧确认，即使路径最终又回到 A
Actions.delete(state)
local root_stale = confirmations[#confirmations]
state.root = { path = temporary .. '/b' }
state.root = { path = temporary .. '/a' }
root_stale.opts.on_confirm()
assert(vim.fn.filereadable(target) == 1, 'A→B→A must not execute the old delete confirmation')
assert_equal(calls.refresh, 0, 'stale root confirmation must not refresh the explorer')

-- owner 持有的 handle 也必须走统一 cancel，重复 close 不得重复清理
Actions.delete(state)
local directly_closed = confirmations[#confirmations]
local owned_handle = state._confirm_handle
owned_handle.close()
owned_handle.close()
assert_equal(directly_closed.close_count, 1, 'owned confirmation handle close must be idempotent')

-- 连续打开确认必须关闭旧 handle、清理旧 watcher，旧 callback 不能落地
Actions.delete(state)
local first = confirmations[#confirmations]
Actions.delete(state)
local second = confirmations[#confirmations]
assert_equal(first.close_count, 1, 'opening a newer confirmation must close the old handle once')
first.opts.on_confirm()
assert(vim.fn.filereadable(target) == 1, 'superseded delete callback must be ignored')
second.opts.on_cancel()
second.opts.on_cancel()
assert_equal(second.close_count, 0, 'cancel callback must not close an already closed confirmation')

-- 关闭源窗口必须取消确认；重复触发旧 callback 仍不得删除文件
local base_window = vim.api.nvim_get_current_win()
vim.cmd('vsplit')
local source_window = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(source_window, source_buffer)
state.win = source_window
Actions.delete(state)
local window_stale = confirmations[#confirmations]
vim.api.nvim_set_current_win(base_window)
vim.api.nvim_win_close(source_window, true)
window_stale.opts.on_confirm()
assert(vim.fn.filereadable(target) == 1, 'closed source window must cancel the delete confirmation')
assert_equal(window_stale.close_count, 1, 'source-window cancellation must close the confirmation once')

vim.api.nvim_win_set_buf(base_window, source_buffer)
state.win = base_window
vim.fn.delete(temporary, 'rf')
print('vv-explorer confirmation lifecycle: PASS')

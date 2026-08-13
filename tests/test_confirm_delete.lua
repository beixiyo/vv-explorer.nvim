-- 删除确认的行为回归测试
-- 运行：nvim --headless -u NONE -l tests/test_confirm_delete.lua

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local utils = vim.fn.fnamemodify(root, ':h') .. '/vv-utils.nvim'
package.path = utils .. '/lua/?.lua;' .. utils .. '/lua/?/init.lua;' .. root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local pending
package.preload['vv-utils.confirm'] = function()
  return {
    open = function(opts)
      pending = opts
      return { close = function() end }
    end,
  }
end

local calls = { refresh = 0, render = 0, after_fs_change = 0 }
package.preload['vv-explorer.tree'] = function()
  return { refresh = function() calls.refresh = calls.refresh + 1 end }
end
package.preload['vv-explorer.render'] = function()
  return { render = function() calls.render = calls.render + 1 end }
end
package.preload['vv-explorer.preview'] = function()
  return { clear_if_deleted = function() end }
end
package.preload['vv-explorer.trash'] = function()
  return {
    enabled = function() return false end,
    trash = function() error('trash should not be used in permanent-delete tests') end,
  }
end
package.preload['vv-explorer.lsp'] = function()
  return { will_rename_clients = function() return {} end, did_rename = function() end }
end
package.preload['vv-utils.loading'] = function()
  return { start = function() return function() end end }
end

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
  after_fs_change = function() calls.after_fs_change = calls.after_fs_change + 1 end,
}
require('vv-explorer.actions.mutations').attach(Actions, Helpers, context)

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(('%s: expected %s, got %s'):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function invoke_mapping(buffer, lhs)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buffer, 'n')) do
    if mapping.lhs == lhs then
      assert(type(mapping.callback) == 'function', 'buffer mapping should expose its Lua callback')
      mapping.callback()
      return
    end
  end
  error('mapping not found: ' .. lhs)
end

local temporary = vim.fn.tempname()
assert(vim.fn.mkdir(temporary, 'p') == 1, 'temporary directory should be created')
local target = temporary .. '/target.txt'
vim.fn.writefile({ 'original' }, target)

local source_buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, source_buffer)
local state = {
  buf = source_buffer,
  win = vim.api.nvim_get_current_win(),
  root = { path = temporary },
  cursor_node = { path = target, name = 'target.txt' },
  selection = {},
}

-- 取消必须保持目标和 explorer 状态不变
Actions.delete(state)
assert(pending and type(pending.on_confirm) == 'function', 'delete should open a confirmation')
pending.on_cancel()
assert(vim.fn.filereadable(target) == 1, 'cancelled delete must not remove the target')
assert_equal(calls.after_fs_change, 0, 'cancelled delete must not refresh the explorer')

-- 未变化的目标在确认后执行
Actions.delete(state)
pending.on_confirm()
assert(vim.fn.filereadable(target) == 0, 'confirmed delete should remove the target')
assert_equal(calls.after_fs_change, 1, 'confirmed delete should refresh the explorer')

-- 确认等待期间被替换的同一路径必须拒绝，不能删掉 replacement
vim.fn.writefile({ 'original again' }, target)
Actions.delete(state)
vim.fn.delete(target)
vim.fn.writefile({ 'replacement' }, target)
pending.on_confirm()
assert(vim.deep_equal(vim.fn.readfile(target), { 'replacement' }), 'stale delete must preserve the replacement target')
assert_equal(calls.after_fs_change, 1, 'stale delete must not refresh the explorer')

-- 下面的测试使用真实回收站 store，只替换确认适配，验证 entry 身份和整箱快照
package.loaded['vv-explorer.trash.panel'] = nil
package.loaded['vv-explorer.trash.store'] = nil
local Panel = require('vv-explorer.trash.panel')
local Store = require('vv-explorer.trash.store')
local Fs = require('vv-utils.fs')

local trash_dir = temporary .. '/trash'
local source = temporary .. '/source.txt'
vim.fn.writefile({ 'trash payload' }, source)
local store = Store.new({ enabled = true, max_items = 50, warn_size_mb = 500, scan_on_open = false }, trash_dir)
store:trash({ source })

Panel.open(store)
local panel_buffer = vim.api.nvim_get_current_buf()
invoke_mapping(panel_buffer, 'd')
assert(pending and type(pending.on_cancel) == 'function', 'permanent delete should open a confirmation')
pending.on_cancel()
assert(#store:list() == 1, 'cancelled permanent delete must keep the trash entry')

Panel.open(store)
panel_buffer = vim.api.nvim_get_current_buf()
invoke_mapping(panel_buffer, 'd')
local original_entry = assert(store:list()[1])
Fs.delete(original_entry.trash_path)
vim.fn.writefile({ 'replacement payload' }, original_entry.trash_path)
pending.on_confirm()
assert(Fs.exists(original_entry.trash_path), 'stale permanent delete must preserve a replacement payload')
assert(#store:list() == 1, 'stale permanent delete must keep the entry')

-- 重新建立一份正常 entry，确认永久删除确实执行
Fs.delete(original_entry.trash_path)
pcall(Fs.delete, original_entry.meta_path)
local second_source = temporary .. '/second.txt'
vim.fn.writefile({ 'second payload' }, second_source)
store:trash({ second_source })
Panel.open(store)
panel_buffer = vim.api.nvim_get_current_buf()
invoke_mapping(panel_buffer, 'd')
pending.on_confirm()
assert(#store:list() == 0, 'confirmed permanent delete should remove the selected entry')

-- 清空确认期间有新 entry 加入时，整箱操作必须拒绝
local third_source = temporary .. '/third.txt'
vim.fn.writefile({ 'third payload' }, third_source)
store:trash({ third_source })
Panel.open(store)
panel_buffer = vim.api.nvim_get_current_buf()
invoke_mapping(panel_buffer, 'D')
local fourth_source = temporary .. '/fourth.txt'
vim.fn.writefile({ 'fourth payload' }, fourth_source)
store:trash({ fourth_source })
pending.on_confirm()
assert(#store:list() == 2, 'stale empty-trash confirmation must preserve all entries')

-- 无变化时确认清空，两个 entry 都应被删除
Panel.open(store)
panel_buffer = vim.api.nvim_get_current_buf()
invoke_mapping(panel_buffer, 'D')
pending.on_confirm()
assert(#store:list() == 0, 'confirmed empty-trash should remove the captured entries')

if vim.api.nvim_win_is_valid(vim.api.nvim_get_current_win()) then
  pcall(vim.api.nvim_win_close, vim.api.nvim_get_current_win(), true)
end
vim.fn.delete(temporary, 'rf')
print('vv-explorer confirm delete: PASS')

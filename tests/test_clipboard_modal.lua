-- 粘贴冲突集成：真实 Modal 选择、完整覆盖与过期剪贴板保护

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local utils = vim.fn.fnamemodify(root, ':h') .. '/vv-utils.nvim'
vim.opt.runtimepath:prepend(utils)
vim.opt.runtimepath:prepend(root)

local shared_record
package.preload['vv-utils.state'] = function()
  return {
    register = function()
      return {
        get = function() return vim.deepcopy(shared_record) end,
        set = function(_, _, value) shared_record = vim.deepcopy(value) return true end,
        remove = function() shared_record = nil return true end,
        compare_and_set = function(_, _, expected, value)
          if not vim.deep_equal(shared_record, expected) then return false, vim.deepcopy(shared_record) end
          shared_record = vim.deepcopy(value)
          return true, vim.deepcopy(shared_record)
        end,
      }
    end,
  }
end
package.preload['vv-explorer.render'] = function()
  return { render = function() end }
end
package.preload['vv-explorer.tree'] = function()
  return { expand_to = function() end }
end

local ClipboardStore = require('vv-explorer.clipboard_store')
local Clipboard = require('vv-explorer.actions.clipboard')
local Fs = require('vv-utils.fs')

local Actions = {}
local Helpers = {
  ensure_state_fields = function() end,
  selected_paths = function() return {} end,
  focus_path = function() end,
}
local changed = 0
local context = {
  target_node = function(state) return state.root end,
  dir_context = function(_, node) return node.path end,
  after_fs_change = function() changed = changed + 1 end,
}
Clipboard.attach(Actions, Helpers, context)

local temporary = vim.fn.tempname()
local source_root = temporary .. '/source'
local destination_root = temporary .. '/destination'
assert(vim.fn.mkdir(source_root .. '/widget', 'p') == 1)
assert(vim.fn.mkdir(destination_root .. '/widget', 'p') == 1)
vim.fn.writefile({ 'new' }, source_root .. '/widget/shared.txt')
vim.fn.writefile({ 'source-only' }, source_root .. '/widget/source-only.txt')
vim.fn.writefile({ 'old' }, destination_root .. '/widget/shared.txt')
vim.fn.writefile({ 'destination-only' }, destination_root .. '/widget/destination-only.txt')

local explorer_buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, explorer_buffer)
local state = {
  root = { path = destination_root, name = 'destination', is_dir = true },
  buf = explorer_buffer,
  win = vim.api.nvim_get_current_win(),
  opts = { clipboard = { conflict = 'prompt' } },
}

assert(ClipboardStore.write('copy', { source_root .. '/widget' }))
Actions.paste(state)
local modal_window = vim.api.nvim_get_current_win()
assert(modal_window ~= state.win, 'conflicting paste should open a Modal')
local modal_buffer = vim.api.nvim_win_get_buf(modal_window)
assert(vim.bo[modal_buffer].filetype == 'vv-modal',
  'paste conflict should use vv-utils.modal')
local modal_text = table.concat(vim.api.nvim_buf_get_lines(modal_buffer, 0, -1, false), '\n')
assert(modal_text:find('%^o'), 'Modal should normalize <C-o> as ^o')
assert(modal_text:find('%^k'), 'Modal should normalize <C-k> as ^k')
vim.api.nvim_feedkeys(vim.keycode('<C-o>'), 'xt', false)

assert(changed == 1, 'Overwrite action should report one filesystem change')
assert(vim.fn.readfile(destination_root .. '/widget/shared.txt')[1] == 'new',
  'Overwrite action should install source content')
assert(vim.fn.filereadable(destination_root .. '/widget/destination-only.txt') == 0,
  'Overwrite action should replace the complete directory instead of merging')
assert(shared_record == nil, 'successful copy paste should clear the shared clipboard')

assert(ClipboardStore.write('copy', { source_root .. '/widget' }))
Actions.paste(state)
vim.api.nvim_feedkeys(vim.keycode('<C-k>'), 'xt', false)
assert(changed == 2, 'Keep Both action should report one more filesystem change')
assert(vim.fn.readfile(destination_root .. '/widget (copy)/shared.txt')[1] == 'new',
  'Keep Both action should create an incremented sibling')

vim.fn.writefile({ 'newer source' }, source_root .. '/widget/shared.txt')
vim.fn.writefile({ 'current destination' }, destination_root .. '/widget/shared.txt')
assert(ClipboardStore.write('copy', { source_root .. '/widget' }))
Actions.paste(state)
assert(ClipboardStore.write('copy', { source_root .. '/widget/source-only.txt' }))
vim.api.nvim_feedkeys(vim.keycode('<C-o>'), 'xt', false)

assert(changed == 2, 'a stale Modal must not execute a filesystem change')
assert(vim.fn.readfile(destination_root .. '/widget/shared.txt')[1] == 'current destination',
  'a stale Modal must preserve the current destination')

local partial_source_a = source_root .. '/partial-a.txt'
local partial_source_b = source_root .. '/partial-b.txt'
vim.fn.writefile({ 'partial a' }, partial_source_a)
vim.fn.writefile({ 'partial b' }, partial_source_b)
assert(ClipboardStore.write('copy', { partial_source_a, partial_source_b }))
local original_copy = Fs.copy
local partial_source_a_normalized = vim.fs.normalize(vim.fn.fnamemodify(partial_source_a, ':p'))
Fs.copy = function(source_path, destination_path)
  local copied = original_copy(source_path, destination_path)
  if source_path == partial_source_a_normalized then
    vim.fn.writefile({ 'changed after planning' }, partial_source_b)
  end
  return copied
end
Actions.paste(state)
Fs.copy = original_copy
assert(changed == 3, 'a partial paste should report the completed filesystem change')
assert(vim.fn.readfile(destination_root .. '/partial-a.txt')[1] == 'partial a',
  'the completed source must still be pasted')
assert(vim.fn.filereadable(destination_root .. '/partial-b.txt') == 0,
  'the stale source must not be pasted')
assert(shared_record == nil,
  'a copy must clear its shared clipboard after the first successful paste, including partial success')

-- cut 部分成功仍保留失败项，不能随 copy 的一次性语义一起清空
local cut_record = assert(ClipboardStore.write('cut', { partial_source_a, partial_source_b }))
assert(vim.uv.fs_unlink(partial_source_b))
Actions.paste(state)
vim.api.nvim_feedkeys(vim.keycode('<C-k>'), 'xt', false)
assert(vim.fn.filereadable(partial_source_a) == 0, 'the successful cut must move its source')
assert(shared_record and shared_record.mode == 'cut' and shared_record.owner_id == cut_record.owner_id,
  'partial cut must preserve the original owner')
assert(vim.deep_equal(shared_record.paths, { partial_source_b }),
  'partial cut must retain only failed source paths')

vim.fn.delete(temporary, 'rf')
print('vv-explorer clipboard modal: PASS')

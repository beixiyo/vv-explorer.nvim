-- actions facade 的行为回归测试
-- 运行：nvim --headless -u NONE -l tests/test_actions.lua

local root = vim.fn.getcwd()
local utils = vim.fn.fnamemodify(root, ':h') .. '/vv-utils.nvim'
package.path = utils .. '/lua/?.lua;' .. utils .. '/lua/?/init.lua;' .. root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local calls = {
  copy = {},
  expand = {},
  focus = {},
  rename = {},
  sync = {},
  refresh = 0,
  render = 0,
}
local shared_record
local state_subscriber
local unsubscribe_count = 0

local Helpers = {}

function Helpers.node_under_cursor(state) return state.cursor_node end
function Helpers.row_under_cursor(state) return state.row end
function Helpers.row_at_line(state) return state.row end
function Helpers.selected_paths(state) return state.selected_paths or {} end
function Helpers.ensure_state_fields(state) state.selection = state.selection or {} end
function Helpers.invalidate_filter_index() end
function Helpers.focus_path(_, path) calls.focus[#calls.focus + 1] = path end
function Helpers.node_at_line() end
function Helpers.find_row() end
function Helpers.expand_to_file() end

package.preload['vv-explorer.actions.helpers'] = function() return Helpers end
package.preload['vv-explorer.actions.navigation'] = function()
  return {
    attach = function(Actions)
      function Actions.open() end
    end,
  }
end
package.preload['vv-explorer.actions.filter'] = function()
  return { attach = function() end }
end
package.preload['vv-explorer.tree'] = function()
  return {
    refresh = function() calls.refresh = calls.refresh + 1 end,
    expand_to = function(_, path) calls.expand[#calls.expand + 1] = path end,
  }
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
    trash = function() return { trashed = {}, failed = {} } end,
  }
end
package.preload['vv-explorer.lsp'] = function()
  return {
    will_rename_clients = function() return {} end,
    did_rename = function() end,
  }
end
package.preload['vv-utils.loading'] = function()
  return { start = function() return function() end end }
end
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
        subscribe = function(_, _, callback)
          state_subscriber = callback
          local active = true
          return function()
            if not active then return end
            active = false
            unsubscribe_count = unsubscribe_count + 1
            state_subscriber = nil
          end
        end,
      }
    end,
  }
end
package.preload['vv-utils.modal'] = function()
  return { open = function() error('modal should not open in this test') end }
end
local RealFs = require('vv-utils.fs')
package.loaded['vv-utils.fs'] = {
  unique_dest = RealFs.unique_dest,
  copy = function(source, dest)
    calls.copy[#calls.copy + 1] = { source = source, dest = dest }
    return RealFs.copy(source, dest)
  end,
  rename = function(source, dest)
    calls.rename[#calls.rename + 1] = { source = source, dest = dest }
    return RealFs.rename(source, dest)
  end,
  sync_buffers = function(source, dest)
    calls.sync[#calls.sync + 1] = { source = source, dest = dest }
  end,
  mkdir_p = RealFs.mkdir_p,
  create_file = RealFs.create_file,
  delete = RealFs.delete,
  realpath = RealFs.realpath,
  exists = RealFs.exists,
}

vim.notify = function() end

local Actions = require('vv-explorer.actions')

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(('%s: expected %s, got %s'):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local root_node = { path = '/project', name = 'project', is_dir = true }
local first = { path = '/project/a', name = 'a', is_dir = true, parent = root_node }
local second = { path = '/project/a/b', name = 'b', is_dir = true, parent = first }
local tip = { path = '/project/a/b/c', name = 'c', is_dir = true, parent = second }
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, buf)

local state = {
  root = root_node,
  cursor_node = tip,
  row = { group_chain = { 'a', 'b', 'c' } },
  buf = buf,
  win = vim.api.nvim_get_current_win(),
  name_cols = { [1] = 0 },
  selection = {},
  opts = { clipboard = { conflict = 'increment' } },
}

Actions.copy_mark(state)
assert_equal(state.clipboard.paths[1], tip.path, '折叠链默认选中最深节点')

Actions.subscribe_clipboard(state)
local renders_before_remote_clear = calls.render
shared_record = nil
state_subscriber(nil)
assert_equal(state.clipboard, nil, '其他实例清除共享记录后应移除当前标记')
assert_equal(calls.render, renders_before_remote_clear + 1, '其他实例清除共享记录后应重新渲染')
Actions.unsubscribe_clipboard(state)
Actions.unsubscribe_clipboard(state)
assert_equal(unsubscribe_count, 1, '剪贴板订阅释放必须幂等')

state.clipboard = nil
Actions.chain_select_shallower(state)
Actions.copy_mark(state)
assert_equal(state.clipboard.paths[1], second.path, '折叠链向浅一层后操作对应真实节点')

state.clipboard = { mode = 'copy', paths = { first.path } }
shared_record = { version = 1, id = 'self', mode = 'copy', paths = { first.path }, created_at = 1 }
Actions.paste(state)
assert_equal(#calls.copy, 0, '不能把目录复制到自身子树')
assert_equal(state.clipboard.paths[1], first.path, '全部粘贴失败时保留剪贴板')

state.cursor_node = root_node
state.row = {}
local temporary = vim.fn.tempname()
assert(vim.fn.mkdir(temporary .. '/project', 'p') == 1)
vim.fn.writefile({ 'source' }, temporary .. '/source.txt')
vim.fn.writefile({ 'existing' }, temporary .. '/project/source.txt')
state.root = { path = temporary .. '/project', name = 'project', is_dir = true }
state.cursor_node = state.root
shared_record = {
  version = 1,
  id = 'copy',
  mode = 'copy',
  paths = { temporary .. '/source.txt' },
  created_at = 1,
}
Actions.paste(state)
assert_equal(#calls.copy, 1, '合法粘贴执行一次复制')
assert(calls.copy[1].dest:match('/project/%.source %(copy%).txt%.vv%-explorer%-stage%-'),
  '合法粘贴应先复制到目标旁的隐藏 staging 路径')
assert_equal(calls.rename[#calls.rename].dest, temporary .. '/project/source (copy).txt',
  '合法粘贴应原子发布到唯一目标路径')
assert_equal(state.clipboard, nil, '复制粘贴成功后清除共享剪贴板')
assert_equal(calls.focus[#calls.focus], temporary .. '/project/source (copy).txt', '粘贴成功后聚焦目标')

vim.fn.writefile({ 'move' }, temporary .. '/move.txt')
shared_record = {
  version = 1,
  id = 'cut',
  mode = 'cut',
  paths = { temporary .. '/move.txt' },
  created_at = 1,
}
Actions.paste(state)
assert_equal(calls.rename[#calls.rename].source, temporary .. '/move.txt', '剪切粘贴移动原始来源')
assert_equal(calls.rename[#calls.rename].dest, temporary .. '/project/move.txt', '剪切粘贴发布到目标路径')
assert_equal(#calls.sync, 1, '剪切粘贴同步已加载 buffer 路径')

vim.fn.writefile({ 'drop' }, temporary .. '/drop.txt')
vim.fn.writefile({ 'existing drop' }, temporary .. '/project/drop.txt')
Actions.drop_into(state, { state.root.path, temporary .. '/drop.txt' }, state.root.path)
assert_equal(#calls.copy, 2, '拖放跳过目标目录自身并继续复制其他文件')
assert_equal(calls.rename[#calls.rename].dest, temporary .. '/project/drop (copy).txt', '拖放同样发布到唯一目标路径')

vim.fn.delete(temporary, 'rf')

print('vv-explorer actions: PASS')

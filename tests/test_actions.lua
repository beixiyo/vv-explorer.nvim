-- actions facade 的行为回归测试
-- 运行：nvim --headless -u NONE -l tests/test_actions.lua

local root = vim.fn.getcwd()
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local calls = {
  copy = {},
  expand = {},
  focus = {},
  rename = {},
  sync = {},
  refresh = 0,
  render = 0,
}

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
package.preload['vv-utils.fs'] = function()
  return {
    unique_dest = function(path) return path .. '.copy' end,
    copy = function(source, dest)
      calls.copy[#calls.copy + 1] = { source = source, dest = dest }
    end,
    rename = function(source, dest)
      calls.rename[#calls.rename + 1] = { source = source, dest = dest }
    end,
    sync_buffers = function(source, dest)
      calls.sync[#calls.sync + 1] = { source = source, dest = dest }
    end,
    mkdir_p = function() end,
    create_file = function() end,
    delete = function() end,
    realpath = function(path) return path end,
  }
end

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
}

Actions.copy_mark(state)
assert_equal(state.clipboard.paths[1], tip.path, '折叠链默认选中最深节点')

state.clipboard = nil
Actions.chain_select_shallower(state)
Actions.copy_mark(state)
assert_equal(state.clipboard.paths[1], second.path, '折叠链向浅一层后操作对应真实节点')

state.clipboard = { mode = 'copy', paths = { first.path } }
Actions.paste(state)
assert_equal(#calls.copy, 0, '不能把目录复制到自身子树')
assert_equal(state.clipboard.paths[1], first.path, '全部粘贴失败时保留剪贴板')

state.cursor_node = root_node
state.row = {}
state.clipboard = { mode = 'copy', paths = { '/source.txt' } }
Actions.paste(state)
assert_equal(#calls.copy, 1, '合法粘贴执行一次复制')
assert_equal(calls.copy[1].dest, '/project/source.txt.copy', '合法粘贴使用唯一目标路径')
assert_equal(state.clipboard, nil, '粘贴成功后清空剪贴板')
assert_equal(calls.focus[#calls.focus], '/project/source.txt.copy', '粘贴成功后聚焦目标')

state.clipboard = { mode = 'cut', paths = { '/move.txt' } }
Actions.paste(state)
assert_equal(#calls.rename, 1, '剪切粘贴执行移动')
assert_equal(#calls.sync, 1, '剪切粘贴同步已加载 buffer 路径')

Actions.drop_into(state, { '/project', '/drop.txt' }, '/project')
assert_equal(#calls.copy, 2, '拖放跳过目标目录自身并继续复制其他文件')
assert_equal(calls.copy[2].dest, '/project/drop.txt.copy', '拖放同样使用唯一目标路径')

print('vv-explorer actions: PASS')

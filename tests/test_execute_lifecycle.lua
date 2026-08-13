-- 执行确认生命周期回归：连续 execute、面板关闭与 root 代际校验

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

for _, name in ipairs({
  'vv-explorer.tree',
  'vv-explorer.render',
  'vv-explorer.preview.main_win',
  'vv-explorer.preview',
  'vv-explorer.trash',
  'vv-utils.editor',
  'vv-utils.fs',
  'vv-utils.scroll',
}) do
  package.preload[name] = function() return {} end
end

local confirmations = {}
package.preload['vv-utils.exec'] = function()
  return {
    resolve = function(path)
      return {
        cmd = { 'runner', path },
        runner = 'runner',
        cwd = vim.g.vv_explorer_execute_lifecycle_cwd,
        target = 'file',
      }
    end,
  }
end
package.preload['vv-explorer.execute_confirm'] = function()
  return {
    open = function(path, cwd, command, on_confirm, opts)
      local confirmation = {
        path = path,
        cwd = cwd,
        command = command,
        opts = opts,
        on_confirm = on_confirm,
        close_count = 0,
      }
      confirmations[#confirmations + 1] = confirmation
      return {
        close = function()
          confirmation.close_count = confirmation.close_count + 1
        end,
      }
    end,
  }
end

local Navigation = require('vv-explorer.actions.navigation')
local Actions = {}
Navigation.attach(Actions, {
  node_under_cursor = function(state) return state.node end,
})

local cwd = vim.fn.tempname()
assert(vim.fn.mkdir(cwd, 'p') == 1, 'execute cwd should be created')
vim.g.vv_explorer_execute_lifecycle_cwd = cwd

local source_buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, source_buffer)
local state
state = {
  buf = source_buffer,
  win = vim.api.nvim_get_current_win(),
  root = { path = cwd },
  node = { path = cwd .. '/first.lua', is_dir = false },
  opts = {
    execute = {
      run = function(_, ctx)
        state.runs = (state.runs or 0) + 1
        state.last_ctx = ctx
      end,
    },
  },
}

-- 连续 execute 使用同一个确认槽位，旧确认的回调必须成为 no-op
Actions.execute(state)
local first = confirmations[#confirmations]
state.node = { path = cwd .. '/second.lua', is_dir = false }
Actions.execute(state)
local second = confirmations[#confirmations]
assert(first ~= second, 'each execute should create a distinct confirmation request')
assert(first.close_count == 1, 'latest execute should close the previous confirmation')
first.on_confirm()
assert((state.runs or 0) == 0, 'superseded execute callback must not run')
second.on_confirm()
local function assert_equal(actual, expected, message)
  if actual ~= expected then error(('%s: expected %s, got %s'):format(message, expected, actual)) end
end
assert_equal(state.runs, 1, 'latest execute should run exactly once')
assert(state.last_ctx.path == cwd .. '/second.lua', 'latest execute should keep its source context')

-- root A→B→A 仍然是不同代际，旧执行确认不得落地
state.node = { path = cwd .. '/third.lua', is_dir = false }
Actions.execute(state)
local root_stale = confirmations[#confirmations]
state.root = { path = cwd .. '/b' }
state.root = { path = cwd }
root_stale.on_confirm()
assert(state.runs == 1, 'A→B→A must invalidate the old execute confirmation')

-- 源窗口关闭时 watcher 取消确认，即使持有的 callback 被误触发也不执行
local base_window = vim.api.nvim_get_current_win()
vim.cmd('vsplit')
local source_window = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(source_window, source_buffer)
state.win = source_window
state.node = { path = cwd .. '/fourth.lua', is_dir = false }
Actions.execute(state)
local window_stale = confirmations[#confirmations]
vim.api.nvim_set_current_win(base_window)
vim.api.nvim_win_close(source_window, true)
window_stale.on_confirm()
assert(state.runs == 1, 'closed source window must cancel execute confirmation')
assert(window_stale.close_count == 1, 'source-window cancellation must close execute confirmation once')

vim.api.nvim_win_set_buf(base_window, source_buffer)
vim.fn.delete(cwd, 'rf')
print('vv-explorer execute lifecycle: PASS')

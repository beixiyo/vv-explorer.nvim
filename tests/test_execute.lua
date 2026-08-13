-- Explorer 执行计划的 cwd 传递回归测试

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

package.preload['vv-utils.exec'] = function()
  return {
    resolve = function()
      return {
        cmd = { 'cargo', 'run' },
        runner = 'cargo',
        cwd = vim.g.vv_explorer_execute_cwd,
      }
    end,
  }
end

package.preload['vv-explorer.execute_confirm'] = function()
  return {
    open = function(_, _, _, on_confirm)
      on_confirm()
    end,
  }
end

local Navigation = require('vv-explorer.actions.navigation')
local Actions = {}
Navigation.attach(Actions, {
  node_under_cursor = function(state) return state.node end,
})

local cwd = vim.fn.tempname()
assert(vim.fn.mkdir(cwd, 'p') == 1, 'test cwd should be created')
vim.g.vv_explorer_execute_cwd = cwd
local received
Actions.execute({
  node = { path = cwd .. '/src/main.rs', is_dir = false },
  opts = {
    execute = {
      run = function(cmd, ctx)
        received = { cmd = cmd, ctx = ctx }
      end,
    },
  },
})

assert(received, 'custom runner should receive the resolved plan')
assert(vim.deep_equal(received.cmd, { 'cargo', 'run' }), 'Explorer should preserve command argv')
assert(received.ctx.cwd == cwd, 'Explorer should prefer project cwd over the source-file directory')
assert(received.ctx.runner == 'cargo', 'Explorer should preserve runner metadata')

local notifications = {}
local notify = vim.notify
vim.notify = function(message)
  notifications[#notifications + 1] = message
end

vim.g.vv_explorer_execute_cwd = cwd .. '/removed-before-confirm'
local failed_runner_called = false
Actions.execute({
  node = { path = cwd .. '/src/main.rs', is_dir = false },
  opts = {
    execute = {
      confirm = false,
      run = function()
        failed_runner_called = true
      end,
    },
  },
})
assert(not failed_runner_called, 'runner must not start with an unavailable cwd')
assert(#notifications == 1 and notifications[1]:find('working directory does not exist', 1, true),
  'unavailable cwd should be reported without throwing')

vim.g.vv_explorer_execute_cwd = cwd
local original_jobstart = vim.fn.jobstart
vim.fn.jobstart = function() return -1 end
Actions.execute({
  node = { path = cwd .. '/src/main.rs', is_dir = false },
  opts = { execute = { confirm = false } },
})
vim.fn.jobstart = original_jobstart
assert(#notifications == 2 and notifications[2]:find('could not start runner', 1, true),
  'jobstart failure should be reported without throwing')

vim.notify = notify
vim.g.vv_explorer_execute_cwd = nil
vim.fn.delete(cwd, 'd')
print('vv-explorer execute: PASS')

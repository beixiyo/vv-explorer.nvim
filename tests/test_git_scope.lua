local this = debug.getinfo(1, 'S').source:sub(2)
local plugin_root = vim.fn.fnamemodify(this, ':p:h:h')
local vendors = vim.fn.fnamemodify(plugin_root, ':h')
package.path = table.concat({
  plugin_root .. '/lua/?.lua',
  plugin_root .. '/lua/?/init.lua',
  vendors .. '/vv-utils.nvim/lua/?.lua',
  vendors .. '/vv-utils.nvim/lua/?/init.lua',
  package.path,
}, ';')

local callbacks = { status = {}, tracked = {}, ignored = {} }
local function capture(lane, root, callback)
  local item = { root = root, callback = callback, cancels = 0 }
  callbacks[lane][#callbacks[lane] + 1] = item
  return function() item.cancels = item.cancels + 1 end
end

package.loaded['vv-utils.git'] = {
  index = function(root, callback) return capture('status', root, callback) end,
  tracked = function(root, callback) return capture('tracked', root, callback) end,
  ignored_entries = function(root, callback) return capture('ignored', root, callback) end,
  make_is_ignored = function(files) return function() return files[1] end end,
  symbol_for = function() end,
}
package.loaded['vv-explorer.git'] = nil

local Git = require('vv-explorer.git')
local state = { root = { path = '/repo-a' } }
Git.attach(state)

local after_b = 0
local after_a = 0
state.root.path = '/repo-b'
state.git.refresh(function() after_b = after_b + 1 end)
state.root.path = '/repo-a'
state.git.refresh(function() after_a = after_a + 1 end)

assert(#callbacks.status == 1, 'debounce window unexpectedly started an intermediate producer')
assert(callbacks.status[1].cancels == 1, 'refresh intent did not immediately cancel old status')
assert(callbacks.tracked[1].cancels == 1 and callbacks.ignored[1].cancels == 1,
  'refresh intent did not immediately cancel old auxiliary lanes')
assert(vim.wait(1000, function() return #callbacks.status == 2 end, 10),
  'real debounce did not start the latest request')
assert(callbacks.status[2].root == '/repo-a', 'A-B-A debounce did not retain the latest root')

callbacks.status[1].callback({ status_map = { result = 'old-a' } })
assert(state.git.status_map.result == nil and after_b == 0 and after_a == 0,
  'cancelled pre-debounce request published data or after callback')
callbacks.status[2].callback({ status_map = { result = 'latest-a' } })
assert(state.git.status_map.result == 'latest-a' and after_b == 0 and after_a == 1,
  'latest debounced status did not publish exactly once')

callbacks.tracked[2].callback({ is_tracked = function() return 'latest-a' end })
callbacks.tracked[1].callback({ is_tracked = function() return 'old-a' end })
assert(state.git.is_tracked() == 'latest-a', 'cancelled tracked callback overwrote latest data')
callbacks.ignored[2].callback({ 'latest-a' }, {})
callbacks.ignored[1].callback({ 'old-a' }, {})
assert(state.git.is_ignored() == 'latest-a', 'cancelled ignored callback overwrote latest data')

state.root.path = '/repo-c'
state.git.refresh()
assert(vim.wait(1000, function() return #callbacks.status == 3 end, 10))
local old_attach_status = callbacks.status[3].callback
Git.attach(state)
old_attach_status({ status_map = { result = 'old attach' } })
assert(state.git.status_map.result == nil, 'old attach callback wrote into replacement owner')
callbacks.status[4].callback({ status_map = { result = 'c' } })
assert(state.git.status_map.result == 'c', 'replacement owner did not accept its own result')

state.root.path = '/repo-d'
state.git.refresh()
assert(vim.wait(1000, function() return #callbacks.status == 5 end, 10))
local detached_status = callbacks.status[5].callback
Git.detach(state)
detached_status({ status_map = { result = 'detached' } })
assert(state.git == nil, 'detached callback revived git state')

print('PASS: explorer git intent scope covers real debounce, ABA and owner teardown')

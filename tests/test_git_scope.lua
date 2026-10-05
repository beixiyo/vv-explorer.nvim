local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["Git 意图防抖、A→B→A 与 detach 抑制旧结果"] = function()
  child.lua_func(function()
    local root = vim.env.VV_TEST_REPO

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

    assert(#callbacks.status == 1, '防抖窗口意外启动了中间生产者')
    assert(callbacks.status[1].cancels == 1, '刷新意图未立即取消旧状态请求')
    assert(callbacks.tracked[1].cancels == 1 and callbacks.ignored[1].cancels == 1,
      '刷新意图未立即取消旧辅助通道')
    assert(vim.wait(1000, function() return #callbacks.status == 2 end, 10),
      '真实防抖未启动最新请求')
    assert(callbacks.status[2].root == '/repo-a', 'A→B→A 防抖未保留最新 root')

    callbacks.status[1].callback({ status_map = { result = 'old-a' } })
    assert(state.git.status_map.result == nil and after_b == 0 and after_a == 0,
      '防抖前已取消请求仍发布了数据或 after 回调')
    callbacks.status[2].callback({ status_map = { result = 'latest-a' } })
    assert(state.git.status_map.result == 'latest-a' and after_b == 0 and after_a == 1,
      '最新防抖状态未恰好发布一次')

    callbacks.tracked[2].callback({ is_tracked = function() return 'latest-a' end })
    callbacks.tracked[1].callback({ is_tracked = function() return 'old-a' end })
    assert(state.git.is_tracked() == 'latest-a', '取消后的 tracked 回调覆盖了最新数据')
    callbacks.ignored[2].callback({ 'latest-a' }, {})
    callbacks.ignored[1].callback({ 'old-a' }, {})
    assert(state.git.is_ignored() == 'latest-a', '取消后的 ignored 回调覆盖了最新数据')

    state.root.path = '/repo-c'
    state.git.refresh()
    assert(vim.wait(1000, function() return #callbacks.status == 3 end, 10))
    local old_attach_status = callbacks.status[3].callback
    Git.attach(state)
    old_attach_status({ status_map = { result = 'old attach' } })
    assert(state.git.status_map.result == nil, '旧 attach 回调写入了新所有者')
    callbacks.status[4].callback({ status_map = { result = 'c' } })
    assert(state.git.status_map.result == 'c', '新所有者未接受自身结果')

    state.root.path = '/repo-d'
    state.git.refresh()
    assert(vim.wait(1000, function() return #callbacks.status == 5 end, 10))
    local detached_status = callbacks.status[5].callback
    Git.detach(state)
    detached_status({ status_map = { result = 'detached' } })
    assert(state.git == nil, 'detach 后回调复活了 Git 状态')
  end)
end

return T

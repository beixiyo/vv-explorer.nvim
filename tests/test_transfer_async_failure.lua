local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["安装与清理同时抛错仍恰好完成一次并结算整批 LSP"] = function()
  child.lua_func(function()
    -- execute_async 在 commit / prepare 抛错时也必须恰好调用一次 on_done，否则调用方的 in-flight 标记会永久卡死

    -- install_move 与它的失败清理路径都抛错：模拟 Reservation.cleanup 里 TempSlot.create 出错
    local Installer = require('vv-explorer.transfer.installer')
    Installer.install_move = function() error('install boom') end
    local Reservation = require('vv-explorer.transfer.reservation')
    Reservation.cleanup = function() error('cleanup boom') end

    local Transfer = require('vv-explorer.actions.transfer')

    local temporary = vim.fn.tempname()
    assert(vim.fn.mkdir(temporary .. '/src', 'p') == 1)
    assert(vim.fn.mkdir(temporary .. '/dst', 'p') == 1)
    temporary = assert(vim.uv.fs_realpath(temporary))
    vim.fn.writefile({ 'x' }, temporary .. '/src/a.txt')
    vim.fn.writefile({ 'y' }, temporary .. '/src/b.txt')

    local function run(hooks)
      local done_count, result = 0, nil
      Transfer.execute_async(
        Transfer.plan({ temporary .. '/src/a.txt', temporary .. '/src/b.txt' }, temporary .. '/dst', 'cut'),
        'increment', hooks,
        function(r) done_count = done_count + 1; result = r end
      )
      assert(vim.wait(2000, function() return done_count > 0 end), 'commit 抛错也必须调用 on_done')
      vim.wait(50)
      assert(done_count == 1, 'on_done 必须恰好调用一次')
      return result
    end

    -- 同步 proceed 与异步 proceed 两种路径
    local sync_outcomes
    local sync_result = run({
      before_moves = function(_, proceed) proceed() end,
      after_moves = function(outcomes) sync_outcomes = outcomes end,
    })
    assert(#sync_result.failed >= 2, '每个失败条目都必须被报告')
    assert(sync_outcomes and #sync_outcomes == 2 and not sync_outcomes[1].moved and not sync_outcomes[2].moved,
      'after_moves 必须获知未发生移动以供调用方回滚')

    local async_outcomes
    run({
      before_moves = function(_, proceed) vim.defer_fn(proceed, 10) end,
      after_moves = function(outcomes) async_outcomes = outcomes end,
    })
    assert(async_outcomes and #async_outcomes == 2, '异步 proceed 也必须结算整批 after_moves')

    vim.fn.delete(temporary, 'rf')
  end)
end

return T

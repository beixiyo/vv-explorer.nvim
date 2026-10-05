local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["跨进程共享剪贴板读回、所有者退出、部分进度、订阅与 CAS 竞争"] = function()
  child.lua_func(function()
    -- 共享文件剪贴板必须能被全新的 Neovim 进程读取

    local root = vim.env.VV_TEST_REPO
    local fixture = root .. '/tests/clipboard_process_fixture.lua'
    local state_home = vim.fn.tempname()
    local payload = vim.fn.tempname()
    assert(vim.fn.mkdir(state_home, 'p') == 1)

    local function command(mode, extra_env)
      return vim.system({ vim.v.progpath, '--headless', '--clean', '-l', fixture }, {
        env = vim.tbl_extend('force', {
          XDG_STATE_HOME = state_home,
          VV_EXPLORER_CLIPBOARD_TEST_MODE = mode,
          VV_EXPLORER_CLIPBOARD_TEST_SOURCE = payload,
        }, extra_env or {}),
        text = true,
      })
    end

    local function run(mode)
      local result = command(mode):wait()
      assert(result.code == 0, ('剪贴板进程 %s 失败：%s'):format(mode, result.stderr))
    end

    local ready_path = state_home .. '/writer.ready'
    local release_path = state_home .. '/writer.release'
    local writer = command('write-hold', {
      VV_EXPLORER_CLIPBOARD_TEST_READY = ready_path,
      VV_EXPLORER_CLIPBOARD_TEST_RELEASE = release_path,
    })
    assert(vim.wait(10000, function() return vim.fn.filereadable(ready_path) == 1 end, 5),
      '剪贴板写入进程未就绪')
    run('read')
    assert(vim.fn.writefile({ 'release' }, release_path) == 0)
    local writer_result = writer:wait()
    assert(writer_result.code == 0, '剪贴板写入进程失败：' .. writer_result.stderr)
    run('empty')

    local cut_ready_path = state_home .. '/cut-owner.ready'
    local cut_release_path = state_home .. '/cut-owner.release'
    local cut_owner = command('write-cut-hold', {
      VV_EXPLORER_CLIPBOARD_TEST_READY = cut_ready_path,
      VV_EXPLORER_CLIPBOARD_TEST_RELEASE = cut_release_path,
    })
    assert(vim.wait(10000, function() return vim.fn.filereadable(cut_ready_path) == 1 end, 5),
      '剪切剪贴板所有者未就绪')

    local partial_ready_path = state_home .. '/cut-partial.ready'
    local partial_release_path = state_home .. '/cut-partial.release'
    local partial = command('partial-cut-hold', {
      VV_EXPLORER_CLIPBOARD_TEST_READY = partial_ready_path,
      VV_EXPLORER_CLIPBOARD_TEST_RELEASE = partial_release_path,
    })
    assert(vim.wait(10000, function() return vim.fn.filereadable(partial_ready_path) == 1 end, 5),
      '部分剪切消费者未就绪')
    run('read-cut-remaining')
    assert(vim.fn.writefile({ 'release' }, partial_release_path) == 0)
    local partial_result = partial:wait()
    assert(partial_result.code == 0, '部分剪切消费者失败：' .. partial_result.stderr)
    run('read-cut-remaining')
    assert(vim.fn.writefile({ 'release' }, cut_release_path) == 0)
    local cut_owner_result = cut_owner:wait()
    assert(cut_owner_result.code == 0, '剪切剪贴板所有者失败：' .. cut_owner_result.stderr)
    run('empty')

    local watch_ready_path = state_home .. '/watch.ready'
    local watch_result_path = state_home .. '/watch.result'
    local owner = command('write-watch', {
      VV_EXPLORER_CLIPBOARD_TEST_READY = watch_ready_path,
      VV_EXPLORER_CLIPBOARD_TEST_RESULT = watch_result_path,
    })
    assert(vim.wait(10000, function() return vim.fn.filereadable(watch_ready_path) == 1 end, 5),
      '剪贴板所有者订阅未就绪')
    run('clear')
    local owner_result = owner:wait()
    assert(owner_result.code == 0, '剪贴板所有者订阅失败：' .. owner_result.stderr)
    assert(vim.fn.readfile(watch_result_path)[1] == 'cleared',
      '剪贴板所有者未观察到其他 Neovim 清空记录')
    run('empty')

    run('cas-protect')
    run('owner-release-race')
    vim.fn.delete(state_home, 'rf')
  end)
end

return T

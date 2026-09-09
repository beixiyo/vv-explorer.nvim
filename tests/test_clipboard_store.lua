-- 共享文件剪贴板必须能被全新的 Neovim 进程读取

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
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
  assert(result.code == 0, ('clipboard process %s failed: %s'):format(mode, result.stderr))
end

local ready_path = state_home .. '/writer.ready'
local release_path = state_home .. '/writer.release'
local writer = command('write-hold', {
  VV_EXPLORER_CLIPBOARD_TEST_READY = ready_path,
  VV_EXPLORER_CLIPBOARD_TEST_RELEASE = release_path,
})
assert(vim.wait(10000, function() return vim.fn.filereadable(ready_path) == 1 end, 5),
  'clipboard writer did not become ready')
run('read')
assert(vim.fn.writefile({ 'release' }, release_path) == 0)
local writer_result = writer:wait()
assert(writer_result.code == 0, 'clipboard writer failed: ' .. writer_result.stderr)
run('empty')

local cut_ready_path = state_home .. '/cut-owner.ready'
local cut_release_path = state_home .. '/cut-owner.release'
local cut_owner = command('write-cut-hold', {
  VV_EXPLORER_CLIPBOARD_TEST_READY = cut_ready_path,
  VV_EXPLORER_CLIPBOARD_TEST_RELEASE = cut_release_path,
})
assert(vim.wait(10000, function() return vim.fn.filereadable(cut_ready_path) == 1 end, 5),
  'cut clipboard owner did not become ready')

local partial_ready_path = state_home .. '/cut-partial.ready'
local partial_release_path = state_home .. '/cut-partial.release'
local partial = command('partial-cut-hold', {
  VV_EXPLORER_CLIPBOARD_TEST_READY = partial_ready_path,
  VV_EXPLORER_CLIPBOARD_TEST_RELEASE = partial_release_path,
})
assert(vim.wait(10000, function() return vim.fn.filereadable(partial_ready_path) == 1 end, 5),
  'partial cut consumer did not become ready')
run('read-cut-remaining')
assert(vim.fn.writefile({ 'release' }, partial_release_path) == 0)
local partial_result = partial:wait()
assert(partial_result.code == 0, 'partial cut consumer failed: ' .. partial_result.stderr)
run('read-cut-remaining')
assert(vim.fn.writefile({ 'release' }, cut_release_path) == 0)
local cut_owner_result = cut_owner:wait()
assert(cut_owner_result.code == 0, 'cut clipboard owner failed: ' .. cut_owner_result.stderr)
run('empty')

local watch_ready_path = state_home .. '/watch.ready'
local watch_result_path = state_home .. '/watch.result'
local owner = command('write-watch', {
  VV_EXPLORER_CLIPBOARD_TEST_READY = watch_ready_path,
  VV_EXPLORER_CLIPBOARD_TEST_RESULT = watch_result_path,
})
assert(vim.wait(10000, function() return vim.fn.filereadable(watch_ready_path) == 1 end, 5),
  'clipboard owner subscription did not become ready')
run('clear')
local owner_result = owner:wait()
assert(owner_result.code == 0, 'clipboard owner subscription failed: ' .. owner_result.stderr)
assert(vim.fn.readfile(watch_result_path)[1] == 'cleared',
  'clipboard owner did not observe another Neovim clearing its record')
run('empty')

run('cas-protect')
run('owner-release-race')
vim.fn.delete(state_home, 'rf')
print('vv-explorer shared clipboard: PASS')

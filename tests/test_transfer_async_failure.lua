-- execute_async 在 commit / prepare 抛错时也必须恰好调用一次 on_done，否则调用方的 in-flight 标记会永久卡死

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ':h') .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(root)

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
  assert(vim.wait(2000, function() return done_count > 0 end), 'on_done must be called even when commit throws')
  vim.wait(50)
  assert(done_count == 1, 'on_done must be called exactly once')
  return result
end

-- 同步 proceed 与异步 proceed 两种路径
local sync_moved = {}
local sync_result = run({
  before_move = function(_, _, proceed) proceed() end,
  after_move = function(_, _, moved) sync_moved[#sync_moved + 1] = moved end,
})
assert(#sync_result.failed >= 2, 'each failed entry must be reported')
assert(#sync_moved == 2 and not sync_moved[1] and not sync_moved[2],
  'after_move must be told the move did not happen so callers can roll back')

local async_moved = {}
run({
  before_move = function(_, _, proceed) vim.defer_fn(proceed, 10) end,
  after_move = function(_, _, moved) async_moved[#async_moved + 1] = moved end,
})
assert(#async_moved == 2, 'async proceed path must also reach after_move for every entry')

vim.fn.delete(temporary, 'rf')

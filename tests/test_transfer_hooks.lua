-- Transfer.execute_async：cut 整批只等待一次外部系统（LSP），落盘必须等 proceed，且收到 increment 后的最终路径

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ':h') .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(root)

local Transfer = require('vv-explorer.actions.transfer')

local temporary = vim.fn.tempname()
assert(vim.fn.mkdir(temporary, 'p') == 1)
temporary = assert(vim.uv.fs_realpath(temporary))
local sources = temporary .. '/sources'
local destination = temporary .. '/destination'
assert(vim.fn.mkdir(sources, 'p') == 1)
assert(vim.fn.mkdir(destination, 'p') == 1)
vim.fn.writefile({ 'new' }, sources .. '/a.txt')
vim.fn.writefile({ 'new-b' }, sources .. '/b.txt')
vim.fn.writefile({ 'old' }, destination .. '/a.txt')

local function run(plan, hooks)
  local result
  Transfer.execute_async(plan, 'increment', hooks, function(r) result = r end)
  assert(vim.wait(2000, function() return result ~= nil end), 'execute_async must call on_done')
  return result
end

local calls = {}
local hooks = {
  before_moves = function(moves, proceed)
    calls[#calls + 1] = { 'before', moves }
    -- 模拟异步 LSP：落盘必须等到 proceed 之后，整批的源文件此时都还在
    vim.defer_fn(function()
      for _, move in ipairs(moves) do
        assert(vim.fn.filereadable(move.source) == 1, 'source must still exist while waiting for before_moves')
      end
      proceed()
    end, 30)
  end,
  after_moves = function(outcomes) calls[#calls + 1] = { 'after', outcomes } end,
}

run(Transfer.plan({ sources .. '/a.txt' }, destination, 'copy'), hooks)
assert(#calls == 0, 'copy must not call move hooks')

local result = run(Transfer.plan({ sources .. '/a.txt', sources .. '/b.txt' }, destination, 'cut'), hooks)
assert(result.completed == 2, 'cut should complete every entry')
assert(#calls == 2 and calls[1][1] == 'before' and calls[2][1] == 'after',
  'a whole batch must call before_moves once and after_moves once, not once per entry')
local moves, outcomes = calls[1][2], calls[2][2]
assert(#moves == 2 and #outcomes == 2, 'hooks must receive every entry of the batch')
assert(moves[1].destination ~= destination .. '/a.txt', 'increment destination must differ from the conflicting path')
assert(moves[1].destination == outcomes[1].destination, 'after_moves must report the same final destination')
assert(outcomes[1].moved and outcomes[2].moved, 'after_moves must report successful moves')
assert(vim.fn.filereadable(outcomes[1].destination) == 1, 'destination must exist after the move')

-- before_moves 抛错视为已 proceed，不能卡死也不能中断移动；after_moves 抛错同样不影响结果
vim.fn.writefile({ 'again' }, sources .. '/c.txt')
local throwing = run(
  Transfer.plan({ sources .. '/c.txt' }, destination, 'cut'),
  { before_moves = function() error('boom') end, after_moves = function() error('boom') end }
)
assert(throwing.completed == 1, 'throwing hooks must not abort the move')

-- proceed 被同步调用且重复调用时，整批只落盘一次
local many = {}
for i = 1, 300 do
  local path = sources .. ('/m%d.txt'):format(i)
  vim.fn.writefile({ 'x' }, path)
  many[#many + 1] = path
end
local after_count = 0
local bulk = run(Transfer.plan(many, destination, 'cut'), {
  before_moves = function(_, proceed) proceed(); proceed() end,
  after_moves = function() after_count = after_count + 1 end,
})
assert(bulk.completed == 300, 'synchronous proceed must complete every entry exactly once')
assert(after_count == 1, 'repeated proceed must not run the batch twice')

-- 目录与它的子文件同批 cut：只移动目录，LSP 只收到一条 rename，子项随目录一起视为完成
assert(vim.fn.mkdir(sources .. '/dir', 'p') == 1)
vim.fn.writefile({ 'child' }, sources .. '/dir/child.txt')
local nested_plan = Transfer.plan({ sources .. '/dir', sources .. '/dir/child.txt' }, destination, 'cut')
assert(#nested_plan.entries == 1 and #nested_plan.failed == 0,
  'a child of another selected source must not become its own entry nor be reported as an error')
local nested_moves
local nested = run(nested_plan, { before_moves = function(moves, proceed) nested_moves = moves; proceed() end })
assert(#nested_moves == 1 and nested_moves[1].source == sources .. '/dir',
  'LSP must receive only the directory rename, never a contradictory child rename')
assert(nested.completed == 1 and vim.fn.filereadable(destination .. '/dir/child.txt') == 1, 'directory must move with its child')
local done = {}
for _, path in ipairs(nested.completed_sources) do done[path] = true end
assert(done[sources .. '/dir'] and done[sources .. '/dir/child.txt'],
  'the covered child must be reported completed so it does not linger in the cut clipboard')

-- copy 不做去重：目录与子文件各自复制（前一步已把 dir 移走，先重建源）
assert(vim.fn.mkdir(sources .. '/dir', 'p') == 1)
vim.fn.writefile({ 'child' }, sources .. '/dir/child.txt')
assert(vim.fn.mkdir(destination .. '/copies', 'p') == 1)
local copy_plan = Transfer.plan({ sources .. '/dir', sources .. '/dir/child.txt' }, destination .. '/copies', 'copy')
assert(#copy_plan.entries == 2, 'copy must keep every selected source')

-- 嵌套 A ⊃ B ⊃ C 且按 C、B、A 的顺序选择：三者都挂到最外层 A，不能有子项漏出剪贴板
local nest = temporary .. '/nest'
assert(vim.fn.mkdir(nest .. '/A/B/C', 'p') == 1)
vim.fn.writefile({ 'x' }, nest .. '/A/B/C/f.txt')
local reversed = Transfer.plan({ nest .. '/A/B/C', nest .. '/A/B', nest .. '/A' }, destination, 'cut')
assert(#reversed.entries == 1 and reversed.entries[1].source == nest .. '/A', 'only the outermost directory may be an entry')
local reversed_result = run(reversed, {})
local reversed_done = {}
for _, path in ipairs(reversed_result.completed_sources) do reversed_done[path] = true end
assert(reversed_done[nest .. '/A'] and reversed_done[nest .. '/A/B'] and reversed_done[nest .. '/A/B/C'],
  'every covered descendant must be reported completed regardless of selection order')

-- 符号链接目录不能覆盖它指向的目录里的内容：移动链接不会带走 real/x.txt
assert(vim.fn.mkdir(temporary .. '/linkcase/real', 'p') == 1)
vim.fn.writefile({ 'x' }, temporary .. '/linkcase/real/x.txt')
assert(vim.uv.fs_symlink(temporary .. '/linkcase/real', temporary .. '/linkcase/L'))
local link_plan = Transfer.plan({ temporary .. '/linkcase/L', temporary .. '/linkcase/L/x.txt' }, destination, 'cut')
assert(#link_plan.entries == 2 and not next(link_plan.covered),
  'a symlink must not be treated as a container of the paths reached through it')

-- 外层在规划阶段就失败（粘进自身）时，子项仍应独立执行，而不是被静默吞掉
assert(vim.fn.mkdir(temporary .. '/selfcase/D', 'p') == 1)
vim.fn.writefile({ 'x' }, temporary .. '/selfcase/D/f.txt')
local self_plan = Transfer.plan({ temporary .. '/selfcase/D', temporary .. '/selfcase/D/f.txt' }, temporary .. '/selfcase/D', 'cut')
assert(#self_plan.failed == 1 and self_plan.failed[1]:find('inside itself', 1, true),
  'the container that cannot move must be reported')
assert(not next(self_plan.covered), 'a failed container must not swallow its children')

vim.fn.delete(temporary, 'rf')

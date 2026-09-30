-- Transfer.execute_async：cut 才等待并通知外部系统（LSP），落盘前必须等 proceed，且收到 increment 后的最终路径

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ':h') .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(root)

local Transfer = require('vv-explorer.actions.transfer')

local temporary = vim.fn.tempname()
local sources = temporary .. '/sources'
local destination = temporary .. '/destination'
assert(vim.fn.mkdir(sources, 'p') == 1)
assert(vim.fn.mkdir(destination, 'p') == 1)
vim.fn.writefile({ 'new' }, sources .. '/a.txt')
vim.fn.writefile({ 'old' }, destination .. '/a.txt')

---@return table? result
local function run(plan, hooks)
  local result
  Transfer.execute_async(plan, 'increment', hooks, function(r) result = r end)
  assert(vim.wait(2000, function() return result ~= nil end), 'execute_async must call on_done')
  return result
end

local calls = {}
local hooks = {
  before_move = function(from, to, proceed)
    calls[#calls + 1] = { 'before', from, to }
    -- 模拟异步 LSP：落盘必须等到 proceed 之后
    vim.defer_fn(function()
      assert(vim.fn.filereadable(from) == 1, 'source must still exist while waiting for before_move')
      proceed()
    end, 30)
  end,
  after_move = function(from, to, moved) calls[#calls + 1] = { 'after', from, to, moved } end,
}

run(Transfer.plan({ sources .. '/a.txt' }, destination, 'copy'), hooks)
assert(#calls == 0, 'copy must not call move hooks')

local result = run(Transfer.plan({ sources .. '/a.txt' }, destination, 'cut'), hooks)
assert(result.completed == 1, 'cut should complete')
assert(#calls == 2 and calls[1][1] == 'before' and calls[2][1] == 'after', 'cut must call before then after')
assert(calls[1][3] == result.last_dest and calls[2][3] == result.last_dest,
  'hooks must receive the final incremented destination, not the conflicting one')
assert(calls[2][4] == true, 'after_move must report a successful move')
assert(calls[1][3] ~= destination .. '/a.txt', 'increment destination must differ from the conflicting path')

-- before_move 抛错视为已 proceed，不能卡死也不能中断移动
vim.fn.writefile({ 'again' }, sources .. '/b.txt')
local throwing = run(
  Transfer.plan({ sources .. '/b.txt' }, destination, 'cut'),
  { before_move = function() error('boom') end }
)
assert(throwing.completed == 1, 'a throwing before_move must not abort the move')

-- proceed 被同步调用且条目很多时不能栈溢出，重复调用只生效一次
local many = {}
for i = 1, 300 do
  local path = sources .. ('/m%d.txt'):format(i)
  vim.fn.writefile({ 'x' }, path)
  many[#many + 1] = path
end
local bulk = run(
  Transfer.plan(many, destination, 'cut'),
  { before_move = function(_, _, proceed) proceed(); proceed() end }
)
assert(bulk.completed == 300, 'synchronous proceed must complete every entry exactly once')

vim.fn.delete(temporary, 'rf')

local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["整批 cut 等待一次外部 proceed，异常及重复回调不重复落盘并去重子路径"] = function()
  child.lua_func(function()
    -- Transfer.execute_async：cut 整批只等待一次外部系统（LSP），落盘必须等 proceed，且收到 increment 后的最终路径

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
      assert(vim.wait(30000, function() return result ~= nil end), 'execute_async 必须调用 on_done')
      return result
    end

    local calls = {}
    local hooks = {
      before_moves = function(moves, proceed)
        calls[#calls + 1] = { 'before', moves }
        -- 模拟异步 LSP：落盘必须等到 proceed 之后，整批的源文件此时都还在
        vim.defer_fn(function()
          for _, move in ipairs(moves) do
            assert(vim.fn.filereadable(move.source) == 1, '等待 before_moves 时源仍必须存在')
          end
          proceed()
        end, 30)
      end,
      after_moves = function(outcomes) calls[#calls + 1] = { 'after', outcomes } end,
    }

    run(Transfer.plan({ sources .. '/a.txt' }, destination, 'copy'), hooks)
    assert(#calls == 0, '复制不得调用移动 hooks')

    local result = run(Transfer.plan({ sources .. '/a.txt', sources .. '/b.txt' }, destination, 'cut'), hooks)
    assert(result.completed == 2, '剪切必须完成每个条目')
    assert(#calls == 2 and calls[1][1] == 'before' and calls[2][1] == 'after',
      '整批 before_moves 与 after_moves 各调用一次，不得逐项调用')
    local moves, outcomes = calls[1][2], calls[2][2]
    assert(#moves == 2 and #outcomes == 2, 'hooks 必须收到整批每个条目')
    assert(moves[1].destination ~= destination .. '/a.txt', '递增目标必须不同于冲突路径')
    assert(moves[1].destination == outcomes[1].destination, 'after_moves 必须报告一致的最终目标')
    assert(outcomes[1].moved and outcomes[2].moved, 'after_moves 必须报告成功的移动')
    assert(vim.fn.filereadable(outcomes[1].destination) == 1, '移动后目标必须存在')

    -- before_moves 抛错视为已 proceed，不能卡死也不能中断移动；after_moves 抛错同样不影响结果
    vim.fn.writefile({ 'again' }, sources .. '/c.txt')
    local throwing = run(
      Transfer.plan({ sources .. '/c.txt' }, destination, 'cut'),
      { before_moves = function() error('boom') end, after_moves = function() error('boom') end }
    )
    assert(throwing.completed == 1, 'hooks 抛错不得中止移动')

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
    assert(bulk.completed == 300, '同步 proceed 必须恰好完成每个条目一次')
    assert(after_count == 1, '重复 proceed 不得执行整批两次')

    -- 目录与它的子文件同批 cut：只移动目录，LSP 只收到一条 rename，子项随目录一起视为完成
    assert(vim.fn.mkdir(sources .. '/dir', 'p') == 1)
    vim.fn.writefile({ 'child' }, sources .. '/dir/child.txt')
    local nested_plan = Transfer.plan({ sources .. '/dir', sources .. '/dir/child.txt' }, destination, 'cut')
    assert(#nested_plan.entries == 1 and #nested_plan.failed == 0,
      '已选目录的子项不得重复执行或被报为错误')
    local nested_moves
    local nested = run(nested_plan, { before_moves = function(moves, proceed) nested_moves = moves; proceed() end })
    assert(#nested_moves == 1 and nested_moves[1].source == sources .. '/dir',
      'LSP 必须只收到目录改名，不能收到矛盾子项改名')
    assert(nested.completed == 1 and vim.fn.filereadable(destination .. '/dir/child.txt') == 1, '目录必须连同子项移动')
    local done = {}
    for _, path in ipairs(nested.completed_sources) do done[path] = true end
    assert(done[sources .. '/dir'] and done[sources .. '/dir/child.txt'],
      '被包含子项必须报告完成，不得残留在剪切剪贴板')

    -- copy 不做去重：目录与子文件各自复制（前一步已把 dir 移走，先重建源）
    assert(vim.fn.mkdir(sources .. '/dir', 'p') == 1)
    vim.fn.writefile({ 'child' }, sources .. '/dir/child.txt')
    assert(vim.fn.mkdir(destination .. '/copies', 'p') == 1)
    local copy_plan = Transfer.plan({ sources .. '/dir', sources .. '/dir/child.txt' }, destination .. '/copies', 'copy')
    assert(#copy_plan.entries == 2, '复制必须保留所有选中的源')

    -- 嵌套 A ⊃ B ⊃ C 且按 C、B、A 的顺序选择：三者都挂到最外层 A，不能有子项漏出剪贴板
    local nest = temporary .. '/nest'
    assert(vim.fn.mkdir(nest .. '/A/B/C', 'p') == 1)
    vim.fn.writefile({ 'x' }, nest .. '/A/B/C/f.txt')
    local reversed = Transfer.plan({ nest .. '/A/B/C', nest .. '/A/B', nest .. '/A' }, destination, 'cut')
    assert(#reversed.entries == 1 and reversed.entries[1].source == nest .. '/A', '只能把最外层目录作为条目')
    local reversed_result = run(reversed, {})
    local reversed_done = {}
    for _, path in ipairs(reversed_result.completed_sources) do reversed_done[path] = true end
    assert(reversed_done[nest .. '/A'] and reversed_done[nest .. '/A/B'] and reversed_done[nest .. '/A/B/C'],
      '无论选择顺序如何，所有被包含的子项都必须报告完成')

    -- 符号链接目录不能覆盖它指向的目录里的内容：移动链接不会带走 real/x.txt
    assert(vim.fn.mkdir(temporary .. '/linkcase/real', 'p') == 1)
    vim.fn.writefile({ 'x' }, temporary .. '/linkcase/real/x.txt')
    assert(vim.uv.fs_symlink(temporary .. '/linkcase/real', temporary .. '/linkcase/L'))
    local link_plan = Transfer.plan({ temporary .. '/linkcase/L', temporary .. '/linkcase/L/x.txt' }, destination, 'cut')
    assert(#link_plan.entries == 2 and not next(link_plan.covered),
      '符号链接不得被视为其指向路径的父容器')

    -- 外层在规划阶段就失败（粘进自身）时，子项仍应独立执行，而不是被静默吞掉
    assert(vim.fn.mkdir(temporary .. '/selfcase/D', 'p') == 1)
    vim.fn.writefile({ 'x' }, temporary .. '/selfcase/D/f.txt')
    local self_plan = Transfer.plan({ temporary .. '/selfcase/D', temporary .. '/selfcase/D/f.txt' }, temporary .. '/selfcase/D', 'cut')
    assert(#self_plan.failed == 1 and self_plan.failed[1]:find('inside itself', 1, true),
      '无法移动的父目录必须报告')
    assert(not next(self_plan.covered), '失败的父目录不得吞掉子项')

    vim.fn.delete(temporary, 'rf')
  end)
end

return T

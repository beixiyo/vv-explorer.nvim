local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["回收站移动、恢复、清空及异步容量扫描不遗留孤儿 metadata"] = function()
  child.lua_func(function()
    -- vv-explorer 回收站存储行为

    local Store = require('vv-explorer.trash.store')

    local temporary = vim.fn.tempname()
    local source_dir = temporary .. '/source'
    local trash_dir = temporary .. '/trash'
    vim.fn.mkdir(source_dir, 'p')

    local store = Store.new({
      enabled = true,
      max_items = 10,
      warn_size_mb = 500,
      scan_on_open = false,
    }, trash_dir)

    local original = source_dir .. '/example.txt'
    vim.fn.writefile({ 'payload' }, original)
    local result = store:trash({ original })
    assert(#result.trashed == 1 and #result.failed == 0, '现存文件必须移入回收站')
    assert(vim.fn.filereadable(original) == 0, '已回收文件必须离开原路径')

    local entries = store:list()
    assert(#entries == 1, '已回收文件和 metadata 必须组成一个逻辑条目')
    assert(entries[1].original_path == original, '回收站 metadata 必须保留原路径')
    assert(entries[1].basename == 'example.txt', '回收站 metadata 必须保留文件名')
    assert(entries[1].size_bytes > 0, '回收站 metadata 必须保留文件大小')

    vim.fn.writefile({ 'replacement' }, original)
    local restored = store:restore(entries[1])
    assert(restored ~= original, '恢复不得覆盖新建的原路径')
    assert(vim.deep_equal(vim.fn.readfile(original), { 'replacement' }), '恢复必须保留冲突目标')
    assert(vim.deep_equal(vim.fn.readfile(restored), { 'payload' }), '恢复必须找回已回收内容')
    assert(#store:list() == 0, '恢复条目必须离开回收站索引')

    local orphan_path = trash_dir .. '/orphan.bin'
    vim.fn.writefile({ 'orphan' }, orphan_path)
    local orphan = assert(store:list()[1])
    assert(orphan.original_path == '(unknown)', '缺失 metadata 必须产生显式孤儿条目')
    local restored_orphan, orphan_error = pcall(store.restore, store, orphan)
    assert(not restored_orphan, '孤儿条目不得恢复到当前工作目录')
    assert(tostring(orphan_error):find('original path unknown', 1, true), '孤儿恢复必须说明路径缺失')
    store:delete_entry(orphan)
    assert(vim.fn.filereadable(orphan_path) == 0, 'delete_entry 必须移除孤儿内容')

    local missing = store:trash({ source_dir .. '/missing.txt' })
    assert(#missing.trashed == 0 and #missing.failed == 1, '源缺失必须报告为回收失败')

    local limited_dir = temporary .. '/limited-trash'
    local limited = Store.new({
      enabled = true,
      max_items = 1,
      warn_size_mb = 500,
      scan_on_open = false,
    }, limited_dir)
    local first = source_dir .. '/first.txt'
    local second = source_dir .. '/second.txt'
    vim.fn.writefile({ 'first' }, first)
    vim.fn.writefile({ 'second' }, second)
    limited:trash({ first, second })
    assert(vim.wait(200, function() return #limited:list() == 1 end), 'max_items 必须裁剪较旧的超额条目')
    limited:empty()
    assert(#limited:list() == 0, '清空必须移除内容和 metadata')

    -- 容量统计：曾经调 `du -sb`，而 BSD / macOS 的 du 没有 `-b`，回调恒为 0，
    -- 容量提醒（warn_size_mb）因此从未触发过
    local sized_dir = temporary .. '/sized-trash'
    local sized = Store.new({
      enabled = true,
      max_items = 10,
      warn_size_mb = 500,
      scan_on_open = false,
    }, sized_dir)

    local payload_dir = source_dir .. '/nested'
    vim.fn.mkdir(payload_dir, 'p')
    vim.fn.writefile({ string.rep('x', 63) }, source_dir .. '/big.txt')
    vim.fn.writefile({ string.rep('y', 31) }, payload_dir .. '/inner.txt')
    sized:trash({ source_dir .. '/big.txt', payload_dir })

    local scanned
    local scan_handle = sized:scan_size(function(bytes) scanned = bytes end)
    assert(type(scan_handle.cancel) == 'function', 'scan_size 必须返回可取消句柄')
    assert(vim.wait(5000, function() return scanned ~= nil end, 10), 'scan_size 必须报告大小')
    -- writefile 每行补一个换行：64 + 32，metadata 的 json 另算，故只断言下界与非零
    assert(scanned >= 96, '回收站大小必须包含嵌套内容，实际：' .. tostring(scanned))

    local cancelled_bytes
    local cancelled_handle = sized:scan_size(function(bytes) cancelled_bytes = bytes end)
    cancelled_handle.cancel()
    vim.wait(200, function() return false end, 10)
    assert(cancelled_bytes == nil, '取消的回收站统计不得回调')

    -- 目录移入回收站：rename 不等递归统计（大目录曾因此冻结界面），大小随后异步补写进 meta
    local async_dir = temporary .. '/async-trash'
    local async = Store.new({ enabled = true, max_items = 10, warn_size_mb = 500, scan_on_open = false }, async_dir)

    local function make_tree(name)
      local dir = source_dir .. '/' .. name
      vim.fn.mkdir(dir .. '/deep', 'p')
      vim.fn.writefile({ string.rep('a', 9) }, dir .. '/one.txt')
      vim.fn.writefile({ string.rep('b', 19) }, dir .. '/deep/two.txt')
      return dir
    end

    local function meta_files()
      return vim.fn.glob(async_dir .. '/*.meta.json', true, true)
    end

    local tree = make_tree('tree')
    async:trash({ tree })
    assert(vim.fn.isdirectory(tree) == 0, '目录必须立即离开原路径')
    local pending_entry = assert(async:list()[1])
    assert(pending_entry.size_bytes == nil, '返回前不得同步计算目录大小')
    assert(pending_entry.original_path == tree, '没有大小的 metadata 仍必须允许恢复')
    assert(
      vim.wait(5000, function() return async:list()[1].size_bytes ~= nil end, 10),
      '目录大小必须异步补写到 metadata'
    )
    assert(async:list()[1].size_bytes == 10 + 20, '补写大小必须计入嵌套文件，实际：' .. tostring(async:list()[1].size_bytes))
    async:empty()

    -- 统计途中被恢复 / 清空：扫描结果不能重建 meta，留下指向不存在 payload 的孤儿条目
    local restored_tree = make_tree('restored-tree')
    async:trash({ restored_tree })
    local restored_path = async:restore(async:list()[1])
    local emptied_tree = make_tree('emptied-tree')
    async:trash({ emptied_tree })
    async:empty()
    vim.wait(300, function() return false end, 10)
    assert(#meta_files() == 0, '恢复或清空后迟到统计不得重建 metadata')
    assert(#async:list() == 0, '恢复和清空后回收站必须保持为空')
    assert(vim.fn.filereadable(restored_path .. '/deep/two.txt') == 1, '统计期间恢复必须保持完整内容')
    assert(vim.fn.filereadable(restored_path .. '.meta.json') == 0, '大小补写绝不能写到恢复路径旁')

    vim.fn.delete(temporary, 'rf')
  end)
end

return T

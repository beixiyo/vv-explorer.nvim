local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["历史大小补跑和新目录统计原地更新面板，孤儿条目不重建 metadata"] = function()
  child.lua_func(function()
    -- 回收站目录大小的补跑与面板原地更新：
    --   1. 上次扫描中途退出 Neovim（meta 没有 size_bytes、新进程也没有在途扫描），
    --      打开面板必须补跑扫描、写回 meta，并在不重开面板的情况下把 `—` 换成真实大小
    --   2. 面板打开时刚移入的目录，补写完成后同一个 buffer 原地更新，光标行不变
    --   3. 孤儿条目（meta 缺失）不补跑，不会凭空生成 meta

    local Store = require('vv-explorer.trash.store')
    local Panel = require('vv-explorer.trash.panel')
    Panel.setup()

    local temporary = vim.fn.tempname()
    local trash_dir = temporary .. '/trash'
    local source_dir = temporary .. '/source'
    vim.fn.mkdir(trash_dir, 'p')
    vim.fn.mkdir(source_dir, 'p')

    local function write(path, bytes)
      vim.fn.mkdir(vim.fs.dirname(path), 'p')
      vim.fn.writefile({ string.rep('x', bytes) }, path, 'b') -- 'b' 不追加换行，文件恰为 bytes 字节
    end

    local function read_meta(path)
      return vim.json.decode(table.concat(vim.fn.readfile(path .. '.meta.json'), '\n'))
    end

    local function panel_lines()
      return vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    end

    local function close_panel()
      vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
    end

    -- 1：模拟「扫描中途退出」留下的条目
    local interrupted = trash_dir .. '/0000000001_interrupted'
    write(interrupted .. '/a.txt', 10)
    write(interrupted .. '/deep/b.txt', 20)
    vim.fn.writefile({ vim.json.encode({ original_path = source_dir .. '/interrupted', trashed_at = 1 }) }, interrupted .. '.meta.json')

    -- 2 的孤儿条目：只有 payload 没有 meta
    local orphan = trash_dir .. '/0000000002_orphan'
    write(orphan .. '/c.txt', 5)

    local store = Store.new({ enabled = true, max_items = 10, warn_size_mb = 500 }, trash_dir)
    assert(store:list()[1].size_bytes == nil, '前置条件：条目大小未知')

    Panel.open(store)
    local buffer = vim.api.nvim_get_current_buf()
    local function interrupted_line()
      for _, line in ipairs(panel_lines()) do
        if line:find('interrupted', 1, true) then return line end
      end
    end
    assert(interrupted_line():find('—', 1, true), '补写前大小列应显示 —')

    assert(
      vim.wait(5000, function() return read_meta(interrupted).size_bytes ~= nil end, 10),
      '打开面板必须给大小未知的目录补跑扫描并写回 meta'
    )
    assert(read_meta(interrupted).size_bytes == 30, '补写的大小应统计嵌套文件，got ' .. tostring(read_meta(interrupted).size_bytes))
    assert(vim.wait(1000, function() return interrupted_line():find('30 B', 1, true) ~= nil end, 10),
      '补写后面板必须原地显示真实大小：' .. tostring(interrupted_line()))
    assert(vim.api.nvim_get_current_buf() == buffer, '更新大小不得重开面板')
    assert(not vim.bo[buffer].modifiable, '原地更新后 buffer 必须恢复不可修改')

    vim.wait(200, function() return false end, 10)
    assert(vim.fn.filereadable(orphan .. '.meta.json') == 0, '孤儿条目不得补跑扫描或生成 meta')
    close_panel()

    -- 2：面板打开期间刚移入的目录
    local fresh_source = source_dir .. '/fresh'
    write(fresh_source .. '/d.txt', 40)
    local fresh_store = Store.new({ enabled = true, max_items = 10, warn_size_mb = 500 }, temporary .. '/trash-fresh')

    -- 先放一个已知大小的条目，让光标停在第 2 行验证原地更新不移动光标
    write(source_dir .. '/known.txt', 3)
    fresh_store:trash({ source_dir .. '/known.txt' })
    vim.wait(1100, function() return false end, 50) -- 让两个条目的 trashed_at 不同，排序稳定
    fresh_store:trash({ fresh_source })
    Panel.open(fresh_store)
    local fresh_buffer = vim.api.nvim_get_current_buf()
    local window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(window, { 2, 0 })

    assert(vim.wait(5000, function()
      return vim.api.nvim_buf_get_lines(fresh_buffer, 0, 1, false)[1]:find('40 B', 1, true) ~= nil
    end, 10), '刚移入的目录补写完成后，面板必须原地显示大小：' .. vim.inspect(vim.api.nvim_buf_get_lines(fresh_buffer, 0, -1, false)))
    assert(vim.api.nvim_get_current_buf() == fresh_buffer, '更新大小不得重开面板')
    assert(vim.api.nvim_win_get_cursor(window)[1] == 2, '原地更新不得移动光标行')
    close_panel()

    vim.fn.delete(temporary, 'rf')
  end)
end

return T

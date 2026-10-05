local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["真实批量移动结算 LSP 编辑，保护只读、用户修改与外部磁盘内容"] = function()
  child.lua_func(function()
    -- LSP 编辑 + 真实文件移动的集成：被移动文件自身的编辑必须落盘，部分失败必须只回滚 buffer、不在旧路径复活文件
    --
    -- 真实的：Transfer.execute_async / Installer / Fs.sync_buffers / WorkspaceEdit / 磁盘。
    -- 桩掉的：LSP 客户端请求（返回固定 WorkspaceEdit）
    -- after_moves 直接调用公开的 Lsp.settle_batch（clipboard.lua 同款），「有一项失败就整体回滚」的策略由它承担，
    -- 这里只验证它与真实移动结果组合后的磁盘 / buffer 效果；clipboard.lua 的 UI 流程不在此覆盖
    vim.o.confirm = false

    local temporary = vim.fn.tempname()
    assert(vim.fn.mkdir(temporary, 'p') == 1)
    temporary = assert(vim.uv.fs_realpath(temporary))

    local function text_edit(path, line)
      return {
        [vim.uri_from_fname(path)] = {
          { range = { start = { line = line, character = 8 }, ['end'] = { line = line, character = 13 } }, newText = './new' },
        },
      }
    end

    local fixture -- 每个场景一套全新目录
    local request_probe -- 发出 willRenameFiles 时调用，用来观察请求那一刻的 buffer 状态
    local function edit_changes()
      return vim.tbl_extend('error',
        text_edit(fixture.src .. '/a.ts', 0),     -- 被移动文件自身
        text_edit(fixture.other, 0),              -- 别处未打开的文件
        text_edit(fixture.dirty, 1))              -- 已打开且用户有未保存修改
    end

    package.loaded['vv-utils.lsp.file_operations'] = {
      clients = function() return { { name = 'fixture-lsp' } } end,
      will_rename_many_async = function(_, _, on_done)
        if request_probe then request_probe() end
        on_done({ { edit = { changes = edit_changes() }, encoding = 'utf-16' } }, false)
      end,
      notify_did_rename_many = function() end,
    }

    local Transfer = require('vv-explorer.actions.transfer')
    local Lsp = require('vv-explorer.lsp')

    local function disk(path) return vim.fn.readfile(path)[1] end
    local function exists(path) return vim.uv.fs_stat(path) ~= nil end

    local function new_fixture(name)
      local base = temporary .. '/' .. name
      assert(vim.fn.mkdir(base .. '/src', 'p') == 1)
      assert(vim.fn.mkdir(base .. '/dst', 'p') == 1)
      local f = {
        src = base .. '/src', dst = base .. '/dst',
        other = base .. '/other.ts', dirty = base .. '/dirty.ts',
      }
      vim.fn.writefile({ 'import "./old"' }, f.src .. '/a.ts')
      vim.fn.writefile({ 'import "./a"' }, f.src .. '/b.ts')
      vim.fn.writefile({ 'import "./old"' }, f.other)
      vim.fn.writefile({ 'import "./old"' }, f.dirty)
      vim.cmd('silent! %bwipeout!')
      local buf = vim.fn.bufadd(f.dirty)
      vim.fn.bufload(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'user unsaved edit', 'import "./old"' })
      f.dirty_buf = buf
      fixture = f
      return f
    end

    ---@param sabotage_b? boolean 在 LSP 编辑应用之后、落盘之前改动 b.ts，让它的 commit 因源快照变化而失败
    ---@param between_commit_and_settle? fun(outcomes: table[]) 落盘之后、收尾之前执行，用来模拟这个窗口里的外部改动
    local function run(f, sabotage_b, between_commit_and_settle)
      local plan = Transfer.plan({ f.src .. '/a.ts', f.src .. '/b.ts' }, f.dst, 'cut')
      local pending
      local outcomes_seen
      local result
      Transfer.execute_async(plan, 'increment', {
        before_moves = function(moves, proceed)
          local renames = {}
          for _, move in ipairs(moves) do renames[#renames + 1] = { old_path = move.source, new_path = move.destination } end
          Lsp.will_rename_many_async(renames, 1000, function(_, edits)
            pending = edits
            if sabotage_b then vim.fn.writefile({ 'externally changed' }, f.src .. '/b.ts') end
            proceed()
          end)
        end,
        after_moves = function(outcomes)
          outcomes_seen = outcomes
          if between_commit_and_settle then between_commit_and_settle(outcomes) end
          Lsp.settle_batch(pending, outcomes)
        end,
      }, function(r) result = r end)
      assert(vim.wait(3000, function() return result ~= nil end), 'execute_async 必须完成')
      return result, outcomes_seen
    end

    local function modified_named_buffers()
      local names = {}
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified and vim.api.nvim_buf_get_name(buf) ~= '' then
          names[#names + 1] = vim.api.nvim_buf_get_name(buf)
        end
      end
      return names
    end

    -- 场景 1：整批成功。被移动文件自身的编辑必须保存到新路径（改名后的 buffer 对已存在文件 :write 会 E13）
    local f = new_fixture('success')
    local result = run(f)
    assert(result.completed == 2, '两个文件都必须移动')
    assert(not exists(f.src .. '/a.ts'), '移动文件必须从旧路径消失')
    assert(disk(f.dst .. '/a.ts') == 'import "./new"', '移动文件自身的编辑必须保存到新路径')
    assert(disk(f.other) == 'import "./new"', '其他未打开文件的编辑必须保存')
    assert(disk(f.dirty) == 'import "./old"', '用户原有未保存修改不得被隐式保存')
    local modified = modified_named_buffers()
    assert(#modified == 1 and modified[1] == f.dirty, '只能留下用户原有修改的 buffer 为 modified，实际：' .. vim.inspect(modified))

    -- 场景 2：部分失败。整体回滚只能动 buffer：旧路径不能复活，临时 buffer 不能残留，用户文件不能被重写
    f = new_fixture('partial')
    local dirty_mtime = vim.uv.fs_stat(f.dirty).mtime
    result = run(f, true)
    assert(result.completed == 1 and #result.failed >= 1, 'b 必须失败且 a 仍必须移动')
    assert(not exists(f.src .. '/a.ts'), '回滚不得在旧路径重建已移动文件')
    assert(disk(f.dst .. '/a.ts') == 'import "./old"', '已回滚编辑不得写入已移动文件')
    assert(disk(f.other) == 'import "./old"', '已回滚编辑不得写入其他文件')
    modified = modified_named_buffers()
    assert(#modified == 1 and modified[1] == f.dirty,
      '回滚不得留下用户原有修改以外的 modified buffer，实际：' .. vim.inspect(modified))
    local restored_lines = vim.api.nvim_buf_get_lines(f.dirty_buf, 0, -1, false)
    assert(restored_lines[1] == 'user unsaved edit' and restored_lines[2] == 'import "./old"',
      '回滚必须还原 buffer 中用户原有内容')
    local after = vim.uv.fs_stat(f.dirty).mtime
    assert(after.sec == dirty_mtime.sec and after.nsec == dirty_mtime.nsec,
      '回滚不得重写用户修改 buffer 对应磁盘文件')

    -- 场景 3：已加载、未修改但内容落后于磁盘的 buffer（外部改了文件、nvim 还没 checktime）不能被写盘覆盖
    local notices = {}
    local original_notify = vim.notify
    vim.notify = function(message) notices[#notices + 1] = message end

    f = new_fixture('stale')
    vim.fn.bufload(vim.fn.bufadd(f.other))
    vim.fn.writefile({ 'import "./old"', '// external change' }, f.other)
    run(f)
    assert(vim.fn.readfile(f.other)[2] == '// external change',
      '陈旧 buffer 不得覆盖其他进程的磁盘修改')
    assert(table.concat(notices, '\n'):find('not saved', 1, true), '必须告知用户编辑未保存')

    -- 场景 4：只读文件不能被写穿，也不能清掉 buffer 的 readonly（save_target 的 readonly/fs_access 检查与普通 :write 的 E505 共同拦住）
    notices = {}
    f = new_fixture('readonly')
    assert(vim.uv.fs_chmod(f.other, tonumber('444', 8)))
    run(f)
    assert(disk(f.other) == 'import "./old"', '只读文件不得被写入')
    assert(table.concat(notices, '\n'):find('not saved', 1, true), '必须告知用户编辑未保存')
    vim.uv.fs_chmod(f.other, tonumber('644', 8))

    -- 场景 5：用户原本就在 buffer 列表里的未加载 buffer（会话恢复、:badd）不能被当成临时 buffer wipe 掉
    f = new_fixture('listed')
    local listed = vim.fn.bufadd(f.other)
    vim.bo[listed].buflisted = true -- bufadd 默认不在列表里；会话恢复出来的 buffer 是 listed 的
    assert(vim.fn.buflisted(listed) == 1 and not vim.api.nvim_buf_is_loaded(listed))
    run(f)
    assert(disk(f.other) == 'import "./new"', '编辑仍必须保存')
    assert(vim.api.nvim_buf_is_valid(listed) and vim.fn.buflisted(listed) == 1,
      '用户已列出的 buffer 必须保留在列表中')
    assert(not vim.api.nvim_buf_is_loaded(listed), 'buffer 必须重新卸载，不得保持已加载且已修改')

    f = new_fixture('listed-rollback')
    listed = vim.fn.bufadd(f.other)
    vim.bo[listed].buflisted = true
    run(f, true)
    assert(vim.api.nvim_buf_is_valid(listed) and vim.fn.buflisted(listed) == 1,
      '回滚也不得 wipe 用户已列出的 buffer')
    assert(not vim.api.nvim_buf_is_loaded(listed), '回滚不得让 listed buffer 继续加载已回滚编辑')

    -- 场景 6：被移动的只读文件自身也是编辑目标。LSP 编辑使它的 buffer 处于已修改状态，sync_buffers 不重读它，
    -- 保存走 `write!`，会跳过 Neovim 自己的只读检查；readonly 与 fs_access 因此是这里的唯一防线
    notices = {}
    f = new_fixture('readonly-moved')
    assert(vim.uv.fs_chmod(f.src .. '/a.ts', tonumber('444', 8)))
    run(f)
    assert(disk(f.dst .. '/a.ts') == 'import "./old"', '移动后的只读文件不得被写穿')
    assert(table.concat(notices, '\n'):find('not saved', 1, true), '必须告知用户编辑未保存')
    vim.uv.fs_chmod(f.dst .. '/a.ts', tonumber('644', 8))

    -- 场景 7：最常见的真实情况——已加载、未修改、与磁盘一致的 buffer 作为编辑目标
    local function raw(path) local file = assert(io.open(path, 'rb')); local content = file:read('*a'); file:close(); return content end
    local function write_raw(path, content) local file = assert(io.open(path, 'wb')); file:write(content); file:close() end

    for _, variant in ipairs({
      { name = 'lf', old = 'import "./old"\n', new = 'import "./new"\n' },
      { name = 'crlf', old = 'import "./old"\r\n', new = 'import "./new"\r\n' },
      { name = 'bom', old = '\239\187\191import "./old"\n', new = '\239\187\191import "./new"\n' },
    }) do
      f = new_fixture('clean-' .. variant.name)
      write_raw(f.other, variant.old)
      local clean = vim.fn.bufadd(f.other)
      vim.fn.bufload(clean)
      assert(not vim.bo[clean].modified)
      run(f)
      assert(raw(f.other) == variant.new,
        variant.name .. '：干净已加载 buffer 保存必须保留换行和 BOM')
      assert(not vim.bo[clean].modified, variant.name .. '：保存后 buffer 不得保持 modified')

      -- 回滚：内容还原，且不能把干净 buffer 留成 modified
      f = new_fixture('clean-rollback-' .. variant.name)
      write_raw(f.other, variant.old)
      clean = vim.fn.bufadd(f.other)
      vim.fn.bufload(clean)
      run(f, true)
      assert(raw(f.other) == variant.old, variant.name .. '：回滚不得修改磁盘')
      assert(vim.api.nvim_buf_get_lines(clean, 0, -1, false)[1]:find('old', 1, true),
        variant.name .. '：回滚必须还原 buffer 内容')
      assert(not vim.bo[clean].modified, variant.name .. '：回滚不得让干净 buffer 残留 modified')
    end

    -- 场景 8：已改名的 buffer 用 write!，它会跳过 Neovim 自己的「文件已被改动」检查，
    -- 所以「磁盘内容仍是编辑前的」这道比对是唯一防线：落盘之后、保存之前被外部改动，不能被覆盖
    notices = {}
    f = new_fixture('external-after-move')
    run(f, false, function() write_raw(f.dst .. '/a.ts', 'import "./old"\n// external change\n') end)
    assert(raw(f.dst .. '/a.ts') == 'import "./old"\n// external change\n',
      '移动后其他进程的修改不得被 write! 覆盖')
    assert(table.concat(notices, '\n'):find('not saved', 1, true), '必须告知用户编辑未保存')

    -- 场景 9：buffer 加载之后文件才被 chmod 成只读。此时 buffer 的 readonly 选项仍是 false，
    -- 只有 fs_access 能拦住，否则 write! 会把只读文件写穿
    notices = {}
    f = new_fixture('chmod-after-load')
    local preloaded = vim.fn.bufadd(f.src .. '/a.ts')
    vim.fn.bufload(preloaded)
    assert(not vim.bo[preloaded].readonly)
    run(f, false, function() assert(vim.uv.fs_chmod(f.dst .. '/a.ts', tonumber('444', 8))) end)
    assert(disk(f.dst .. '/a.ts') == 'import "./old"', 'buffer 加载后变为只读的文件不得被写穿')
    assert(table.concat(notices, '\n'):find('not saved', 1, true), '必须告知用户编辑未保存')
    vim.uv.fs_chmod(f.dst .. '/a.ts', tonumber('644', 8))

    -- 场景 10：没被移动、已加载且干净的 buffer，对应文件只被 touch 过（内容不变）。
    -- 普通 :write 此时会弹阻塞式 y/n（headless 下脚本直接退出）；write! + 磁盘内容比对应当直接保存
    f = new_fixture('touched')
    local touched = vim.fn.bufadd(f.other)
    vim.fn.bufload(touched)
    vim.uv.fs_utime(f.other, os.time() + 100, os.time() + 100)
    run(f)
    assert(disk(f.other) == 'import "./new"', '仅更新时间的文件保存不得触发交互提示')

    -- 场景 11：用户要被告知哪些文件被 LSP 改写并自动保存了；回滚时没有改动落盘，不能说“已更新”
    notices = {}
    f = new_fixture('notify-updated')
    run(f)
    local updated = table.concat(notices, '\n')
    assert(updated:find('updated references in', 1, true), '移动成功且改写文件时必须通知用户')
    assert(updated:find('other.ts', 1, true) and updated:find('a.ts', 1, true), '通知必须列出已改写文件：' .. updated)
    assert(not updated:find('dirty.ts', 1, true) or updated:find('updated references in 2', 1, true),
      '用户修改 buffer 未保存，不得报告为已更新')

    notices = {}
    f = new_fixture('notify-rollback')
    run(f, true)
    assert(not table.concat(notices, '\n'):find('updated references in', 1, true),
      '已回滚整批没有写盘，不得报告文件已更新')

    -- 场景 12：目标路径上残留过期 buffer（未修改、文件已被删，如 Git 丢弃改动后）。它必须在 willRenameFiles 之前被关掉：
    -- 否则服务端把它当成已打开的文档；它还占着 buffer 名，sync_buffers 把源 buffer 改名过去会失败、源 buffer 停在旧路径
    f = new_fixture('stale-destination')
    vim.fn.writefile({ 'ghost' }, f.dst .. '/a.ts')
    local stale = vim.fn.bufadd(f.dst .. '/a.ts')
    vim.fn.bufload(stale)
    assert(os.remove(f.dst .. '/a.ts'))
    local moved_buf = vim.fn.bufadd(f.src .. '/a.ts')
    vim.fn.bufload(moved_buf)
    local stale_alive_at_request
    request_probe = function() stale_alive_at_request = vim.api.nvim_buf_is_valid(stale) end
    result = run(f)
    request_probe = nil
    assert(stale_alive_at_request == false, '发送 willRenameFiles 前必须关闭陈旧目标 buffer')
    assert(result.completed == 2, '目标仅有陈旧 buffer 时移动必须成功')
    assert(vim.api.nvim_buf_get_name(moved_buf) == f.dst .. '/a.ts',
      '已移动文件 buffer 必须改名为目标，实际：' .. vim.api.nvim_buf_get_name(moved_buf))
    assert(disk(f.dst .. '/a.ts') == 'import "./new"', '移动文件的编辑仍必须保存到新路径')

    -- 场景 13：目标路径上是已修改的 buffer（文件不存在但有未保存内容）：绝不能关掉，移动被拒绝，内容原样
    f = new_fixture('dirty-destination')
    local dirty_dest = vim.fn.bufadd(f.dst .. '/a.ts')
    vim.fn.bufload(dirty_dest)
    vim.api.nvim_buf_set_lines(dirty_dest, 0, -1, false, { 'unsaved work' })
    result = run(f)
    assert(vim.api.nvim_buf_is_valid(dirty_dest) and vim.bo[dirty_dest].modified, '目标 buffer 有修改时绝不能关闭')
    assert(vim.api.nvim_buf_get_lines(dirty_dest, 0, -1, false)[1] == 'unsaved work', '其未保存内容必须保留')
    assert(exists(f.src .. '/a.ts'), '目标 buffer 有修改时移动必须拒绝并保留源')

    vim.notify = original_notify
    vim.fn.delete(temporary, 'rf')
  end)
end

return T

local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["递增复制、完整覆盖与规划后目标变化保护"] = function()
  child.lua_func(function()
    local F = dofile(vim.env.VV_TEST_REPO .. '/tests/fixtures/transfer.lua')()
    local Transfer, Fs, temporary, sources, destination = F.Transfer, F.Fs, F.temporary, F.sources, F.destination
    local invalid_mode_ok, invalid_mode_error = pcall(Transfer.plan, {}, destination, 'merge')
    assert(not invalid_mode_ok and tostring(invalid_mode_error):find('transfer mode', 1, true),
      'plan 必须拒绝 copy/cut 以外模式')

    local increment_plan = Transfer.plan({ sources .. '/widget' }, destination, 'copy')
    assert(increment_plan.conflicts == 1, '变更前必须报告现存目标')
    local invalid_policy_ok, invalid_policy_error = pcall(Transfer.execute, increment_plan, 'merge')
    assert(not invalid_policy_ok and tostring(invalid_policy_error):find('transfer policy', 1, true),
      'execute 必须拒绝 overwrite/increment 以外的策略')
    local increment = Transfer.execute(increment_plan, 'increment')
    assert(increment.completed == 1, '递增粘贴必须完成')
    assert(vim.fn.readfile(destination .. '/widget/shared.txt')[1] == 'old', '递增必须保留目标')
    assert(vim.fn.readfile(destination .. '/widget (copy)/shared.txt')[1] == 'new', '递增必须复制源')
    assert(vim.deep_equal(F.read_tree(destination .. '/widget (copy)'), F.read_tree(sources .. '/widget')), '递增必须复制完整目录结构和每个文件字节')

    local overwrite_plan = Transfer.plan({ sources .. '/widget' }, destination, 'copy')
    local overwrite = Transfer.execute(overwrite_plan, 'overwrite')
    assert(overwrite.completed == 1, '覆盖粘贴必须完成')
    assert(vim.fn.readfile(destination .. '/widget/shared.txt')[1] == 'new', '覆盖必须使用源内容')
    assert(vim.fn.filereadable(destination .. '/widget/destination-only.txt') == 0,
      '覆盖必须替换整个目录而非合并')
    assert(vim.deep_equal(F.read_tree(destination .. '/widget'), F.read_tree(sources .. '/widget')), '覆盖必须读回完整目录结构和每个文件字节')

    local stale_plan = Transfer.plan({ sources .. '/widget' }, destination, 'copy')
    assert(vim.uv.fs_rename(destination .. '/widget', destination .. '/widget-old'))
    assert(vim.fn.mkdir(destination .. '/widget', 'p') == 1)
    vim.fn.writefile({ 'changed-again' }, destination .. '/widget/shared.txt')
    local stale = Transfer.execute(stale_plan, 'overwrite')
    assert(stale.completed == 0 and #stale.failed == 1, '目标变化后必须拒绝覆盖')
    assert(vim.fn.readfile(destination .. '/widget/shared.txt')[1] == 'changed-again',
      '拒绝覆盖必须保留新目标')

    local descendant_plan = Transfer.plan({ sources .. '/widget' }, destination, 'copy')
    vim.fn.writefile({ 'descendant changed while the conflict modal was open' }, destination .. '/widget/shared.txt')
    local descendant = Transfer.execute(descendant_plan, 'overwrite')
    assert(descendant.completed == 0 and #descendant.failed == 1,
      '目录子项变化后必须拒绝覆盖')
    assert(vim.fn.readfile(destination .. '/widget/shared.txt')[1]
      == 'descendant changed while the conflict modal was open',
      '拒绝子项覆盖必须保留已变更文件')

    local root_source = sources .. '/root-path'
    vim.fn.writefile({ 'root path' }, root_source)
    local root_plan = Transfer.plan({ root_source }, '/', 'copy')
    assert(root_plan.destination_dir == '/', '文件系统根路径必须保留末尾分隔符')
    assert(root_plan.entries[1].destination == '/root-path',
      '粘贴到文件系统根目录不得产生相对目标')

    local source_alias = temporary .. '/widget-alias'
    assert(vim.uv.fs_symlink(sources .. '/widget', source_alias), '必须创建测试符号链接')
    local symlink_subtree_plan = Transfer.plan({ sources .. '/widget' }, source_alias, 'copy')
    assert(#symlink_subtree_plan.entries == 0 and #symlink_subtree_plan.failed == 1,
      '链接目标进入源子树必须被拒绝')
    assert(symlink_subtree_plan.failed[1]:find('inside itself', 1, true),
      '链接进入自身子树被拒绝必须说明跳过的源')
  end)
end

T["符号链接、路径重定向及 cut 同步使用物理路径"] = function()
  child.lua_func(function()
    local F = dofile(vim.env.VV_TEST_REPO .. '/tests/fixtures/transfer.lua')()
    local Transfer, Fs, temporary, sources, destination = F.Transfer, F.Fs, F.temporary, F.sources, F.destination
    local physical_alias_destination = temporary .. '/physical-alias-destination'
    local logical_alias_destination = temporary .. '/logical-alias-destination'
    assert(vim.fn.mkdir(physical_alias_destination, 'p') == 1)
    assert(vim.uv.fs_symlink(physical_alias_destination, logical_alias_destination))
    local alias_source = sources .. '/alias-source.txt'
    vim.fn.writefile({ 'symlinked destination parent' }, alias_source)
    local alias_plan = Transfer.plan({ alias_source }, logical_alias_destination, 'copy')
    assert(alias_plan.entries[1].destination == logical_alias_destination .. '/alias-source.txt',
      'plan 输出必须保留 explorer 目标别名')
    assert(alias_plan.entries[1].destination_path == physical_alias_destination .. '/alias-source.txt',
      '文件系统操作必须解析目标父目录符号链接')
    local alias_result = Transfer.execute(alias_plan, 'increment')
    assert(alias_result.completed == 1, '经符号链接目标父目录复制必须完成')
    assert(alias_result.last_dest == logical_alias_destination .. '/alias-source.txt',
      '粘贴聚焦路径必须保持 explorer 的目标命名空间')
    assert(vim.fn.readfile(physical_alias_destination .. '/alias-source.txt')[1]
      == 'symlinked destination parent',
      '链接目标父目录必须收到复制条目')

    local retarget_source = sources .. '/retarget-source.txt'
    local retarget_a = temporary .. '/retarget-a'
    local retarget_b = temporary .. '/retarget-b'
    local retarget_parent = temporary .. '/retarget-parent'
    vim.fn.writefile({ 'retarget source' }, retarget_source)
    assert(vim.fn.mkdir(retarget_a, 'p') == 1)
    assert(vim.fn.mkdir(retarget_b, 'p') == 1)
    assert(vim.uv.fs_symlink(retarget_a, retarget_parent))
    local retarget_plan = Transfer.plan({ retarget_source }, retarget_parent, 'copy')
    assert(vim.fn.delete(retarget_parent) == 0)
    assert(vim.uv.fs_symlink(retarget_b, retarget_parent))
    local retarget_before_execute = Transfer.execute(retarget_plan, 'increment')
    assert(retarget_before_execute.completed == 0 and #retarget_before_execute.failed == 1,
      '执行前目标父目录重定向必须中止粘贴')
    assert(vim.fn.filereadable(retarget_a .. '/retarget-source.txt') == 0
      and vim.fn.filereadable(retarget_b .. '/retarget-source.txt') == 0,
      '执行前目标重定向不得向任一目标复制')

    assert(vim.fn.delete(retarget_parent) == 0)
    assert(vim.uv.fs_symlink(retarget_a, retarget_parent))
    local retarget_boundary_plan = Transfer.plan({ retarget_source }, retarget_parent, 'copy')
    local retarget_copy = Fs.copy
    local retargeted_during_stage = false
    Fs.copy = function(source_path, destination_path)
      local copied = retarget_copy(source_path, destination_path)
      if not retargeted_during_stage
        and destination_path:find('%.vv%-explorer%-stage%-', 1, false)
      then
        retargeted_during_stage = true
        assert(vim.fn.delete(retarget_parent) == 0)
        assert(vim.uv.fs_symlink(retarget_b, retarget_parent))
      end
      return copied
    end
    local retarget_at_boundary = Transfer.execute(retarget_boundary_plan, 'increment')
    Fs.copy = retarget_copy
    assert(retargeted_during_stage, '必须触发安装边界重定向')
    assert(retarget_at_boundary.completed == 0 and #retarget_at_boundary.failed == 1,
      '暂存期间目标父目录重定向必须中止粘贴')
    assert(vim.fn.filereadable(retarget_a .. '/retarget-source.txt') == 0
      and vim.fn.filereadable(retarget_b .. '/retarget-source.txt') == 0,
      '安装边界重定向必须释放预留且不发布')
    assert(vim.fn.glob(retarget_a .. '/.retarget-source.txt.vv-explorer-*', false, true)[1] == nil,
      '安装边界重定向不得留下预留清理孤儿')

    local physical_source_parent = temporary .. '/physical-source-parent'
    local logical_source_parent = temporary .. '/logical-source-parent'
    assert(vim.fn.mkdir(physical_source_parent, 'p') == 1)
    assert(vim.uv.fs_symlink(physical_source_parent, logical_source_parent))
    local logical_cut_source = logical_source_parent .. '/sync-source.txt'
    local physical_cut_source = physical_source_parent .. '/sync-source.txt'
    vim.fn.writefile({ 'sync source' }, logical_cut_source)
    local sync_plan = Transfer.plan({ logical_cut_source }, destination, 'cut')
    local sync_buffers = Fs.sync_buffers
    local synced_source
    local synced_destination
    Fs.sync_buffers = function(source_path, destination_path)
      synced_source = source_path
      synced_destination = destination_path
    end
    local sync_result = Transfer.execute(sync_plan, 'increment')
    Fs.sync_buffers = sync_buffers
    assert(sync_result.completed == 1, '经链接源父目录剪切必须完成')
    assert(synced_source == physical_cut_source,
      '剪切 buffer 同步必须使用物理源路径')
    assert(synced_destination == destination .. '/sync-source.txt',
      '剪切 buffer 同步必须保留物理目标路径')
    assert(vim.fn.filereadable(physical_cut_source) == 0,
      '经链接源父目录剪切必须移除物理源')
    assert(vim.fn.readfile(destination .. '/sync-source.txt')[1] == 'sync source',
      '经链接源父目录剪切必须发布源内容')

    local symlink_source_target = temporary .. '/symlink-source-target'
    local symlink_source = temporary .. '/symlink-source'
    assert(vim.fn.mkdir(symlink_source_target, 'p') == 1)
    assert(vim.uv.fs_symlink(symlink_source_target, symlink_source))
    local symlink_source_plan = Transfer.plan({ symlink_source }, symlink_source_target, 'copy')
    assert(#symlink_source_plan.entries == 1,
      '不能仅因链接指向的目录包含目标就拒绝链接源')
    local symlink_source_result = Transfer.execute(symlink_source_plan, 'increment')
    assert(symlink_source_result.completed == 1, '复制符号链接源必须完成')
    local copied_symlink = symlink_source_target .. '/symlink-source'
    local copied_symlink_stat = vim.uv.fs_lstat(copied_symlink)
    assert(copied_symlink_stat and copied_symlink_stat.type == 'link',
      '复制符号链接必须保留链接条目')
    assert(vim.uv.fs_readlink(copied_symlink) == symlink_source_target,
      '复制符号链接必须保留链接目标')
  end)
end

T["原子目标预留、发布竞争、清理失败与超过百个重名"] = function()
  child.lua_func(function()
    local F = dofile(vim.env.VV_TEST_REPO .. '/tests/fixtures/transfer.lua')()
    local Transfer, Fs, temporary, sources, destination = F.Transfer, F.Fs, F.temporary, F.sources, F.destination
    local reservation_source = sources .. '/reservation-race.txt'
    local reservation_destination = destination .. '/reservation-race.txt'
    vim.fn.writefile({ 'reservation source' }, reservation_source)
    local reservation_plan = Transfer.plan({ reservation_source }, destination, 'copy')
    local reservation_copy = Fs.copy
    local concurrent_create_blocked = false
    Fs.copy = function(source_path, destination_path)
      local copied = reservation_copy(source_path, destination_path)
      if destination_path:find('%.vv%-explorer%-stage%-', 1, false) then
        local fd, create_error = vim.uv.fs_open(reservation_destination, 'wx', 420)
        if fd then
          vim.uv.fs_close(fd)
        else
          concurrent_create_blocked = tostring(create_error):find('EEXIST', 1, true) ~= nil
        end
      end
      return copied
    end
    local reservation_result = Transfer.execute(reservation_plan, 'increment')
    Fs.copy = reservation_copy
    assert(concurrent_create_blocked,
      '原子并发创建必须发现递增目标已被预留')
    assert(reservation_result.completed == 1, '已预留递增目标仍必须发布')
    assert(vim.fn.readfile(reservation_destination)[1] == 'reservation source',
      '递增发布不得覆盖并发预留')

    local reservation_backup_source = sources .. '/reservation-backup-race.txt'
    local reservation_backup_destination = destination .. '/reservation-backup-race.txt'
    vim.fn.writefile({ 'reservation backup source' }, reservation_backup_source)
    local reservation_backup_plan = Transfer.plan(
      { reservation_backup_source }, destination, 'copy'
    )
    local reservation_backup_rename = Fs.rename
    local reservation_backup_injected = false
    Fs.rename = function(source_path, destination_path)
      local renamed = reservation_backup_rename(source_path, destination_path)
      if not reservation_backup_injected
        and destination_path:find('%.vv%-explorer%-backup%-', 1, false)
      then
        reservation_backup_injected = true
        vim.fn.writefile({ 'created after reservation backup' }, reservation_backup_destination)
      end
      return renamed
    end
    local reservation_backup_result = Transfer.execute(reservation_backup_plan, 'increment')
    Fs.rename = reservation_backup_rename
    assert(reservation_backup_result.completed == 0 and #reservation_backup_result.failed == 1,
      '递增预留备份后出现新目标必须中止发布')
    assert(vim.fn.readfile(reservation_backup_destination)[1] == 'created after reservation backup',
      '预留备份后并发出现的目标必须保留')
    assert(vim.fn.glob(destination .. '/.*vv-explorer-backup-*', false, true)[1] == nil,
      '递增发布失败不得留下隐藏备份孤儿')
    assert(vim.fn.filereadable(reservation_backup_destination .. ' (recovery)') == 0,
      '空递增预留不得留下可见孤儿恢复项')

    local reservation_cleanup_source = sources .. '/reservation-cleanup-failure.txt'
    local reservation_cleanup_destination = destination .. '/reservation-cleanup-failure.txt'
    vim.fn.writefile({ 'reservation cleanup source' }, reservation_cleanup_source)
    local reservation_cleanup_plan = Transfer.plan(
      { reservation_cleanup_source }, destination, 'copy'
    )
    local reservation_cleanup_delete = Fs.delete
    local reservation_cleanup_failed = false
    Fs.delete = function(path)
      if path:find('%.vv%-explorer%-backup%-', 1, false) then
        reservation_cleanup_failed = true
        error('injected reservation backup cleanup failure')
      end
      if reservation_cleanup_failed then error('injected reservation cleanup failure') end
      return reservation_cleanup_delete(path)
    end
    local reservation_cleanup_result = Transfer.execute(reservation_cleanup_plan, 'increment')
    Fs.delete = reservation_cleanup_delete
    assert(reservation_cleanup_failed, '必须触发预留备份清理失败')
    assert(reservation_cleanup_result.completed == 1 and #reservation_cleanup_result.failed == 0,
      '预留清理失败不得回滚已提交复制')
    assert(#reservation_cleanup_result.warnings == 1
      and reservation_cleanup_result.warnings[1]:find('increment reservation cleanup', 1, true),
      '预留清理失败必须报告预留相关说明')
    assert(vim.fn.readfile(reservation_cleanup_destination)[1] == 'reservation cleanup source',
      '预留清理失败必须保留已提交目标')
    assert(vim.fn.filereadable(reservation_cleanup_destination .. ' (recovery)') == 0,
      '预留清理失败不得创建空的可见恢复项')

    -- 超过旧的百个重名范围只能影响当前条目，不得中止此前已完成的传输。
    local exhaustion_first_source = sources .. '/exhaustion-first.txt'
    local exhaustion_source = sources .. '/exhaustion.txt'
    vim.fn.writefile({ 'first exhaustion source' }, exhaustion_first_source)
    vim.fn.writefile({ 'exhaustion source' }, exhaustion_source)
    vim.fn.writefile({ 'existing exhaustion destination' }, destination .. '/exhaustion.txt')
    for index = 1, 100 do
      local suffix = index == 1 and ' (copy)' or (' (copy %d)'):format(index)
      vim.fn.writefile({ 'occupied ' .. tostring(index) }, destination .. '/exhaustion' .. suffix .. '.txt')
    end
    local exhaustion_ok, exhaustion_result = pcall(function()
      return Transfer.execute(Transfer.plan(
        { exhaustion_first_source, exhaustion_source }, destination, 'copy'
      ), 'increment')
    end)
    assert(exhaustion_ok, tostring(exhaustion_result))
    assert(exhaustion_result.completed == 2 and #exhaustion_result.failed == 0,
      '超过百个递增候选不得中止整批传输')
    assert(vim.fn.readfile(destination .. '/exhaustion-first.txt')[1] == 'first exhaustion source',
      '候选耗尽前已完成传输必须仍保持完成')
    assert(vim.fn.readfile(destination .. '/exhaustion (copy 101).txt')[1] == 'exhaustion source',
      '递增必须继续超过旧的百个重名范围')
  end)
end

T["临时槽身份竞争与部分清理失败转为可见恢复"] = function()
  child.lua_func(function()
    local F = dofile(vim.env.VV_TEST_REPO .. '/tests/fixtures/transfer.lua')()
    local Transfer, Fs, temporary, sources, destination = F.Transfer, F.Fs, F.temporary, F.sources, F.destination
    -- 暂存失败时内容可能已被其他参与者接管；必须保留容器，不能猜路径删内容。
    local stage_race_source = sources .. '/stage-race.txt'
    vim.fn.writefile({ 'stage source' }, stage_race_source)
    local stage_race_plan = Transfer.plan({ stage_race_source }, destination, 'copy')
    local stage_copy = Fs.copy
    local stage_payload
    Fs.copy = function(source_path, destination_path)
      if destination_path:find('%.vv%-explorer%-stage%-', 1, false) then
        stage_payload = destination_path
        vim.fn.writefile({ 'external stage payload' }, destination_path)
        error('injected stage preemption')
      end
      return stage_copy(source_path, destination_path)
    end
    local stage_race = Transfer.execute(stage_race_plan, 'increment')
    Fs.copy = stage_copy
    assert(stage_race.completed == 0 and #stage_race.failed == 1,
      '暂存被接管必须失败，不得报告复制成功')
    assert(stage_payload and vim.fn.readfile(stage_payload)[1] == 'external stage payload',
      '暂存被接管后不得删除其中内容')
    assert(vim.fn.isdirectory(vim.fs.dirname(stage_payload)) == 1,
      '暂存被接管必须保留私有容器')
    local stage_container_stat = vim.uv.fs_stat(vim.fs.dirname(stage_payload))
    assert(stage_container_stat and stage_container_stat.mode % 4096 == 448,
      '私有暂存容器必须使用 0700 权限')

    -- 覆盖提交后备份可能被替换；身份检查必须保留其容器，不得删掉新内容。
    local backup_replacement_source = sources .. '/backup-replacement.txt'
    local backup_replacement_destination = destination .. '/backup-replacement.txt'
    vim.fn.writefile({ 'new backup replacement source' }, backup_replacement_source)
    vim.fn.writefile({ 'old backup replacement destination' }, backup_replacement_destination)
    local backup_replacement_plan = Transfer.plan(
      { backup_replacement_source }, destination, 'copy'
    )
    local Paths = require('vv-explorer.transfer.paths')
    local original_checktime = Paths.checktime_under
    local backup_payload
    local backup_replacement_injected = false
    Paths.checktime_under = function(...)
      local result = original_checktime(...)
      if not backup_replacement_injected then
        local container = vim.fn.glob(
          destination .. '/.backup-replacement.txt.vv-explorer-backup-*', false, true
        )[1]
        backup_payload = container and vim.fs.joinpath(container, 'payload') or nil
        assert(backup_payload and vim.fn.filereadable(backup_payload) == 1,
          '清理边界前必须存在已提交的备份内容')
        assert(vim.uv.fs_unlink(backup_payload))
        vim.fn.writefile({ 'external backup replacement' }, backup_payload)
        backup_replacement_injected = true
      end
      return result
    end
    local backup_replacement = Transfer.execute(backup_replacement_plan, 'overwrite')
    Paths.checktime_under = original_checktime
    assert(backup_replacement.completed == 1,
      '备份被替换后已提交覆盖仍必须保持完成')
    assert(backup_replacement_injected, '已提交备份被替换必须触发清理')
    assert(backup_payload and vim.fn.readfile(backup_payload)[1] == 'external backup replacement',
      '提交后被替换的备份不得删除')
    assert(vim.fn.isdirectory(vim.fs.dirname(backup_payload)) == 1,
      '被替换的备份必须保留其容器')

    -- 新内容提交后备份处置删除失败，必须还原并移到可见恢复路径，不能留下隐藏孤儿。
    local backup_cleanup_failure_source = sources .. '/backup-cleanup-failure.txt'
    local backup_cleanup_failure_destination = destination .. '/backup-cleanup-failure.txt'
    vim.fn.writefile({ 'new backup cleanup source' }, backup_cleanup_failure_source)
    vim.fn.writefile({ 'old backup cleanup destination' }, backup_cleanup_failure_destination)
    local backup_cleanup_failure_plan = Transfer.plan(
      { backup_cleanup_failure_source }, destination, 'copy'
    )
    local backup_cleanup_delete = Fs.delete
    local backup_cleanup_delete_injected = false
    Fs.delete = function(path)
      if path:find('%.vv%-explorer%-backup%-', 1, false) and path:sub(-8) == '/dispose' then
        backup_cleanup_delete_injected = true
        error('injected committed backup cleanup failure')
      end
      return backup_cleanup_delete(path)
    end
    local backup_cleanup_ok, backup_cleanup_result = pcall(function()
      return Transfer.execute(backup_cleanup_failure_plan, 'overwrite')
    end)
    Fs.delete = backup_cleanup_delete
    assert(backup_cleanup_ok, tostring(backup_cleanup_result))
    assert(backup_cleanup_delete_injected,
      '备份提交后清理失败必须触发处置删除边界')
    assert(backup_cleanup_result.completed == 1 and #backup_cleanup_result.failed == 0,
      '备份提交后清理失败不得回滚新内容')
    assert(vim.fn.readfile(backup_cleanup_failure_destination)[1] == 'new backup cleanup source',
      '备份清理失败后替换内容必须保留在目标')
    assert(vim.fn.readfile(backup_cleanup_failure_destination .. ' (recovery)')[1]
      == 'old backup cleanup destination',
      '备份清理失败后旧目标必须移到可见恢复路径')
    assert(vim.fn.glob(
      destination .. '/.backup-cleanup-failure.txt.vv-explorer-backup-*', false, true
    )[1] == nil, '备份清理失败不得留下隐藏备份容器')

    -- 递归清理可能先删一部分再遇到只读子项失败；剩余内容必须成为可见恢复树。
    local partial_cleanup_source = sources .. '/partial-cleanup-dir'
    local partial_cleanup_destination = destination .. '/partial-cleanup-dir'
    vim.fn.mkdir(partial_cleanup_source, 'p')
    vim.fn.mkdir(partial_cleanup_destination .. '/read-only', 'p')
    vim.fn.writefile({ 'new partial cleanup content' }, partial_cleanup_source .. '/new.txt')
    vim.fn.writefile({ 'must remain recoverable' }, partial_cleanup_destination .. '/read-only/keep.txt')
    vim.fn.writefile({ 'another old file' }, partial_cleanup_destination .. '/other.txt')
    assert(vim.uv.fs_chmod(partial_cleanup_destination .. '/read-only', 365))
    local partial_cleanup_plan = Transfer.plan({ partial_cleanup_source }, destination, 'copy')
    local partial_cleanup_delete = Fs.delete
    local partial_cleanup_injected = false
    Fs.delete = function(path)
      if not partial_cleanup_injected
        and path:find('%.partial%-cleanup%-dir%.vv%-explorer%-backup%-', 1, false)
        and path:sub(-8) == '/dispose'
      then
        partial_cleanup_injected = true
        partial_cleanup_delete(vim.fs.joinpath(path, 'other.txt'))
        return partial_cleanup_delete(path)
      end
      return partial_cleanup_delete(path)
    end
    local partial_cleanup_ok, partial_cleanup_result = pcall(function()
      return Transfer.execute(partial_cleanup_plan, 'overwrite')
    end)
    Fs.delete = partial_cleanup_delete
    assert(partial_cleanup_ok, tostring(partial_cleanup_result))
    assert(partial_cleanup_injected, '必须触发部分处置清理')
    assert(partial_cleanup_result.completed == 1 and #partial_cleanup_result.failed == 0,
      '部分备份清理失败不得回滚已提交复制')
    assert(vim.fn.readfile(partial_cleanup_destination .. '/new.txt')[1]
      == 'new partial cleanup content', '替换内容必须保留在目标')
    assert(vim.fn.readfile(partial_cleanup_destination .. ' (recovery)/read-only/keep.txt')[1]
      == 'must remain recoverable', '剩余处置内容必须在恢复路径可见')
    assert(vim.uv.fs_lstat(partial_cleanup_destination .. ' (recovery)/other.txt') == nil,
      '清理失败前已删除的子项不得复活')
    assert(vim.uv.fs_chmod(
      partial_cleanup_destination .. ' (recovery)/read-only', 493
    ))
    assert(vim.fn.glob(
      destination .. '/.partial-cleanup-dir.vv-explorer-backup-*', false, true
    )[1] == nil, '部分清理恢复不得留下隐藏备份容器')
  end)
end

T["备份恢复失败和发布竞争保留旧目标与新文件"] = function()
  child.lua_func(function()
    local F = dofile(vim.env.VV_TEST_REPO .. '/tests/fixtures/transfer.lua')()
    local Transfer, Fs, temporary, sources, destination = F.Transfer, F.Fs, F.temporary, F.sources, F.destination
    -- 目标目录不可写导致失败事务无法恢复备份时，必须保留旧目标唯一副本。
    assert(vim.fn.has('unix') == 1, '备份权限恢复测试需要 POSIX 文件系统；不得静默跳过')
    do
      local failed_backup_source = sources .. '/failed-backup.txt'
      local failed_backup_destination = destination .. '/failed-backup.txt'
      vim.fn.writefile({ 'new failed backup content' }, failed_backup_source)
      vim.fn.writefile({ 'unique old failed backup content' }, failed_backup_destination)
      local failed_backup_plan = Transfer.plan({ failed_backup_source }, destination, 'copy')
      local failed_backup_rename = Fs.rename
      local failed_backup_locked = false
      Fs.rename = function(source_path, destination_path)
        local renamed = failed_backup_rename(source_path, destination_path)
        if not failed_backup_locked
          and destination_path:find('%.failed%-backup%.txt%.vv%-explorer%-backup%-', 1, false)
        then
          failed_backup_locked = true
          assert(vim.uv.fs_chmod(destination, 320))
        end
        return renamed
      end
      local failed_backup_ok, failed_backup_result = pcall(function()
        return Transfer.execute(failed_backup_plan, 'overwrite')
      end)
      Fs.rename = failed_backup_rename
      assert(vim.uv.fs_chmod(destination, 493))
      assert(failed_backup_ok, tostring(failed_backup_result))
      assert(failed_backup_locked, '事务失败必须触发备份保护')
      assert(failed_backup_result.completed == 0 and #failed_backup_result.failed == 1,
        '备份恢复失败必须仍报告传输失败')
      local failed_backup_container = vim.fn.glob(
        destination .. '/.failed-backup.txt.vv-explorer-backup-*', false, true
      )[1]
      assert(failed_backup_container and vim.fn.readfile(
        vim.fs.joinpath(failed_backup_container, 'payload')
      )[1] == 'unique old failed backup content',
        '事务失败必须保留唯一的旧目标内容')
      assert(vim.fn.filereadable(failed_backup_destination) == 0,
        '事务失败不得发布部分替换内容')
    end

    local race_source = sources .. '/race.txt'
    local race_destination = destination .. '/race.txt'
    vim.fn.writefile({ 'planned source' }, race_source)
    vim.fn.writefile({ 'planned destination' }, race_destination)
    local race_plan = Transfer.plan({ race_source }, destination, 'copy')
    local original_copy = Fs.copy
    Fs.copy = function(source_path, destination_path)
      original_copy(source_path, destination_path)
      vim.fn.writefile({ 'concurrent destination update that must survive' }, race_destination)
    end
    local race = Transfer.execute(race_plan, 'overwrite')
    Fs.copy = original_copy
    assert(race.completed == 0 and #race.failed == 1,
      '暂存期间目标变化必须中止替换')
    assert(vim.fn.readfile(race_destination)[1] == 'concurrent destination update that must survive',
      '事务回滚必须恢复暂存期间变更的目标')

    local backup_race_source = sources .. '/backup-race.txt'
    local backup_race_destination = destination .. '/backup-race.txt'
    vim.fn.writefile({ 'backup source' }, backup_race_source)
    vim.fn.writefile({ 'backup destination' }, backup_race_destination)
    local backup_race_plan = Transfer.plan({ backup_race_source }, destination, 'copy')
    local original_rename = Fs.rename
    local injected_destination = false
    Fs.rename = function(source_path, destination_path)
      local result = original_rename(source_path, destination_path)
      if not injected_destination and destination_path:find('%.vv%-explorer%-backup%-', 1, false) then
        injected_destination = true
        vim.fn.writefile({ 'created after backup' }, backup_race_destination)
      end
      return result
    end
    local backup_race = Transfer.execute(backup_race_plan, 'overwrite')
    Fs.rename = original_rename
    assert(backup_race.completed == 0 and #backup_race.failed == 1,
      '备份后出现新目标必须中止且不得报告成功')
    assert(vim.fn.readfile(backup_race_destination)[1] == 'created after backup',
      '备份后出现的新目标必须在回滚后保留')
    local recovery_path = backup_race_destination .. ' (recovery)'
    assert(vim.fn.readfile(recovery_path)[1] == 'backup destination',
      '被替换目标必须移到显式恢复路径')
    assert(vim.fn.glob(destination .. '/.backup-race.txt.vv-explorer-backup-*', false, true)[1] == nil,
      '覆盖失败不得留下隐藏孤儿备份')
  end)
end

T["同设备剪切完整替换目录并移除源"] = function()
  child.lua_func(function()
    local F = dofile(vim.env.VV_TEST_REPO .. '/tests/fixtures/transfer.lua')()
    local Transfer, Fs, temporary, sources, destination = F.Transfer, F.Fs, F.temporary, F.sources, F.destination
    local cut_source = sources .. '/move-me'
    assert(vim.fn.mkdir(cut_source, 'p') == 1)
    vim.fn.writefile({ 'moved' }, cut_source .. '/new.txt')
    assert(vim.fn.mkdir(destination .. '/move-me', 'p') == 1)
    vim.fn.writefile({ 'old' }, destination .. '/move-me/old.txt')
    local cut = Transfer.execute(Transfer.plan({ cut_source }, destination, 'cut'), 'overwrite')
    assert(cut.completed == 1, '剪切覆盖必须完成')
    assert(vim.fn.isdirectory(cut_source) == 0, '剪切覆盖必须移除源')
    assert(vim.fn.filereadable(destination .. '/move-me/new.txt') == 1, '剪切覆盖必须安装源内容')
    assert(vim.fn.filereadable(destination .. '/move-me/old.txt') == 0, '剪切覆盖必须替换目标')
  end)
end

T["跨设备剪切复制失败、源替换与部分清理失败可见恢复"] = function()
  child.lua_func(function()
    local F = dofile(vim.env.VV_TEST_REPO .. '/tests/fixtures/transfer.lua')()
    local Transfer, Fs, temporary, sources, destination = F.Transfer, F.Fs, F.temporary, F.sources, F.destination
    -- 只替换设备号查询；复制、隔离、发布、回滚和完整内容读回均走真实 /tmp 文件系统。
    local cross_destination = temporary .. '/cross-device-destination'
    local stat = vim.uv.fs_stat
    local device_probes = 0
    vim.uv.fs_stat = function(path, ...)
      local result = stat(path, ...)
      if result and path == cross_destination then
        result.dev = result.dev + 1
        device_probes = device_probes + 1
      end
      return result
    end
      local cross_source = sources .. '/cross-device'
      assert(vim.fn.mkdir(cross_source, 'p') == 1)
      assert(vim.fn.mkdir(cross_destination .. '/cross-device', 'p') == 1)
      vim.fn.writefile({ 'new cross-device content' }, cross_source .. '/new.txt')
      assert(vim.fn.mkdir(cross_source .. '/empty', 'p') == 1)
      local binary = assert(io.open(cross_source .. '/binary.dat', 'wb'))
      assert(binary:write('\239\187\191unchanged\r\n\0tail'))
      assert(binary:close())
      local cross_snapshot = F.read_tree(cross_source)
      vim.fn.writefile({ 'old cross-device content' }, cross_destination .. '/cross-device/old.txt')

      local cross_cut = Transfer.execute(Transfer.plan({ cross_source }, cross_destination, 'cut'), 'overwrite')
      assert(cross_cut.completed == 1, '跨设备剪切覆盖必须完成')
      assert(vim.fn.isdirectory(cross_source) == 0, '跨设备剪切发布后必须移除源')
      assert(vim.fn.filereadable(cross_destination .. '/cross-device/new.txt') == 1,
        '跨设备剪切必须发布完整源内容')
      assert(vim.deep_equal(F.read_tree(cross_destination .. '/cross-device'), cross_snapshot), '跨设备剪切必须保留空目录、BOM、CRLF、NUL 与末尾完整字节')
      assert(vim.fn.filereadable(cross_destination .. '/cross-device/old.txt') == 0,
        '跨设备剪切覆盖必须替换完整目标')

      local cross_race_source = sources .. '/cross-device-race'
      local cross_race_destination = cross_destination .. '/cross-device-race'
      assert(vim.fn.mkdir(cross_race_source, 'p') == 1)
      vim.fn.writefile({ 'original cross-device content' }, cross_race_source .. '/payload.txt')

      local original_delete = Fs.delete
      local injected_source_replacement = false
      Fs.delete = function(path)
        if not injected_source_replacement then
          injected_source_replacement = true
          vim.fn.writefile({ 'concurrent replacement must survive' }, cross_race_source)
        end
        return original_delete(path)
      end
      local cross_race_ok, cross_race = pcall(function()
        return Transfer.execute(Transfer.plan({ cross_race_source }, cross_destination, 'cut'), 'overwrite')
      end)
      Fs.delete = original_delete

      assert(cross_race_ok, '跨设备清理竞争不得从传输结果边界逃逸')
      assert(injected_source_replacement, '跨设备清理竞争必须触发删除边界')
      assert(cross_race.completed == 1, '跨设备剪切隔离源后必须完成')
      assert(vim.fn.readfile(cross_race_destination .. '/payload.txt')[1] == 'original cross-device content',
        '跨设备剪切必须复制隔离后的源快照')
      assert(vim.fn.readfile(cross_race_source)[1] == 'concurrent replacement must survive',
        '清理期间源路径被替换后不得静默删除新内容')

      local cross_failure_source = sources .. '/cross-device-copy-failure'
      local cross_failure_destination = cross_destination .. '/cross-device-copy-failure'
      assert(vim.fn.mkdir(cross_failure_source, 'p') == 1)
      vim.fn.writefile({ 'must be restored after copy failure' }, cross_failure_source .. '/payload.txt')
      local original_copy = Fs.copy
      Fs.copy = function(source_path, destination_path)
        if destination_path:find('%.vv%-explorer%-stage%-', 1, false) then
          error('injected cross-device copy failure')
        end
        return original_copy(source_path, destination_path)
      end
      local cross_failure_ok, cross_failure = pcall(function()
        return Transfer.execute(Transfer.plan({ cross_failure_source }, cross_destination, 'cut'), 'overwrite')
      end)
      Fs.copy = original_copy

      assert(cross_failure_ok, '跨设备复制失败必须包含在传输结果中')
      assert(cross_failure.completed == 0 and #cross_failure.failed == 1,
        '跨设备复制失败不得报告剪切完成')
      assert(vim.fn.readfile(cross_failure_source .. '/payload.txt')[1] == 'must be restored after copy failure',
        '跨设备复制失败必须恢复原源路径')
      assert(vim.fn.isdirectory(cross_failure_destination) == 0,
        '跨设备复制失败不得发布目标')
      assert(vim.fn.glob(sources .. '/.cross-device-copy-failure.vv-explorer-source-*', false, true)[1] == nil,
        '跨设备复制失败不得留下隔离源的暂存路径')

      local cleanup_restore_source = sources .. '/cross-device-cleanup-restore'
      local cleanup_restore_destination = cross_destination .. '/cross-device-cleanup-restore'
      assert(vim.fn.mkdir(cleanup_restore_source, 'p') == 1)
      vim.fn.writefile({ 'must survive cleanup failure' }, cleanup_restore_source .. '/payload.txt')
      local cleanup_delete = Fs.delete
      Fs.delete = function(path)
        error('injected source cleanup failure')
      end
      local cleanup_restore_ok, cleanup_restore = pcall(function()
        return Transfer.execute(Transfer.plan({ cleanup_restore_source }, cross_destination, 'cut'), 'overwrite')
      end)
      Fs.delete = cleanup_delete

      assert(cleanup_restore_ok, '清理失败必须包含在传输结果中')
      assert(cleanup_restore.completed == 0 and #cleanup_restore.failed == 1,
        '清理失败不得报告剪切完成')
      assert(vim.fn.readfile(cleanup_restore_source .. '/payload.txt')[1] == 'must survive cleanup failure',
        '源路径空缺时清理失败必须恢复原源内容')
      assert(vim.fn.isdirectory(cleanup_restore_source .. ' (recovery)') == 0,
        '源路径空缺时清理失败不得无故创建恢复项')
      assert(vim.fn.filereadable(cleanup_restore_destination .. '/payload.txt') == 1,
        '源清理失败时成功的跨设备复制必须仍可用')

      local cleanup_recovery_source = sources .. '/cross-device-cleanup-recovery'
      local cleanup_recovery_destination = cross_destination .. '/cross-device-cleanup-recovery'
      assert(vim.fn.mkdir(cleanup_recovery_source, 'p') == 1)
      vim.fn.writefile({ 'must be preserved in recovery' }, cleanup_recovery_source .. '/payload.txt')
      local replacement_delete = Fs.delete
      local replacement_created = false
      Fs.delete = function()
        if not replacement_created then
          replacement_created = true
          vim.fn.writefile({ 'concurrent source replacement' }, cleanup_recovery_source)
          error('injected cleanup failure after source replacement')
        end
        return replacement_delete(path)
      end
      local cleanup_recovery_ok, cleanup_recovery = pcall(function()
        return Transfer.execute(Transfer.plan({ cleanup_recovery_source }, cross_destination, 'cut'), 'overwrite')
      end)
      Fs.delete = replacement_delete

      assert(cleanup_recovery_ok, '源被替换时清理失败必须包含在传输结果中')
      assert(cleanup_recovery.completed == 0 and #cleanup_recovery.failed == 1,
        '源被替换时清理失败不得报告剪切完成')
      assert(vim.fn.readfile(cleanup_recovery_source)[1] == 'concurrent source replacement',
        '并发替换的源必须保留在原路径')
      assert(vim.fn.readfile(cleanup_recovery_source .. ' (recovery)/payload.txt')[1]
        == 'must be preserved in recovery',
        '原源路径被占用时隔离源必须移到可见恢复路径')
      assert(vim.fn.isdirectory(cleanup_recovery_destination) == 1,
        '源清理恢复后已复制目标必须仍可用')

      local partial_source_cleanup = sources .. '/cross-device-partial-cleanup'
      local partial_source_cleanup_destination = cross_destination .. '/cross-device-partial-cleanup'
      assert(vim.fn.mkdir(partial_source_cleanup .. '/read-only', 'p') == 1)
      vim.fn.writefile({ 'must remain in source recovery' }, partial_source_cleanup .. '/read-only/keep.txt')
      vim.fn.writefile({ 'removed before cleanup failed' }, partial_source_cleanup .. '/other.txt')
      assert(vim.uv.fs_chmod(partial_source_cleanup .. '/read-only', 365))
      local partial_source_cleanup_delete = Fs.delete
      local partial_source_cleanup_injected = false
      Fs.delete = function(path)
        if not partial_source_cleanup_injected
          and path:find('cross%-device%-partial%-cleanup%.vv%-explorer%-source%-', 1, false)
          and path:sub(-8) == '/dispose'
        then
          partial_source_cleanup_injected = true
          partial_source_cleanup_delete(vim.fs.joinpath(path, 'other.txt'))
          return partial_source_cleanup_delete(path)
        end
        return partial_source_cleanup_delete(path)
      end
      local partial_source_cleanup_ok, partial_source_cleanup_result = pcall(function()
        return Transfer.execute(Transfer.plan(
          { partial_source_cleanup }, cross_destination, 'cut'
        ), 'overwrite')
      end)
      Fs.delete = partial_source_cleanup_delete
      assert(partial_source_cleanup_ok, tostring(partial_source_cleanup_result))
      assert(partial_source_cleanup_injected, '必须触发部分源处置清理')
      assert(partial_source_cleanup_result.completed == 0 and #partial_source_cleanup_result.failed == 1,
        '部分源清理必须保持剪切失败标记')
      assert(vim.fn.readfile(
        partial_source_cleanup .. ' (recovery)/read-only/keep.txt'
      )[1] == 'must remain in source recovery',
        '剩余源内容必须在恢复路径可见')
      assert(vim.fn.isdirectory(partial_source_cleanup) == 0,
        '源恢复到恢复路径后原源路径必须保持缺失')
      assert(vim.uv.fs_lstat(partial_source_cleanup .. ' (recovery)/other.txt') == nil,
        '源清理失败前已删除的子项不得复活')
      assert(vim.fn.isdirectory(partial_source_cleanup_destination) == 1,
        '源恢复后已复制目标必须仍可用')
      assert(vim.uv.fs_chmod(
        partial_source_cleanup .. ' (recovery)/read-only', 493
      ))
      vim.fn.delete(cross_destination, 'rf')
    vim.uv.fs_stat = stat
    assert(device_probes > 0, '跨设备分支必须真正查询异设备目标目录')
  end)
end

return T

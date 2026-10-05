local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["LSP 编辑先暂存，移动失败回滚、成功仅保存允许的 buffer，整批只请求一次"] = function()
  child.lua_func(function()
    -- vv-explorer LSP 适配层：willRenameFiles 编辑先应用、后由 settle 决定保存或回滚
    --
    -- 只替换 LSP 客户端请求，WorkspaceEdit / buffer / 磁盘都是真实的

    local temporary = vim.fn.tempname()
    assert(vim.fn.mkdir(temporary, 'p') == 1)
    temporary = assert(vim.uv.fs_realpath(temporary))

    local unopened = temporary .. '/unopened.ts'      -- 未打开：编辑后应保存、临时 buffer 应清理
    local dirty = temporary .. '/dirty.ts'            -- 已打开且用户有未保存修改：编辑后不得替用户保存
    local moved_file = temporary .. '/moved.ts'       -- 被移动文件自身也是编辑目标
    for _, path in ipairs({ unopened, dirty, moved_file }) do vim.fn.writefile({ 'import "./old"' }, path) end

    local dirty_buf = vim.fn.bufadd(dirty)
    vim.fn.bufload(dirty_buf)
    vim.api.nvim_buf_set_lines(dirty_buf, 0, -1, false, { 'user unsaved edit', 'import "./old"' })

    local function text_edit(path, line)
      return {
        [vim.uri_from_fname(path)] = {
          { range = { start = { line = line, character = 8 }, ['end'] = { line = line, character = 13 } }, newText = './new' },
        },
      }
    end

    local fixture_clients = { { name = 'fixture-lsp' } }
    local requests = {}
    package.loaded['vv-utils.lsp.file_operations'] = {
      clients = function() return fixture_clients end,
      will_rename_many_async = function(renames, _, on_done)
        requests[#requests + 1] = renames
        local changes = vim.tbl_extend('error', text_edit(unopened, 0), text_edit(moved_file, 0), text_edit(dirty, 1))
        on_done({ { edit = { changes = changes }, encoding = 'utf-16' } }, false)
      end,
      notify_did_rename_many = function() end,
    }

    local Lsp = require('vv-explorer.lsp')

    local function request()
      local timed_out, pending
      Lsp.will_rename_async('/x/old.ts', '/x/new.ts', 1000, function(t, p) timed_out, pending = t, p end)
      assert(timed_out == false and pending, '编辑必须应用并作为 pending 返回')
      return pending
    end

    local function disk(path) return vim.fn.readfile(path)[1] end
    local function loaded_buf(path)
      local bufnr = vim.fn.bufnr(path)
      return bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) and bufnr or nil
    end

    -- 1) 应用后、settle 前：磁盘必须保持原样，否则 cut 的源快照复验会失败
    local pending = request()
    assert(disk(unopened) == 'import "./old"', '文件操作完成前编辑不得写盘')
    assert(disk(moved_file) == 'import "./old"', '真正移动前文件磁盘内容必须保持不变')
    assert(loaded_buf(unopened), '编辑必须应用到 buffer')

    -- 2) 移动失败：全部回滚，不留隐藏 modified buffer，用户自己的未保存修改保留
    pending.settle(false)
    assert(disk(unopened) == 'import "./old"', '回滚必须保持磁盘不变')
    assert(not loaded_buf(unopened), '回滚必须移除临时 buffer')
    local restored_lines = vim.api.nvim_buf_get_lines(dirty_buf, 0, -1, false)
    assert(restored_lines[1] == 'user unsaved edit' and restored_lines[2] == 'import "./old"',
      '回滚必须还原用户修改 buffer 的编辑前状态')
    assert(vim.bo[dirty_buf].modified, '回滚必须保留用户未保存状态')
    pending.settle(true) -- 幂等：已 settle 后再调用不能生效
    assert(disk(unopened) == 'import "./old"', 'settle 必须幂等')

    -- 3) 移动成功：未打开的文件被保存并清理；用户已有未保存修改的 buffer 不被写盘
    local notified = {}
    local original_notify = vim.notify
    vim.notify = function(message, level) notified[#notified + 1] = { message, level } end
    pending = request()
    pending.settle(true)
    vim.notify = original_notify

    assert(disk(unopened) == 'import "./new"', '未打开文件必须保存，避免用户错过编辑')
    assert(disk(moved_file) == 'import "./new"', '移动文件自身的编辑也必须保存')
    assert(not loaded_buf(unopened) and not loaded_buf(moved_file), '保存后必须清理临时 buffer')
    assert(disk(dirty) == 'import "./old"', '用户原有未保存修改不得被隐式保存')
    assert(vim.bo[dirty_buf].modified, '用户修改的 buffer 必须保持 modified')
    local function notices_at(level)
      local found = {}
      for _, note in ipairs(notified) do
        if note[2] == level then found[#found + 1] = note[1] end
      end
      return found
    end

    local warnings = notices_at(vim.log.levels.WARN)
    assert(#warnings == 1 and warnings[1]:find('unsaved changes', 1, true),
      '必须告知用户已有修改的 buffer 被编辑但未保存')

    -- 被自动保存的文件必须告知用户，否则没打开的文件被改了他永远不知道
    local infos = notices_at(vim.log.levels.INFO)
    assert(#infos == 1 and infos[1]:find('updated references in 2 file(s)', 1, true),
      '必须告知用户 LSP 改写并保存了哪些文件，实际：' .. vim.inspect(infos))
    assert(infos[1]:find('unopened.ts', 1, true) and infos[1]:find('moved.ts', 1, true), '通知必须列出已保存文件')
    assert(not infos[1]:find('dirty.ts', 1, true), '未保存的 buffer 不得被报告为已更新')

    -- 4) 多个文件必须合并成一次请求，且 renames 原样透传
    requests = {}
    local timed_out, batch_pending
    Lsp.will_rename_many_async({
      { old_path = '/x/a.ts', new_path = '/x/sub/a.ts' },
      { old_path = '/x/b.ts', new_path = '/x/sub/b.ts' },
    }, 1000, function(t, p) timed_out, batch_pending = t, p end)
    assert(#requests == 1 and #requests[1] == 2, '整批必须只发一次包含全部文件的请求')
    assert(requests[1][2].new_path == '/x/sub/b.ts')
    assert(timed_out == false and batch_pending)
    batch_pending.settle(false) -- 批量里只要有一项没移动成功，调用方就整体回滚
    assert(not loaded_buf(unopened), '部分失败回滚必须移除临时 buffer')

    vim.fn.delete(temporary, 'rf')
  end)
end

return T

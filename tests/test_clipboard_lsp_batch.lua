local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["剪切整批成功、部分失败与迟到 LSP 编辑正确结算并保留完整磁盘内容"] = function()
  child.lua_func(function()
    -- cut 粘贴触发 LSP 时「整批结果 → 如何收尾」的策略测试
    --
    -- 一、Lsp.settle_batch 纯函数：全成功 / 部分失败 / 全失败 / pending 为 nil
    -- 二、Actions.paste 级集成（真实的：Clipboard.attach、Transfer.execute_async、Lsp、WorkspaceEdit、磁盘）：
    --   成功、部分失败、before_moves 中途抛错后 LSP 回调迟到
    --
    -- 桩掉的：vv-utils.lsp.file_operations（协议层）、vv-utils.state（共享剪贴板落盘）、
    --   vv-utils.loading（计数 mark/stop，记录 mark 的 opts）、render / tree
    -- 不覆盖：
    --   * 真实 LSP 服务端与超时分支（timed_out 的 WARN 与本策略无关）
    --   * 冲突弹窗（prompt）路径，那条路径在 test_clipboard_modal 里测；这里用 increment 直接进 execute
    --   * after_moves 抛错被 Transfer 的 pcall 吞掉的分支，settle_batch 自身不会抛

    local root = vim.env.VV_TEST_REPO
    vim.o.confirm = false

    local function eq(actual, expected, message)
      if not vim.deep_equal(actual, expected) then
        error(('%s\n  期望：%s\n  实际：%s'):format(message, vim.inspect(expected), vim.inspect(actual)), 2)
      end
    end

    -- 协议层桩：记录 didRename，willRename 的行为由各场景通过 will_rename 注入
    local did_rename_calls = {}
    local will_rename -- fun(renames, on_done)
    package.loaded['vv-utils.lsp.file_operations'] = {
      clients = function() return { { name = 'fixture-lsp' } } end,
      will_rename_many_async = function(renames, _, on_done) will_rename(renames, on_done) end,
      -- 与真实实现一致：空数组不发送
      notify_did_rename_many = function(renames)
        if #renames == 0 then return end
        did_rename_calls[#did_rename_calls + 1] = vim.deepcopy(renames)
      end,
    }

    local shared_record
    package.preload['vv-utils.state'] = function()
      return {
        register = function()
          return {
            get = function() return vim.deepcopy(shared_record) end,
            set = function(_, _, value) shared_record = vim.deepcopy(value) return true end,
            remove = function() shared_record = nil return true end,
            compare_and_set = function(_, _, expected, value)
              if not vim.deep_equal(shared_record, expected) then return false, vim.deepcopy(shared_record) end
              shared_record = vim.deepcopy(value)
              return true, vim.deepcopy(shared_record)
            end,
          }
        end,
      }
    end

    local loading = { started = 0, stopped = 0 }
    package.preload['vv-utils.loading'] = function()
      return {
        mark = function(opts)
          loading.started = loading.started + 1
          loading.opts = opts
          return { stop = function() loading.stopped = loading.stopped + 1 end }
        end,
      }
    end
    package.preload['vv-explorer.render'] = function() return { render = function() end } end
    package.preload['vv-explorer.tree'] = function() return { expand_to = function() end } end

    local Lsp = require('vv-explorer.lsp')
    local ClipboardStore = require('vv-explorer.clipboard_store')
    local Clipboard = require('vv-explorer.actions.clipboard')

    local notices = {}
    vim.notify = function(message, level) notices[#notices + 1] = { message = message, level = level } end

    local function has_notice(fragment, level)
      for _, notice in ipairs(notices) do
        if notice.message:find(fragment, 1, true) and (level == nil or notice.level == level) then return true end
      end
      return false
    end

    local function reset()
      did_rename_calls = {}
      notices = {}
      loading.started, loading.stopped, loading.opts = 0, 0, nil
    end

    ---@return table pending, table calls
    local function fake_pending()
      local calls = {}
      return { settle = function(moved) calls[#calls + 1] = moved end }, calls
    end

    local function outcome(name, moved)
      return { source = '/src/' .. name, destination = '/dst/' .. name, moved = moved }
    end
    local function rename(name) return { old_path = '/src/' .. name, new_path = '/dst/' .. name } end

    -- 一、纯函数 ---------------------------------------------------------------------------

    -- 全部成功：保存编辑、不 WARN、didRename 带全部
    reset()
    local pending, settles = fake_pending()
    local result = Lsp.settle_batch(pending, { outcome('a', true), outcome('b', true) })
    eq(settles, { true }, '全部移动：settle(true) 恰好一次')
    eq(did_rename_calls, { { rename('a'), rename('b') } }, '全部移动：单次 didRename 携带所有文件')
    eq(#notices, 0, '全部移动：不得警告')
    eq(result.all_moved, true, '全部移动：result.all_moved 必须为真')

    -- 部分失败：整体回滚 + WARN + didRename 只含成功项（顺序保持）
    reset()
    pending, settles = fake_pending()
    result = Lsp.settle_batch(pending, { outcome('a', true), outcome('b', false), outcome('c', true) })
    eq(settles, { false }, '部分失败：settle(false)')
    eq(did_rename_calls, { { rename('a'), rename('c') } }, '部分失败：只对已移动文件发 didRename')
    assert(has_notice('imports of the moved files were not updated', vim.log.levels.WARN), '部分失败：必须有 WARN 通知')
    eq(result.all_moved, false, '部分失败：result.all_moved 必须为假')

    -- 全部失败：回滚，但没有已移动文件，所以既不发 didRename，也不说「已移动文件的 import 没更新」
    reset()
    pending, settles = fake_pending()
    Lsp.settle_batch(pending, { outcome('a', false), outcome('b', false) })
    eq(settles, { false }, '全部未移动：settle(false)')
    eq(did_rename_calls, {}, '全部未移动：不得发 didRename')
    assert(not has_notice('imports of the moved files'), '全部未移动：不得误导性警告')

    -- pending 为 nil（无编辑 / 编辑失败）：不报错，部分失败时也不 WARN，仍对已移动项发 didRename
    reset()
    local ok, err = pcall(Lsp.settle_batch, nil, { outcome('a', true), outcome('b', false) })
    assert(ok, tostring(err))
    eq(did_rename_calls, { { rename('a') } }, 'pending 为空：仍必须对已移动文件发 didRename')
    assert(not has_notice('imports of the moved files'), 'pending 为空：无编辑时不得警告')

    -- 二、Actions.paste 级集成 --------------------------------------------------------------

    local temporary = assert(vim.uv.fs_realpath((function()
      local dir = vim.fn.tempname()
      assert(vim.fn.mkdir(dir, 'p') == 1)
      return dir
    end)()))

    local Actions = {}
    local Helpers = {
      ensure_state_fields = function() end,
      selected_paths = function() return {} end,
      focus_path = function() end,
    }
    Clipboard.attach(Actions, Helpers, {
      target_node = function(state) return state.root end,
      dir_context = function(_, node) return node.path end,
      after_fs_change = function() end,
    })

    local function disk(path) return vim.fn.readfile(path)[1] end

    local function new_fixture(name)
      local base = temporary .. '/' .. name
      assert(vim.fn.mkdir(base .. '/src', 'p') == 1)
      assert(vim.fn.mkdir(base .. '/dst', 'p') == 1)
      local f = { src = base .. '/src', dst = base .. '/dst', other = base .. '/other.ts' }
      vim.fn.writefile({ 'import "./a"' }, f.src .. '/a.ts')
      vim.fn.writefile({ 'import "./a"' }, f.src .. '/b.ts')
      vim.fn.writefile({ 'import "./old"' }, f.other)
      vim.cmd('silent! %bwipeout!')
      return f
    end

    local function lsp_edit(f)
      return {
        {
          edit = {
            changes = {
              [vim.uri_from_fname(f.other)] = {
                { range = { start = { line = 0, character = 8 }, ['end'] = { line = 0, character = 13 } }, newText = './new' },
              },
            },
          },
          encoding = 'utf-16',
        },
      }
    end

    ---@param f table
    ---@return table state
    local function new_state(f)
      local buf = vim.api.nvim_create_buf(false, true)
      return {
        root = { path = f.dst, name = 'dst', is_dir = true },
        buf = buf,
        path_to_row = { [f.src .. '/a.ts'] = 1, [f.src .. '/b.ts'] = 2 },
        opts = { clipboard = { conflict = 'increment' }, lsp_rename_timeout_ms = 1000 },
      }
    end

    local function paste(f, state)
      assert(ClipboardStore.write('cut', { f.src .. '/a.ts', f.src .. '/b.ts' }))
      Actions.paste(state)
      assert(state._transferring == true, '等待 LSP 时粘贴必须标记 transferring')
      assert(vim.wait(3000, function() return state._transferring == nil end), '粘贴必须完成')
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

    -- 场景 1：整批成功。编辑落盘，didRename 一次含全部，状态与 loading 复位
    reset()
    local f = new_fixture('success')
    will_rename = function(_, on_done) on_done(lsp_edit(f), false) end
    local state = new_state(f)
    paste(f, state)
    eq(disk(f.dst .. '/a.ts'), 'import "./a"', '成功：文件必须移动')
    eq(disk(f.other), 'import "./new"', '成功：LSP 编辑必须保存')
    eq(did_rename_calls, { {
      { old_path = f.src .. '/a.ts', new_path = f.dst .. '/a.ts' },
      { old_path = f.src .. '/b.ts', new_path = f.dst .. '/b.ts' },
    } }, '成功：单次 didRename 携带所有已移动文件')
    eq(state._lsp_renaming, nil, '成功：清空 _lsp_renaming')
    -- 整批共用一个 handle（每行一个 handle 时每帧要跑 N 个 timer 回调），盖在图标槽上而不是挤在长名字的行尾
    eq(loading.started, 1, '成功：整批只有一个 loading 句柄')
    eq(loading.stopped, 1, '成功：整批 loading 句柄必须停止')
    eq(loading.opts.pos, 'overlay', '成功：loading 必须覆盖图标槽')
    eq(modified_named_buffers(), {}, '成功：不得残留 modified buffer')

    -- 场景 2：部分失败。b.ts 在快照之后被外部改动，commit 失败；整体回滚，didRename 只含 a.ts
    reset()
    f = new_fixture('partial')
    will_rename = function(_, on_done)
      vim.fn.writefile({ 'externally changed' }, f.src .. '/b.ts')
      on_done(lsp_edit(f), false)
    end
    state = new_state(f)
    paste(f, state)
    eq(disk(f.dst .. '/a.ts'), 'import "./a"', '部分失败：a 仍必须移动')
    assert(vim.uv.fs_stat(f.src .. '/b.ts'), '部分失败：b 保留在源路径')
    eq(disk(f.other), 'import "./old"', '部分失败：LSP 编辑不得写盘')
    eq(modified_named_buffers(), {}, '部分失败：回滚不得留下 modified buffer')
    eq(did_rename_calls, { { { old_path = f.src .. '/a.ts', new_path = f.dst .. '/a.ts' } } },
      '部分失败：只对已移动文件发 didRename')
    assert(has_notice('imports of the moved files were not updated', vim.log.levels.WARN), '部分失败：必须有 WARN 通知')
    eq(state._lsp_renaming, nil, '部分失败：清空 _lsp_renaming')
    assert(loading.started == loading.stopped and loading.started > 0, '部分失败：停止 loading')

    -- 场景 3：LSP 请求发出后 before_moves 抛错（Transfer 兜底直接 proceed），整批先结束，LSP 回调才迟到
    --   a. 此时 LSP 回调尚未触发（下面的断言先于 late_callback），loading 只能靠 execute_async 的完成回调（finish）
    --      里的 clear_loading 兜底，否则 loading 与 _lsp_renaming 永远残留；注意这里的「on_done」是测试里桩的 LSP 回调，不是 finish
    --   b. 迟到的编辑已经没人 settle，必须直接回滚，不能留下隐藏的 modified buffer
    reset()
    f = new_fixture('late')
    local late_callback
    will_rename = function(_, on_done)
      late_callback = on_done
      error('boom after the request was sent')
    end
    state = new_state(f)
    paste(f, state)
    eq(disk(f.dst .. '/a.ts'), 'import "./a"', '迟到：没有 LSP 编辑时文件仍必须移动')
    eq(state._lsp_renaming, nil, '迟到：完成回调必须在 LSP 回调前清空 _lsp_renaming')
    assert(loading.started > 0 and loading.stopped == loading.started, '迟到：完成回调必须在 LSP 回调前停止 loading')
    assert(late_callback, '迟到：必须已经发出请求')
    late_callback(lsp_edit(f), false)
    eq(modified_named_buffers(), {}, '迟到：完成后到达的编辑必须回滚')
    eq(disk(f.other), 'import "./old"', '迟到：编辑绝不能写盘')
    eq(state._transferring, nil, '迟到：不得恢复传输态')

    vim.fn.delete(temporary, 'rf')
  end)
end

return T

local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["真实冲突弹窗完整覆盖目录，过期记录与部分剪切保持共享剪贴板所有权"] = function()
  child.lua_func(function()
    -- 粘贴冲突集成：真实 Modal 选择、完整覆盖与过期剪贴板保护

    local root = vim.env.VV_TEST_REPO

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
    package.preload['vv-explorer.render'] = function()
      return { render = function() end }
    end
    package.preload['vv-explorer.tree'] = function()
      return { expand_to = function() end }
    end

    local ClipboardStore = require('vv-explorer.clipboard_store')
    local Clipboard = require('vv-explorer.actions.clipboard')
    local Fs = require('vv-utils.fs')

    local Actions = {}
    local Helpers = {
      ensure_state_fields = function() end,
      selected_paths = function() return {} end,
      focus_path = function() end,
    }
    local changed = 0
    local context = {
      target_node = function(state) return state.root end,
      dir_context = function(_, node) return node.path end,
      after_fs_change = function() changed = changed + 1 end,
    }
    Clipboard.attach(Actions, Helpers, context)

    local temporary = vim.fn.tempname()
    local source_root = temporary .. '/source'
    local destination_root = temporary .. '/destination'
    assert(vim.fn.mkdir(source_root .. '/widget', 'p') == 1)
    assert(vim.fn.mkdir(destination_root .. '/widget', 'p') == 1)
    vim.fn.writefile({ 'new' }, source_root .. '/widget/shared.txt')
    vim.fn.writefile({ 'source-only' }, source_root .. '/widget/source-only.txt')
    vim.fn.writefile({ 'old' }, destination_root .. '/widget/shared.txt')
    vim.fn.writefile({ 'destination-only' }, destination_root .. '/widget/destination-only.txt')

    local explorer_buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, explorer_buffer)
    local state = {
      root = { path = destination_root, name = 'destination', is_dir = true },
      buf = explorer_buffer,
      win = vim.api.nvim_get_current_win(),
      opts = { clipboard = { conflict = 'prompt' } },
    }

    assert(ClipboardStore.write('copy', { source_root .. '/widget' }))
    Actions.paste(state)
    local modal_window = vim.api.nvim_get_current_win()
    assert(modal_window ~= state.win, '粘贴冲突必须打开弹窗')
    local modal_buffer = vim.api.nvim_win_get_buf(modal_window)
    assert(vim.bo[modal_buffer].filetype == 'vv-modal',
      '粘贴冲突必须使用 vv-utils.modal')
    local modal_text = table.concat(vim.api.nvim_buf_get_lines(modal_buffer, 0, -1, false), '\n')
    assert(modal_text:find('%^o'), '弹窗必须把 <C-o> 规范化为 ^o')
    assert(modal_text:find('%^k'), '弹窗必须把 <C-k> 规范化为 ^k')
    vim.api.nvim_feedkeys(vim.keycode('<C-o>'), 'xt', false)

    assert(changed == 1, '覆盖动作必须报告一次文件系统变更')
    assert(vim.fn.readfile(destination_root .. '/widget/shared.txt')[1] == 'new',
      '覆盖动作必须安装源内容')
    assert(vim.fn.filereadable(destination_root .. '/widget/destination-only.txt') == 0,
      '覆盖动作必须替换完整目录而非合并')
    assert(shared_record == nil, '复制粘贴成功必须清空共享剪贴板')

    assert(ClipboardStore.write('copy', { source_root .. '/widget' }))
    Actions.paste(state)
    vim.api.nvim_feedkeys(vim.keycode('<C-k>'), 'xt', false)
    assert(changed == 2, '保留两者动作必须多报告一次文件系统变更')
    assert(vim.fn.readfile(destination_root .. '/widget (copy)/shared.txt')[1] == 'new',
      '保留两者动作必须创建递增同级项')

    vim.fn.writefile({ 'newer source' }, source_root .. '/widget/shared.txt')
    vim.fn.writefile({ 'current destination' }, destination_root .. '/widget/shared.txt')
    assert(ClipboardStore.write('copy', { source_root .. '/widget' }))
    Actions.paste(state)
    assert(ClipboardStore.write('copy', { source_root .. '/widget/source-only.txt' }))
    vim.api.nvim_feedkeys(vim.keycode('<C-o>'), 'xt', false)

    assert(changed == 2, '过期弹窗不得执行文件系统变更')
    assert(vim.fn.readfile(destination_root .. '/widget/shared.txt')[1] == 'current destination',
      '过期弹窗必须保留当前目标')

    local partial_source_a = source_root .. '/partial-a.txt'
    local partial_source_b = source_root .. '/partial-b.txt'
    vim.fn.writefile({ 'partial a' }, partial_source_a)
    vim.fn.writefile({ 'partial b' }, partial_source_b)
    assert(ClipboardStore.write('copy', { partial_source_a, partial_source_b }))
    local original_copy = Fs.copy
    local partial_source_a_normalized = vim.fs.normalize(vim.fn.fnamemodify(partial_source_a, ':p'))
    Fs.copy = function(source_path, destination_path)
      local copied = original_copy(source_path, destination_path)
      if source_path == partial_source_a_normalized then
        vim.fn.writefile({ 'changed after planning' }, partial_source_b)
      end
      return copied
    end
    Actions.paste(state)
    Fs.copy = original_copy
    assert(changed == 3, '部分粘贴成功必须报告已完成的文件系统变更')
    assert(vim.fn.readfile(destination_root .. '/partial-a.txt')[1] == 'partial a',
      '已完成的源仍必须被粘贴')
    assert(vim.fn.filereadable(destination_root .. '/partial-b.txt') == 0,
      '过期源不得被粘贴')
    assert(shared_record == nil,
      '复制首次粘贴成功后必须清空共享剪贴板，部分成功也一样')

    -- cut 部分成功仍保留失败项，不能随 copy 的一次性语义一起清空
    local cut_record = assert(ClipboardStore.write('cut', { partial_source_a, partial_source_b }))
    assert(vim.uv.fs_unlink(partial_source_b))
    -- 此错误正是缺失源路径的预期报告，精确允许，不放行其他错误。
    _G.Helpers.allowed_errmsg = { 'vv-explorer: paste errors:\nsource is no longer available: ' .. partial_source_b }
    Actions.paste(state)
    vim.api.nvim_feedkeys(vim.keycode('<C-k>'), 'xt', false)
    assert(vim.fn.filereadable(partial_source_a) == 0, '成功剪切必须移动源')
    assert(shared_record and shared_record.mode == 'cut' and shared_record.owner_id == cut_record.owner_id,
      '部分剪切必须保留原所有者')
    assert(vim.v.errmsg == _G.Helpers.allowed_errmsg[1], '缺失源路径必须精确报告预期错误')
    assert(vim.deep_equal(shared_record.paths, { partial_source_b }),
      '部分剪切必须仅保留失败源路径')

    vim.fn.delete(temporary, 'rf')
  end)
end

return T

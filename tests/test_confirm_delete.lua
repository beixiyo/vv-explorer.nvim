local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["删除确认复验目标与状态，取消不落盘并区分回收站和永久删除"] = function()
  child.lua_func(function()
    -- 删除确认的行为回归测试

    local root = vim.env.VV_TEST_REPO

    local pending
    package.preload['vv-utils.confirm'] = function()
      return {
        open = function(opts)
          pending = opts
          return { close = function() end }
        end,
      }
    end

    local calls = { refresh = 0, render = 0, after_fs_change = 0 }
    local trash_enabled = false
    local trash_calls = 0
    package.preload['vv-explorer.tree'] = function()
      return { refresh = function() calls.refresh = calls.refresh + 1 end }
    end
    package.preload['vv-explorer.render'] = function()
      return { render = function() calls.render = calls.render + 1 end }
    end
    package.preload['vv-explorer.preview'] = function()
      return { clear_if_deleted = function() end }
    end
    package.preload['vv-explorer.trash'] = function()
      return {
        enabled = function() return trash_enabled end,
        trash = function(paths)
          trash_calls = trash_calls + 1
          for _, path in ipairs(paths) do vim.fn.delete(path, 'rf') end
          return { trashed = paths, failed = {} }
        end,
      }
    end
    package.preload['vv-explorer.lsp'] = function()
      return { will_rename_clients = function() return {} end, did_rename = function() end }
    end
    package.preload['vv-utils.loading'] = function()
      return { mark = function() return { stop = function() end } end }
    end

    local Actions = {}
    local Helpers = {
      node_under_cursor = function(state) return state.cursor_node end,
      row_under_cursor = function() return {} end,
      selected_paths = function(state) return state.selected_paths or {} end,
      ensure_state_fields = function(state) state.selection = state.selection or {} end,
    }
    local context = {
      target_node = function(state) return state.cursor_node end,
      dir_context = function(state) return state.root.path end,
      after_fs_change = function() calls.after_fs_change = calls.after_fs_change + 1 end,
    }
    require('vv-explorer.actions.mutations').attach(Actions, Helpers, context)

    local function assert_equal(actual, expected, message)
      if actual ~= expected then
        error(('%s：期望 %s，实际 %s'):format(message, vim.inspect(expected), vim.inspect(actual)))
      end
    end

    local function invoke_mapping(buffer, lhs)
      for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buffer, 'n')) do
        if mapping.lhs == lhs then
          assert(type(mapping.callback) == 'function', 'buffer 映射必须暴露 Lua callback')
          mapping.callback()
          return
        end
      end
      error('未找到映射：' .. lhs)
    end

    local temporary = vim.fn.tempname()
    assert(vim.fn.mkdir(temporary, 'p') == 1, '必须创建临时目录')
    local target = temporary .. '/target.txt'
    vim.fn.writefile({ 'original' }, target)

    local source_buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, source_buffer)
    local state = {
      buf = source_buffer,
      win = vim.api.nvim_get_current_win(),
      root = { path = temporary },
      cursor_node = { path = target, name = 'target.txt' },
      selection = {},
    }

    -- 取消必须保持目标和 explorer 状态不变
    Actions.delete(state)
    assert(pending and type(pending.on_confirm) == 'function', '删除必须打开确认框')
    pending.on_cancel()
    assert(vim.fn.filereadable(target) == 1, '取消删除不得移除目标')
    assert_equal(calls.after_fs_change, 0, '取消删除不得刷新面板')

    -- 未变化的目标在确认后执行；永久删除异步完成后才刷新
    Actions.delete(state)
    pending.on_confirm()
    assert(vim.wait(5000, function() return calls.after_fs_change == 1 end, 10), '确认删除后必须刷新面板')
    assert(vim.fn.filereadable(target) == 0, '确认删除后必须移除目标')

    -- 确认等待期间被替换的同一路径必须拒绝，不能删掉 replacement
    vim.fn.writefile({ 'original again' }, target)
    Actions.delete(state)
    vim.fn.delete(target)
    vim.fn.writefile({ 'replacement' }, target)
    pending.on_confirm()
    assert(vim.deep_equal(vim.fn.readfile(target), { 'replacement' }), '过期删除必须保留替换目标')
    assert_equal(calls.after_fs_change, 1, '过期删除不得刷新 explorer')

    -- d 在回收站启用时只进入回收站，D 始终绕过回收站永久删除
    trash_enabled = true
    local trash_target = temporary .. '/trash-target.txt'
    vim.fn.writefile({ 'trash target' }, trash_target)
    state.cursor_node = { path = trash_target, name = 'trash-target.txt' }
    Actions.delete(state)
    assert(pending.title == 'Trash item?', 'd 必须明确确认回收操作')
    pending.on_confirm()
    assert_equal(trash_calls, 1, '回收站启用时 d 必须使用回收站后端')
    assert(vim.fn.filereadable(trash_target) == 0, '确认回收必须移除源路径')

    local force_target = temporary .. '/force-target.txt'
    vim.fn.writefile({ 'force target' }, force_target)
    state.cursor_node = { path = force_target, name = 'force-target.txt' }
    local refreshed_before_force = calls.after_fs_change
    Actions.force_delete(state)
    assert(pending.title == 'Delete item?', 'D 必须明确确认永久删除')
    pending.on_confirm()
    assert(vim.wait(5000, function() return calls.after_fs_change > refreshed_before_force end, 10), '强制删除完成后必须刷新')
    assert_equal(trash_calls, 1, 'D 必须绕过回收站后端')
    assert(vim.fn.filereadable(force_target) == 0, '确认强制删除必须永久移除目标')

    -- 下面的测试使用真实回收站 store，只替换确认适配，验证 entry 身份和整箱快照
    package.loaded['vv-explorer.trash.panel'] = nil
    package.loaded['vv-explorer.trash.store'] = nil
    local Panel = require('vv-explorer.trash.panel')
    local Store = require('vv-explorer.trash.store')
    local Fs = require('vv-utils.fs')

    local trash_dir = temporary .. '/trash'
    local trash_source = temporary .. '/trash-source.txt'
    vim.fn.writefile({ 'trash payload' }, trash_source)
    local store = Store.new({ enabled = true, max_items = 50, warn_size_mb = 500, scan_on_open = false }, trash_dir)
    store:trash({ trash_source })

    Panel.open(store)
    local panel_buffer = vim.api.nvim_get_current_buf()
    invoke_mapping(panel_buffer, 'd')
    assert(pending and type(pending.on_cancel) == 'function', '永久删除必须打开确认框')
    pending.on_cancel()
    assert(#store:list() == 1, '取消永久删除必须保留回收站条目')

    Panel.open(store)
    panel_buffer = vim.api.nvim_get_current_buf()
    invoke_mapping(panel_buffer, 'd')
    local original_entry = assert(store:list()[1])
    Fs.delete(original_entry.trash_path)
    vim.fn.writefile({ 'replacement payload' }, original_entry.trash_path)
    pending.on_confirm()
    assert(Fs.exists(original_entry.trash_path), '过期永久删除必须保留替换内容')
    assert(#store:list() == 1, '过期永久删除必须保留条目')

    -- 重新建立一份正常 entry，确认永久删除确实执行
    Fs.delete(original_entry.trash_path)
    pcall(Fs.delete, original_entry.meta_path)
    local second_source = temporary .. '/second.txt'
    vim.fn.writefile({ 'second payload' }, second_source)
    store:trash({ second_source })
    Panel.open(store)
    panel_buffer = vim.api.nvim_get_current_buf()
    invoke_mapping(panel_buffer, 'd')
    pending.on_confirm()
    assert(#store:list() == 0, '确认永久删除必须移除选中条目')

    -- 清空确认期间有新 entry 加入时，整箱操作必须拒绝
    local third_source = temporary .. '/third.txt'
    vim.fn.writefile({ 'third payload' }, third_source)
    store:trash({ third_source })
    Panel.open(store)
    panel_buffer = vim.api.nvim_get_current_buf()
    invoke_mapping(panel_buffer, 'D')
    local fourth_source = temporary .. '/fourth.txt'
    vim.fn.writefile({ 'fourth payload' }, fourth_source)
    store:trash({ fourth_source })
    pending.on_confirm()
    assert(#store:list() == 2, '过期清空确认必须保留所有条目')

    -- 无变化时确认清空，两个 entry 都应被删除
    Panel.open(store)
    panel_buffer = vim.api.nvim_get_current_buf()
    invoke_mapping(panel_buffer, 'D')
    pending.on_confirm()
    assert(#store:list() == 0, '确认清空必须删除快照条目')

    -- 目录大小在移入后异步补写：确认框打开时大小未知、确认前补写完成，不能被当成「条目已变」而拒绝
    local sizing_source = temporary .. '/sizing-dir'
    vim.fn.mkdir(sizing_source, 'p')
    vim.fn.writefile({ 'nested payload' }, sizing_source .. '/inner.txt')
    store:trash({ sizing_source })
    Panel.open(store)
    panel_buffer = vim.api.nvim_get_current_buf()
    invoke_mapping(panel_buffer, 'd')
    assert(vim.wait(5000, function() return (store:list()[1] or {}).size_bytes ~= nil end, 10), '目录大小必须被补写')
    pending.on_confirm()
    assert(#store:list() == 0, '确认期间大小补写不得取消永久删除')

    if vim.api.nvim_win_is_valid(vim.api.nvim_get_current_win()) then
      pcall(vim.api.nvim_win_close, vim.api.nvim_get_current_win(), true)
    end
    vim.fn.delete(temporary, 'rf')
  end)
end

return T

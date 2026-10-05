local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["面板宽度持久化、重开、外部关闭与重复 setup 释放状态"] = function()
  child.lua_func(function()
    -- vv-explorer 面板状态集成

    local values = { width = 'invalid', open = true }
    local writes = {}
    local handle = {
      get = function(_, field, default)
        local value = values[field]
        return value == nil and default or value
      end,
      set = function(_, field, value)
        values[field] = value
        writes[#writes + 1] = { field = field, value = value }
        return true
      end,
    }

    local function explorer_win()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == 'vv-explorer' then return win end
      end
      error('未找到 explorer 窗口')
    end

    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    local previous_cwd = vim.fn.getcwd()
    vim.cmd.cd(vim.fn.fnameescape(tmp))
    local target = tmp .. '/target.lua'
    local another = tmp .. '/another.lua'
    vim.fn.writefile({ 'return true' }, target)
    vim.fn.writefile({ 'return false' }, another)
    vim.cmd.edit(vim.fn.fnameescape(target))
    local target_buf = vim.api.nvim_get_current_buf()

    local explorer = require('vv-explorer')

    vim.keymap.set('n', '<F28>', '<cmd>let g:vv_explorer_previous_map = 1<cr>', {
      desc = 'fixture: previous mapping',
    })
    explorer.setup({
      persist_open = false,
      preview = false,
      watch = false,
      follow_file = false,
      git = false,
      diagnostics = false,
      trash = false,
      global_mappings = {
        toggle = '<F28>',
        reveal = '<F29>',
      },
    })
    assert(vim.fn.maparg('<F28>', 'n', false, true).desc == 'vv-explorer: toggle',
      'setup 必须安装配置的切换映射')

    explorer.setup({
      persist_open = false,
      preview = false,
      watch = false,
      follow_file = false,
      git = false,
      diagnostics = false,
      trash = false,
      global_mappings = {
        toggle = '<F30>',
        reveal = '<F31>',
      },
    })
    assert(vim.fn.maparg('<F28>', 'n', false, true).desc == 'fixture: previous mapping',
      '重配必须恢复 setup 前的映射')
    assert(vim.fn.maparg('<F29>', 'n') == '', '重配必须移除过时插件映射')

    vim.keymap.set('n', '<F30>', '<cmd>let g:vv_explorer_user_override = 1<cr>', {
      desc = 'fixture: user override',
    })
    explorer.setup({
      persist_open = false,
      preview = false,
      watch = false,
      follow_file = false,
      git = false,
      diagnostics = false,
      trash = false,
      global_mappings = false,
    })
    assert(vim.fn.maparg('<F30>', 'n', false, true).desc == 'fixture: user override',
      '重配必须保留 setup 后用户替换的映射')
    assert(vim.fn.maparg('<F31>', 'n') == '', '禁用全局映射必须移除插件持有的映射')

    explorer.setup({
      state = handle,
      width = 33,
      preview = false,
      watch = false,
      follow_file = false,
      git = false,
      diagnostics = false,
      trash = false,
      global_mappings = false,
    })
    vim.wait(100, function() return explorer.is_open() end)
    assert(not explorer.is_open(), '默认配置不得恢复已保存的打开状态，必须显式启用 persist_open')

    explorer.setup({
      state = handle,
      width = 33,
      persist_open = true,
      preview = false,
      watch = false,
      follow_file = true,
      git = false,
      diagnostics = false,
      trash = false,
      global_mappings = false,
    })

    vim.wait(100, function() return explorer.is_open() end)
    assert(explorer.is_open(), 'setup 必须按持久化打开意图恢复 explorer')
    assert(vim.api.nvim_win_get_width(explorer_win()) == 33, '非法持久化宽度必须回落到配置')
    assert(values.open == true, '打开必须持久化可见意图')
    assert(
      vim.api.nvim_get_current_buf() == target_buf,
      '恢复持久化打开状态必须保持焦点在启动文件 buffer'
    )

    local expected_path = assert(vim.uv.fs_realpath(target))
    assert(
      explorer.get_node_path() == expected_path,
      '恢复持久化打开状态必须定位启动文件且不抢焦点'
    )
    assert(
      vim.deep_equal(explorer.get_target_paths(), { expected_path }),
      '目标路径必须回落到光标节点'
    )

    vim.api.nvim_set_current_win(explorer_win())
    local toggle_select = vim.fn.maparg('<Tab>', 'n', false, true).callback
    assert(type(toggle_select) == 'function', '面板 Tab 映射必须提供选择回调')
    toggle_select()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    toggle_select()
    local expected_another = assert(vim.uv.fs_realpath(another))
    assert(
      vim.deep_equal(explorer.get_target_paths(), { expected_another, expected_path }),
      '目标路径必须按稳定顺序返回所有选中节点'
    )

    explorer.reveal()
    assert(not explorer.is_open(), 'reveal 必须关闭已打开 explorer')

    explorer.reveal()
    assert(explorer.is_open(), 'reveal 必须打开已关闭 explorer')
    assert(
      explorer.get_node_path() == expected_path,
      'reveal 打开必须聚焦当前文件'
    )

    vim.cmd('vertical resize 47')
    vim.api.nvim_exec_autocmds('WinResized', {})
    vim.wait(250, function() return values.width == 47 end)
    assert(values.width == 47, '真实 :vertical resize 必须防抖持久化')

    local resume = explorer.suspend()
    assert(type(resume) == 'function', '打开 explorer 必须提供恢复回调')
    assert(not explorer.is_open(), '暂停必须隐藏窗口')
    assert(values.open == true, '暂停必须保留可见意图')
    local resume_win = vim.api.nvim_get_current_win()
    local resume_buf = vim.api.nvim_get_current_buf()

    resume()
    assert(explorer.is_open(), '恢复必须还原窗口')
    assert(vim.api.nvim_win_get_width(explorer_win()) == 47, '恢复必须还原追踪宽度')
    assert(vim.api.nvim_get_current_win() == resume_win, '恢复必须保持当前窗口')
    assert(vim.api.nvim_get_current_buf() == resume_buf, '恢复必须保持当前 buffer')

    explorer.close()
    assert(not explorer.is_open(), '关闭必须隐藏窗口')
    assert(values.open == false, '显式关闭必须持久化关闭意图')

    local width_writes = 0
    for _, write in ipairs(writes) do
      if write.field == 'width' then width_writes = width_writes + 1 end
    end
    assert(width_writes >= 1, '宽度必须通过注册的 state 句柄写入')

    vim.cmd.cd(vim.fn.fnameescape(previous_cwd))
    vim.fn.delete(tmp, 'rf')
  end)
end

-- 在同一轮 setup 排队恢复后再重配，避免旧回调套用新配置继续打开面板
T['重配关闭持久恢复时旧启动回调不得打开面板'] = function()
  child.lua_func(function()
    local explorer = require('vv-explorer')
    local values = { open = true }
    local handle = {
      get = function(_, key, default) return values[key] == nil and default or values[key] end,
      set = function(_, key, value) values[key] = value; return true end,
    }
    local opts = {
      state = handle, cwd = vim.env.VV_TEST_TMP,
      preview = false, watch = false, follow_file = false,
      git = false, diagnostics = false, trash = false, global_mappings = false,
    }
    explorer.setup(vim.tbl_extend('force', opts, { persist_open = true }))
    explorer.setup(vim.tbl_extend('force', opts, { persist_open = false }))
    vim.wait(100, function() return false end)

    assert(not explorer.is_open(), '旧 setup 的恢复回调不得越过新配置 persist_open=false')
    assert(values.open == true, '禁用恢复只改变策略，不应擦掉旧持久化意图')
  end)
end

T['启动恢复交付前显式关闭不得随后被重新打开'] = function()
  child.lua_func(function()
    local explorer = require('vv-explorer')
    local values = { open = true }
    explorer.setup({
      state = {
        get = function(_, key, default) return values[key] == nil and default or values[key] end,
        set = function(_, key, value) values[key] = value; return true end,
      },
      cwd = vim.env.VV_TEST_TMP, persist_open = true,
      preview = false, watch = false, follow_file = false,
      git = false, diagnostics = false, trash = false, global_mappings = false,
    })
    explorer.close()
    vim.wait(100, function() return false end)

    assert(not explorer.is_open(), '显式 close 必须使尚未交付的启动恢复失效')
    assert(values.open == false, '即使尚无窗口，显式 close 也必须记录关闭意图')
  end)
end

return T

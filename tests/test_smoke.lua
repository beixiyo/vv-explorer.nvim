local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["面板帮助、路径复制、永久删除与目录统计键位正确接线"] = function()
  child.lua_func(function()
    local F = dofile(vim.env.VV_TEST_REPO .. '/tests/fixtures/smoke.lua')()
    local explorer = F.explorer
    local explorer_buf = F.explorer_buf
    local find_mapping = F.find_mapping
    local mapping_binary = F.mapping_binary
      local mapping = find_mapping('n', 'g?')
      assert(mapping and mapping.desc == 'vv-explorer: help', 'g? buffer 映射缺失或指向错误动作')
      local mapping = find_mapping('n', 'Y')
      assert(mapping and mapping.desc == 'vv-explorer: yank_abs_path', 'Y buffer 映射缺失或指向错误动作')
      local mapping = find_mapping('n', 'D')
      assert(mapping and mapping.desc == 'vv-explorer: force_delete',
        'D buffer 映射缺失或指向错误动作')
      local mapping = find_mapping('n', 'K')
      assert(mapping and mapping.desc == 'vv-explorer: scan_directory',
        '⇧K buffer 映射缺失或指向错误动作')
  end)
end

T["帮助面板显示 ⇧K，并使用 vv-icons 渲染标题和动作"] = function()
  child.lua_func(function()
    local F = dofile(vim.env.VV_TEST_REPO .. '/tests/fixtures/smoke.lua')()
    local explorer = F.explorer
    local explorer_buf = F.explorer_buf
    local find_mapping = F.find_mapping
    local mapping_binary = F.mapping_binary
      find_mapping('n', 'g?').callback()
      local help_win = vim.api.nvim_get_current_win()
      local help_buf = vim.api.nvim_get_current_buf()
      local help_text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
      local icons = require('vv-icons')
      local ui_icons = icons.ns.ui
      assert(help_text:find('⇧K', 1, true), '帮助面板未显示 Shift 图标: ' .. help_text)
      assert(help_text:find(ui_icons.explorer, 1, true), '帮助面板标题未使用 vv-icons explorer 图标')
      assert(help_text:find(ui_icons.split_horizontal, 1, true), '帮助面板动作未使用 vv-icons 分屏图标')
      assert(help_text:find(ui_icons.find_text, 1, true), '帮助面板过滤动作未使用 vv-icons 查找图标')

      local git_line
      for index, line in ipairs(vim.api.nvim_buf_get_lines(help_buf, 0, -1, false)) do
        if line:find('toggle gitignored', 1, true) then git_line = index - 1 break end
      end
      local colored = false
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        help_buf,
        vim.api.nvim_get_namespaces()['vv-utils.help_panel'],
        { git_line, 0 },
        { git_line, -1 },
        { details = true }
      )) do
        if mark[4].hl_group == icons.raw.git.git_removed.hl then colored = true break end
      end
      assert(colored, 'Git 动作图标未使用 vv-icons 的语义色')
      vim.api.nvim_feedkeys('q', 'xt', false)
      assert(not vim.api.nvim_win_is_valid(help_win), '帮助面板应能正常关闭')
  end)
end

T["移除旧键位，鼠标 callback 与多击拖拽守卫挂到面板"] = function()
  child.lua_func(function()
    local F = dofile(vim.env.VV_TEST_REPO .. '/tests/fixtures/smoke.lua')()
    local explorer = F.explorer
    local explorer_buf = F.explorer_buf
    local find_mapping = F.find_mapping
    local mapping_binary = F.mapping_binary
      assert(find_mapping('n', 'gy') == nil, 'buffer 仍包含 gy 映射')
      local mapping = find_mapping('n', '<RightMouse>')
      assert(mapping and mapping.callback, '缺少 <RightMouse> 回调映射')
      assert(find_mapping('n', '<3-LeftMouse>'), '缺少 <3-LeftMouse> buffer 守卫')
      assert(find_mapping('n', '<4-LeftMouse>'), '缺少 <4-LeftMouse> buffer 守卫')

      local guarded = false
      for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = 'ModeChanged', buffer = explorer_buf })) do
        if autocmd.desc == 'vv-utils: 面板禁止鼠标拖拽 / 多击进入 visual' then
          guarded = true
          break
        end
      end
      assert(guarded, 'explorer buffer 缺少 ModeChanged Visual 守卫')
  end)
end

T["<CR>/l 聚焦二进制属性，o 才调用系统打开"] = function()
  child.lua_func(function()
    local F = dofile(vim.env.VV_TEST_REPO .. '/tests/fixtures/smoke.lua')()
    local explorer = F.explorer
    local explorer_buf = F.explorer_buf
    local find_mapping = F.find_mapping
    local mapping_binary = F.mapping_binary
      local Sys = require('vv-utils.sys')
      local original_open_default = Sys.open_default
      local system_opened
      Sys.open_default = function(path) system_opened = path end

      local ok, err = pcall(function()
        vim.api.nvim_set_current_win(vim.fn.bufwinid(explorer_buf))
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        local enter = find_mapping('n', '<CR>')
        assert(enter and enter.callback, '缺少 <CR> 打开映射')
        enter.callback()

        local info_buf = vim.api.nvim_get_current_buf()
        assert(info_buf ~= explorer_buf, '<CR> 未聚焦内容窗口')
        assert(vim.b[info_buf].vv_explorer_binary_info == true,
          '<CR> 未聚焦二进制属性 buffer')
        assert(system_opened == nil, '<CR> 错误调用系统打开器')

        vim.api.nvim_set_current_win(vim.fn.bufwinid(explorer_buf))
        local right = find_mapping('n', 'l')
        assert(right and right.callback, '缺少 l 打开映射')
        right.callback()
        assert(vim.api.nvim_get_current_buf() == info_buf, 'l 未聚焦二进制属性 buffer')
        assert(system_opened == nil, 'l 错误调用系统打开器')

        vim.api.nvim_set_current_win(vim.fn.bufwinid(explorer_buf))
        local open = find_mapping('n', 'o')
        assert(open and open.callback, '缺少 o 系统打开映射')
        open.callback()
        assert(vim.fs.normalize(system_opened) == vim.fs.normalize(mapping_binary),
          'o 未对二进制路径调用系统打开器')
      end)

      Sys.open_default = original_open_default
      if not ok then error(err) end
  end)
end

T["诊断符号使用 vv-icons、数量与 Diagnostic* 高亮"] = function()
  child.lua_func(function()
    local F = dofile(vim.env.VV_TEST_REPO .. '/tests/fixtures/smoke.lua')()
    local explorer = F.explorer
    local explorer_buf = F.explorer_buf
    local find_mapping = F.find_mapping
    local mapping_binary = F.mapping_binary
    explorer.close()
      local Diagnostics = require('vv-explorer.diagnostics')
      local icons = require('vv-icons')
      local sym = Diagnostics.symbol_for({
        [vim.diagnostic.severity.ERROR] = 1,
        [vim.diagnostic.severity.WARN] = 2,
      })
      assert(sym and sym.glyph == icons.diagnostics_error .. ' 3', '应使用 vv-icons error 图标并显示总数量')
      assert(sym and sym.hl == 'DiagnosticError', '应使用 DiagnosticError 高亮')
  end)
end

T["预览其他分屏的固定 buffer 不重新加入当前分组"] = function()
  child.lua_func(function()
    local F = dofile(vim.env.VV_TEST_REPO .. '/tests/fixtures/smoke.lua')()
    local explorer = F.explorer
    local explorer_buf = F.explorer_buf
    local find_mapping = F.find_mapping
    local mapping_binary = F.mapping_binary
    explorer.close()
      pcall(vim.cmd, 'silent! only')

      local bufferline = require('vv-bufferline')
      local State = require('vv-bufferline.state')
      local Preview = require('vv-explorer.preview')

      State.reset()
      require('vv-bufferline.winbar_host').reset()
      bufferline.setup()

      local a_path = vim.env.VV_TEST_TMP .. '/vv-explorer-preview-a.ts'
      local b_path = vim.env.VV_TEST_TMP .. '/vv-explorer-preview-b.ts'
      vim.fn.writefile({ 'export const a = 1' }, a_path)
      vim.fn.writefile({ 'export const b = 1' }, b_path)

      vim.cmd('edit ' .. vim.fn.fnameescape(a_path))
      local top = vim.api.nvim_get_current_win()
      vim.cmd('edit ' .. vim.fn.fnameescape(b_path))
      local b = vim.api.nvim_get_current_buf()

      vim.cmd('split')
      local bottom = vim.api.nvim_get_current_win()
      assert(vim.api.nvim_win_get_buf(bottom) == b, '下方分屏未显示 b')

      vim.api.nvim_set_current_win(top)
      bufferline.close_current()
      vim.wait(100)

      assert(not State.has_in_win(top, b), 'b 未从上方分屏分组移除')
      assert(vim.api.nvim_win_get_buf(bottom) == b, '下方分屏停止显示 b')
      assert(vim.bo[b].buflisted, '下方分屏仍持有 b，因此 b 必须保持 listed')

      vim.cmd('topleft vnew')
      local explorer_win = vim.api.nvim_get_current_win()
      local explorer_buf = vim.api.nvim_get_current_buf()
      vim.bo[explorer_buf].filetype = 'vv-explorer'
      Preview.remember_editor_win(top)

      Preview.preview_file({ win = explorer_win, opts = { binary = { intercept = false } } }, b_path)
      vim.wait(100)

      assert(vim.api.nvim_win_get_buf(top) == b, '上方分屏未预览 b')
      assert(not State.has_in_win(top, b), '预览把 b 重新加入了上方分屏分组')
      -- 预览不再隐藏标签栏：top 仍显示既有固定标签（a），但预览的 b 不作为标签出现
      assert(vim.wo[top].winbar ~= '', '预览必须保持上方分屏标签栏可见')
      assert(vim.wo[top].winbar:find('vv-explorer-preview-a.ts', 1, true), '预览期间 winbar 缺少固定标签 a')
      assert(not vim.wo[top].winbar:find('vv-explorer-preview-b.ts', 1, true), '预览 buffer b 不得出现在标签中')
  end)
end

T["无扩展名二进制显示属性并释放临时 buffer"] = function()
  child.lua_func(function()
    local F = dofile(vim.env.VV_TEST_REPO .. '/tests/fixtures/smoke.lua')()
    local explorer = F.explorer
    local explorer_buf = F.explorer_buf
    local find_mapping = F.find_mapping
    local mapping_binary = F.mapping_binary
    explorer.close()
      pcall(vim.cmd, 'silent! only')

      local bufferline = require('vv-bufferline')
      local State = require('vv-bufferline.state')
      local Preview = require('vv-explorer.preview')

      State.reset()
      require('vv-bufferline.winbar_host').reset()
      bufferline.setup()

      local tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir, 'p')
      local seed_path = tmpdir .. '/seed.txt'
      local binary_path = tmpdir .. '/artifact'
      local next_path = tmpdir .. '/next.txt'
      vim.fn.writefile({ 'seed' }, seed_path)
      vim.fn.writefile({ 'next' }, next_path)
      local file = assert(io.open(binary_path, 'wb'))
      file:write(string.char(
        0xcf, 0xfa, 0xed, 0xfe,
        0x0c, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x00, 0x00
      ))
      file:close()
      vim.uv.fs_chmod(binary_path, 493)

      vim.cmd('edit ' .. vim.fn.fnameescape(seed_path))
      local main = vim.api.nvim_get_current_win()
      vim.cmd('topleft vnew')
      local explorer_win = vim.api.nvim_get_current_win()
      vim.bo.filetype = 'vv-explorer'
      Preview.remember_editor_win(main)

      local state = {
        win = explorer_win,
        opts = { binary = { intercept = true, extensions = {} } },
      }
      Preview.preview_file(state, binary_path)

      local info_buf = vim.api.nvim_win_get_buf(main)
      local text = table.concat(vim.api.nvim_buf_get_lines(info_buf, 0, -1, false), '\n')
      assert(vim.bo[info_buf].buftype == 'nofile', '二进制预览必须使用 nofile 临时 buffer')
      assert(vim.bo[info_buf].readonly and not vim.bo[info_buf].modifiable,
        '二进制预览必须显式只读')
      assert(vim.b[info_buf].vv_explorer_binary_info == true, '二进制预览缺少归属标记')
      assert(text:find('Binary file', 1, true), '二进制预览缺少英文标题')
      assert(text:find('Type: Mach-O 64-bit executable', 1, true), '二进制预览缺少文件类型')
      assert(text:find('Architecture: arm64', 1, true), '二进制预览缺少架构')
      assert(text:find('Executable: Yes', 1, true), '二进制预览缺少可执行标记')
      local highlighted = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(info_buf, -1, 0, -1, { details = true })) do
        highlighted[mark[4].hl_group] = true
      end
      assert(highlighted.VVUtilsFileInfoTitle and highlighted.VVUtilsFileInfoLabel,
        '二进制预览缺少共享高亮')

      Preview.preview_file(state, next_path)
      local displayed_path = vim.fs.normalize(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(main)))
      assert(vim.uv.fs_realpath(displayed_path) == vim.uv.fs_realpath(next_path),
        '文本预览未替换二进制属性：' .. displayed_path)
      assert(not vim.api.nvim_buf_is_valid(info_buf), '被替换的二进制临时 buffer 泄漏')

      vim.cmd('enew')
      Preview.discard(state)
      vim.fn.delete(tmpdir, 'rf')
  end)
end

T["提交新文件不复活已移出分组的陈旧预览"] = function()
  child.lua_func(function()
    local F = dofile(vim.env.VV_TEST_REPO .. '/tests/fixtures/smoke.lua')()
    local explorer = F.explorer
    local explorer_buf = F.explorer_buf
    local find_mapping = F.find_mapping
    local mapping_binary = F.mapping_binary
    explorer.close()
      pcall(vim.cmd, 'silent! only')

      local bufferline = require('vv-bufferline')
      local State = require('vv-bufferline.state')
      local Preview = require('vv-explorer.preview')

      State.reset()
      require('vv-bufferline.winbar_host').reset()
      bufferline.setup()

      local b_path = vim.env.VV_TEST_TMP .. '/vv-explorer-stale-b.ts'
      local c_path = vim.env.VV_TEST_TMP .. '/vv-explorer-stale-c.ts'
      vim.fn.writefile({ 'export const b = 1' }, b_path)
      vim.fn.writefile({ 'export const c = 1' }, c_path)

      -- main 当前显式打开的是 c（提交目标），分组应只含 c
      vim.cmd('edit ' .. vim.fn.fnameescape(c_path))
      local main = vim.api.nvim_get_current_win()
      local c = vim.api.nvim_get_current_buf()

      -- b：用户曾打开、随后用 <leader>bd 从 main 分组删除的 buffer
      local b = vim.fn.bufadd(b_path)
      vim.fn.bufload(b)
      vim.bo[b].buflisted = true
      State.add(main, b)
      State.detach(main, b)
      assert(State.is_removed(main, b), '前置：b 已从主窗口移除')
      assert(not State.has_in_win(main, b), '前置：b 不在主窗口分组')

      -- 让 b 在另一个分屏存活（commit 的清理不应 wipe 它，便于断言 removed 仍在）
      vim.cmd('split')
      vim.cmd('buffer ' .. b)
      vim.api.nvim_set_current_win(main)

      -- 模拟 open_file 的 :edit 之后状态：main 已显示 c，但仍残留一条指向 b 的陈旧预览
      local state = { win = main }
      Preview._preview[state] = b
      Preview._preview_win[state] = main

      Preview.commit(state, main)
      vim.wait(50)

      assert(not State.has_in_win(main, b), 'commit 通过陈旧预览复活了已移除 buffer')
      assert(State.is_removed(main, b), 'commit 错误清空 b 的 removed 标记')
      assert(State.has_in_win(main, c), '提交未固定真正打开的 buffer c')
  end)
end

T["空白编辑窗可复用为主目标窗口"] = function()
  child.lua_func(function()
    local F = dofile(vim.env.VV_TEST_REPO .. '/tests/fixtures/smoke.lua')()
    local explorer = F.explorer
    local explorer_buf = F.explorer_buf
    local find_mapping = F.find_mapping
    local mapping_binary = F.mapping_binary
    explorer.close()
      pcall(vim.cmd, 'silent! only')

      local Preview = require('vv-explorer.preview')

      vim.cmd('enew')
      local main = vim.api.nvim_get_current_win()
      local main_buf = vim.api.nvim_get_current_buf()
      vim.bo[main_buf].buflisted = false

      vim.cmd('topleft vnew')
      local explorer_win = vim.api.nvim_get_current_win()
      vim.bo.filetype = 'vv-explorer'

      assert(Preview.find_main_win(explorer_win) == main, '空白普通编辑窗必须复用为主目标')
  end)
end

T["匹配高亮默认链接主题标准组"] = function()
  child.lua_func(function()
    local F = dofile(vim.env.VV_TEST_REPO .. '/tests/fixtures/smoke.lua')()
    local explorer = F.explorer
    local explorer_buf = F.explorer_buf
    local find_mapping = F.find_mapping
    local mapping_binary = F.mapping_binary
    explorer.close()
      local expected = {
        VVExplorerMatch = 'Search',
        VVExplorerChainSelected = 'CurSearch',
        VVExplorerDropTarget = 'PmenuSel',
      }
      for name, target in pairs(expected) do
        local hl = vim.api.nvim_get_hl(0, { name = name })
        assert(hl.link == target, name .. ' 应链接到 ' .. target .. '，实际：' .. vim.inspect(hl))
      end
  end)
end

return T

-- vv-explorer.nvim 变更验证脚本
-- 用法:
--   cd vv-explorer.nvim && nvim --headless -u NONE -l tests/test_smoke.lua
--   或在 nvim 内:  :luafile vv-explorer.nvim/tests/test_smoke.lua

local passed = 0
local failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print('  PASS: ' .. name)
  else
    failed = failed + 1
    print('  FAIL: ' .. name .. ' -> ' .. tostring(err))
  end
end

local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local plugin_root = vim.fn.fnamemodify(this, ':h:h')
local vendors_root = vim.fn.fnamemodify(plugin_root, ':h')

package.path = table.concat({
  plugin_root .. '/lua/?.lua',
  plugin_root .. '/lua/?/init.lua',
  vendors_root .. '/vv-bufferline.nvim/lua/?.lua',
  vendors_root .. '/vv-bufferline.nvim/lua/?/init.lua',
  vendors_root .. '/vv-utils.nvim/lua/?.lua',
  vendors_root .. '/vv-utils.nvim/lua/?/init.lua',
  vendors_root .. '/vv-icons.nvim/lua/?.lua',
  vendors_root .. '/vv-icons.nvim/lua/?/init.lua',
  package.path,
}, ';')

local readme = table.concat(vim.fn.readfile(plugin_root .. '/README.md'), '\n')
local init_lua = table.concat(vim.fn.readfile(plugin_root .. '/lua/vv-explorer/init.lua'), '\n')

print('\n=== vv-explorer.nvim 变更验证 ===\n')
print('[1] README 键位文档修正')

test('README 不再使用单独的 ? 作为 help 键（应为 g?）', function()
  -- 表格内第一列为裸 `?`（非 `g?`）时匹配；此正则兼容 g? 开头行
  assert(readme:find('`g%?`'), 'README 未包含 `g?` 键')
end)

test('README Y 描述为"绝对路径"', function()
  -- 查找包含 `Y` 的行及其描述
  local found_abs = false
  for line in readme:gmatch('[^\n]+') do
    if line:match('`Y`') and line:match('绝对路径') then
      found_abs = true
      break
    end
  end
  assert(found_abs, 'README 中 Y 键描述未修正为绝对路径')
end)

test('README 不再列 gy 键', function()
  -- gy 应完全从表格中移除
  assert(not readme:match('\n|%s*`gy`'), 'README 仍列出 gy 键')
end)

test('README 列出右键复制路径', function()
  -- README 键位表用中文「右键」标注鼠标动作（与「拖拽」同风格），非字面 <RightMouse>
  assert(readme:find('右键'), 'README 未记录右键动作')
  assert(readme:find('yank_abs_path'), 'README 未记录右键对应的 yank_abs_path 动作')
end)

test('README 列出 <C-e> / <C-y>', function()
  assert(readme:find('<C%-e>') or readme:find('C%-e'), 'README 未记录 <C-e>')
  assert(readme:find('<C%-y>') or readme:find('C%-y'), 'README 未记录 <C-y>')
end)

print('\n[2] 代码实际绑定校验（确保文档与代码一致）')

test('init.lua 中 g? 映射到 help', function()
  assert(init_lua:match("%['g%?'%]%s*=%s*'help'"), "init.lua 中 g? 未映射到 help")
end)

test('init.lua 中 Y 映射到 yank_abs_path', function()
  assert(init_lua:match("%['Y'%]%s*=%s*'yank_abs_path'"), 'init.lua 中 Y 未映射到 yank_abs_path')
end)

test('init.lua 中无 gy 映射', function()
  assert(not init_lua:match("%['gy'%]"), 'init.lua 中仍存在 gy 映射')
end)

test('init.lua 中 <RightMouse> 已绑定', function()
  assert(init_lua:match('RightMouse'), 'init.lua 中未绑定 <RightMouse>')
end)

test('init.lua 屏蔽多击 + 跨窗口拖入守卫', function()
  assert(init_lua:match('<3%-LeftMouse>') and init_lua:match('<4%-LeftMouse>'),
    'init.lua 未屏蔽 <3-/4-LeftMouse>（三/四击选行/块）')
  assert(init_lua:match('block_visual_drag'),
    'init.lua 未调用 vv-utils.mouse.block_visual_drag 兜底跨窗口')
end)

print('\n[3] README API 注释修正')

test('README 安装示例注释为 :VVExplorer* 而非 :Explorer*', function()
  -- 不应出现裸的 `:Explorer*` 注释（但可以出现 `:VVExplorer*`）
  local bad_line = false
  for line in readme:gmatch('[^\n]+') do
    if line:match(':Explorer%*') and not line:match(':VVExplorer%*') then
      bad_line = true
      break
    end
  end
  assert(not bad_line, 'README 仍含裸 :Explorer* 注释')
end)

print('\n[4] README 高亮组表格格式')

test('VVGit* 引用块不在表格中间', function()
  -- 找到 VVExplorerDiag 或 VVDiag 所在段落，检查它们和 VVGitConflict 之间没有引用块 >
  local vvgit_pos = readme:find('VVGitConflict')
  local vvdiag_pos = readme:find('VVDiag[EW]') or readme:find('VVExplorerDiag')
  if vvgit_pos and vvdiag_pos and vvdiag_pos > vvgit_pos then
    local between = readme:sub(vvgit_pos, vvdiag_pos)
    assert(not between:match('\n>'), 'VVGitConflict 和 VVDiag* 之间仍有引用块 >')
  end
end)

test('诊断符号使用 vv-icons、数量与 Diagnostic* 高亮', function()
  local Diagnostics = require('vv-explorer.diagnostics')
  local icons = require('vv-icons')
  local sym = Diagnostics.symbol_for({
    [vim.diagnostic.severity.ERROR] = 1,
    [vim.diagnostic.severity.WARN] = 2,
  })
  assert(sym and sym.glyph == icons.diagnostics_error .. ' 3', '应使用 vv-icons error 图标并显示总数量')
  assert(sym and sym.hl == 'DiagnosticError', '应使用 DiagnosticError 高亮')
end)

print('\n[5] vv-bufferline 分组预览回归')

test('preview listed buffer from another split does not re-add it to current split group', function()
  pcall(vim.cmd, 'silent! only')

  local bufferline = require('vv-bufferline')
  local State = require('vv-bufferline.state')
  local Preview = require('vv-explorer.preview')

  State.reset()
  bufferline.setup()

  local a_path = '/tmp/vv-explorer-preview-a.ts'
  local b_path = '/tmp/vv-explorer-preview-b.ts'
  vim.fn.writefile({ 'export const a = 1' }, a_path)
  vim.fn.writefile({ 'export const b = 1' }, b_path)

  vim.cmd('edit ' .. vim.fn.fnameescape(a_path))
  local top = vim.api.nvim_get_current_win()
  vim.cmd('edit ' .. vim.fn.fnameescape(b_path))
  local b = vim.api.nvim_get_current_buf()

  vim.cmd('split')
  local bottom = vim.api.nvim_get_current_win()
  assert(vim.api.nvim_win_get_buf(bottom) == b, 'bottom split does not show b')

  vim.api.nvim_set_current_win(top)
  bufferline.close_current()
  vim.wait(100)

  assert(not State.has_in_win(top, b), 'b was not removed from top split group')
  assert(vim.api.nvim_win_get_buf(bottom) == b, 'bottom split stopped showing b')
  assert(vim.bo[b].buflisted, 'b should remain listed because bottom split owns it')

  Preview.remember_editor_win(top)
  vim.cmd('topleft vnew')
  local explorer_win = vim.api.nvim_get_current_win()
  local explorer_buf = vim.api.nvim_get_current_buf()
  vim.bo[explorer_buf].filetype = 'vv-explorer'

  Preview.preview_file({ win = explorer_win, opts = { binary = { intercept = false } } }, b_path)
  vim.wait(100)

  assert(vim.api.nvim_win_get_buf(top) == b, 'top split did not preview b')
  assert(not State.has_in_win(top, b), 'preview re-added b to top split group')
  -- 预览不再隐藏标签栏：top 仍显示既有固定标签（a），但预览的 b 不作为标签出现
  assert(vim.wo[top].winbar ~= '', 'preview should keep the top split bufferline visible')
  assert(vim.wo[top].winbar:find('vv-explorer-preview-a.ts', 1, true), 'fixed tab a missing from winbar during preview')
  assert(not vim.wo[top].winbar:find('vv-explorer-preview-b.ts', 1, true), 'preview buffer b must not appear as a tab')
end)

test('opening another file does not resurrect a buffer removed from the split (stale preview)', function()
  pcall(vim.cmd, 'silent! only')

  local bufferline = require('vv-bufferline')
  local State = require('vv-bufferline.state')
  local Preview = require('vv-explorer.preview')

  State.reset()
  bufferline.setup()

  local b_path = '/tmp/vv-explorer-stale-b.ts'
  local c_path = '/tmp/vv-explorer-stale-c.ts'
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
  assert(State.is_removed(main, b), 'precondition: b removed from main')
  assert(not State.has_in_win(main, b), 'precondition: b not in main group')

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

  assert(not State.has_in_win(main, b), 'commit resurrected a removed buffer via a stale preview')
  assert(State.is_removed(main, b), 'commit wrongly cleared the removed flag for b')
  assert(State.has_in_win(main, c), 'commit did not promote the actually-opened buffer c')
end)

test('empty unnamed editor window is reusable as main target', function()
  pcall(vim.cmd, 'silent! only')

  local Preview = require('vv-explorer.preview')

  vim.cmd('enew')
  local main = vim.api.nvim_get_current_win()
  local main_buf = vim.api.nvim_get_current_buf()
  vim.bo[main_buf].buflisted = false

  vim.cmd('topleft vnew')
  local explorer_win = vim.api.nvim_get_current_win()
  vim.bo.filetype = 'vv-explorer'

  assert(Preview.find_main_win(explorer_win) == main, 'empty normal editor window should be reused as main target')
end)

print('\n──────────────────────────────────────────────────')
print(string.format('共 %d 项: %d 通过, %d 失败', passed + failed, passed, failed))
if failed > 0 then
  print('有测试未通过！')
  os.exit(1)
else
  print('全部通过')
end

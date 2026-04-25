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

test('README 列出 <RightMouse>', function()
  assert(readme:find('RightMouse'), 'README 未记录 <RightMouse>')
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

print('\n──────────────────────────────────────────────────')
print(string.format('共 %d 项: %d 通过, %d 失败', passed + failed, passed, failed))
if failed > 0 then
  print('有测试未通过！')
  os.exit(1)
else
  print('全部通过')
end

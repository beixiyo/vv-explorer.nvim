-- vv-explorer.nvim 变更验证脚本
-- 用法:
--   进入 vv-explorer.nvim 后运行：nvim --headless -u NONE -l tests/test_smoke.lua
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

print('\n=== vv-explorer.nvim 变更验证 ===\n')
print('[1] 真实 buffer-local 映射校验')

local mapping_state = {}
local mapping_handle = {
  get = function(_, key, default)
    local value = mapping_state[key]
    return value == nil and default or value
  end,
  set = function(_, key, value)
    mapping_state[key] = value
    return true
  end,
}
local mapping_root = vim.fn.tempname()
vim.fn.mkdir(mapping_root, 'p')
local mapping_binary = mapping_root .. '/artifact'
local mapping_file = assert(io.open(mapping_binary, 'wb'))
mapping_file:write(string.char(
  0xcf, 0xfa, 0xed, 0xfe,
  0x0c, 0x00, 0x00, 0x01,
  0x00, 0x00, 0x00, 0x00,
  0x02, 0x00, 0x00, 0x00
))
mapping_file:close()

local explorer = require('vv-explorer')
explorer.setup({
  state = mapping_handle,
  persist_open = false,
  cwd = mapping_root,
  preview = false,
  watch = false,
  follow_file = false,
  git = false,
  diagnostics = false,
  trash = false,
  global_mappings = false,
})
explorer.open()

local explorer_buf = vim.api.nvim_get_current_buf()
assert(vim.bo[explorer_buf].filetype == 'vv-explorer', 'mapping fixture did not open explorer buffer')

local function find_mapping(mode, lhs)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(explorer_buf, mode)) do
    if mapping.lhs == lhs then return mapping end
  end
end

test('g? buffer 映射到 help action', function()
  local mapping = find_mapping('n', 'g?')
  assert(mapping and mapping.desc == 'vv-explorer: help', 'g? buffer mapping missing or points to wrong action')
end)

test('Y buffer 映射到 yank_abs_path action', function()
  local mapping = find_mapping('n', 'Y')
  assert(mapping and mapping.desc == 'vv-explorer: yank_abs_path', 'Y buffer mapping missing or points to wrong action')
end)

test('⇧K buffer 映射到按需目录统计 action', function()
  local mapping = find_mapping('n', 'K')
  assert(mapping and mapping.desc == 'vv-explorer: scan_directory',
    '⇧K buffer mapping missing or points to wrong action')
end)

test('帮助面板显示 ⇧K，并使用 vv-icons 渲染标题和动作', function()
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

test('buffer 中无 gy 映射', function()
  assert(find_mapping('n', 'gy') == nil, 'buffer still contains gy mapping')
end)

test('<RightMouse> 使用 buffer-local callback', function()
  local mapping = find_mapping('n', '<RightMouse>')
  assert(mapping and mapping.callback, '<RightMouse> callback mapping missing')
end)

test('多击映射和 ModeChanged 拖拽守卫实际挂到 panel buffer', function()
  assert(find_mapping('n', '<3-LeftMouse>'), '<3-LeftMouse> buffer guard missing')
  assert(find_mapping('n', '<4-LeftMouse>'), '<4-LeftMouse> buffer guard missing')

  local guarded = false
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = 'ModeChanged', buffer = explorer_buf })) do
    if autocmd.desc == 'vv-utils: 面板禁止鼠标拖拽 / 多击进入 visual' then
      guarded = true
      break
    end
  end
  assert(guarded, 'ModeChanged visual guard missing from explorer buffer')
end)

test('<CR>/l 聚焦二进制属性，o 才调用系统打开', function()
  local Sys = require('vv-utils.sys')
  local original_open_default = Sys.open_default
  local system_opened
  Sys.open_default = function(path) system_opened = path end

  local ok, err = pcall(function()
    vim.api.nvim_set_current_win(vim.fn.bufwinid(explorer_buf))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    local enter = find_mapping('n', '<CR>')
    assert(enter and enter.callback, '<CR> open mapping missing')
    enter.callback()

    local info_buf = vim.api.nvim_get_current_buf()
    assert(info_buf ~= explorer_buf, '<CR> did not focus the content window')
    assert(vim.b[info_buf].vv_explorer_binary_info == true,
      '<CR> did not focus the binary metadata buffer')
    assert(system_opened == nil, '<CR> incorrectly invoked the system opener')

    vim.api.nvim_set_current_win(vim.fn.bufwinid(explorer_buf))
    local right = find_mapping('n', 'l')
    assert(right and right.callback, 'l open mapping missing')
    right.callback()
    assert(vim.api.nvim_get_current_buf() == info_buf, 'l did not focus the binary metadata buffer')
    assert(system_opened == nil, 'l incorrectly invoked the system opener')

    vim.api.nvim_set_current_win(vim.fn.bufwinid(explorer_buf))
    local open = find_mapping('n', 'o')
    assert(open and open.callback, 'o system_open mapping missing')
    open.callback()
    assert(vim.fs.normalize(system_opened) == vim.fs.normalize(mapping_binary),
      'o did not invoke the system opener for the binary path')
  end)

  Sys.open_default = original_open_default
  if not ok then error(err) end
end)

explorer.close()
vim.fn.delete(mapping_root, 'rf')

print('\n[2] 诊断符号')

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

print('\n[3] vv-bufferline 分组预览回归')

test('preview listed buffer from another split does not re-add it to current split group', function()
  pcall(vim.cmd, 'silent! only')

  local bufferline = require('vv-bufferline')
  local State = require('vv-bufferline.state')
  local Preview = require('vv-explorer.preview')

  State.reset()
  require('vv-bufferline.winbar_host').reset()
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

  vim.cmd('topleft vnew')
  local explorer_win = vim.api.nvim_get_current_win()
  local explorer_buf = vim.api.nvim_get_current_buf()
  vim.bo[explorer_buf].filetype = 'vv-explorer'
  Preview.remember_editor_win(top)

  Preview.preview_file({ win = explorer_win, opts = { binary = { intercept = false } } }, b_path)
  vim.wait(100)

  assert(vim.api.nvim_win_get_buf(top) == b, 'top split did not preview b')
  assert(not State.has_in_win(top, b), 'preview re-added b to top split group')
  -- 预览不再隐藏标签栏：top 仍显示既有固定标签（a），但预览的 b 不作为标签出现
  assert(vim.wo[top].winbar ~= '', 'preview should keep the top split bufferline visible')
  assert(vim.wo[top].winbar:find('vv-explorer-preview-a.ts', 1, true), 'fixed tab a missing from winbar during preview')
  assert(not vim.wo[top].winbar:find('vv-explorer-preview-b.ts', 1, true), 'preview buffer b must not appear as a tab')
end)

test('extensionless binary uses an English metadata preview and releases its scratch buffer', function()
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
  assert(vim.bo[info_buf].buftype == 'nofile', 'binary preview must use a nofile scratch buffer')
  assert(vim.bo[info_buf].readonly and not vim.bo[info_buf].modifiable,
    'binary preview must be explicitly read-only')
  assert(vim.b[info_buf].vv_explorer_binary_info == true, 'binary preview ownership marker missing')
  assert(text:find('Binary file', 1, true), 'binary preview English title missing')
  assert(text:find('Type: Mach-O 64-bit executable', 1, true), 'binary preview type missing')
  assert(text:find('Architecture: arm64', 1, true), 'binary preview architecture missing')
  assert(text:find('Executable: Yes', 1, true), 'binary preview executable flag missing')
  local highlighted = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(info_buf, -1, 0, -1, { details = true })) do
    highlighted[mark[4].hl_group] = true
  end
  assert(highlighted.VVUtilsFileInfoTitle and highlighted.VVUtilsFileInfoLabel,
    'binary preview shared highlights missing')

  Preview.preview_file(state, next_path)
  local displayed_path = vim.fs.normalize(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(main)))
  assert(vim.uv.fs_realpath(displayed_path) == vim.uv.fs_realpath(next_path),
    'text preview did not replace binary metadata: ' .. displayed_path)
  assert(not vim.api.nvim_buf_is_valid(info_buf), 'replaced binary scratch buffer leaked')

  vim.cmd('enew')
  Preview.discard(state)
  vim.fn.delete(tmpdir, 'rf')
end)

test('opening another file does not resurrect a buffer removed from the split (stale preview)', function()
  pcall(vim.cmd, 'silent! only')

  local bufferline = require('vv-bufferline')
  local State = require('vv-bufferline.state')
  local Preview = require('vv-explorer.preview')

  State.reset()
  require('vv-bufferline.winbar_host').reset()
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

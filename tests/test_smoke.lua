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

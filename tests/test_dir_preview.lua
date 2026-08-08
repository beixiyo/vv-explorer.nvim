-- vv-explorer 目录属性预览：挂载、异步补算、取消与缓存
--
-- 覆盖目录预览区别于文件预览的四件事：
--   ① 目录节点也能进主窗，且用 nofile scratch 而不是把目录当文件打开
--   ② 递归统计是异步补算的，先出浅层数字，跑完再换成最终值
--   ③ 光标移开后在途统计必须停下，且过期结果不许写回已经换掉的主窗
--   ④ 跑完的结果进缓存，回到同一目录时不再重扫

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
  vendors_root .. '/vv-utils.nvim/lua/?.lua',
  vendors_root .. '/vv-utils.nvim/lua/?/init.lua',
  package.path,
}, ';')

local Config = require('vv-explorer.config')
local Preview = require('vv-explorer.preview')

print('\n=== vv-explorer 目录预览 ===\n')

---@return string root, string nested
local function make_fixture()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. '/nested', 'p')
  vim.fn.writefile({ string.rep('a', 9) }, root .. '/a.txt')
  vim.fn.writefile({ string.rep('b', 19) }, root .. '/nested/b.txt')
  return root, root .. '/nested'
end

-- 打开一个真实的「树窗 + 主窗」布局，返回主窗与可直接喂给 preview 的 state
---@param opts table?
---@return integer main, table state
local function open_layout(opts)
  pcall(vim.cmd, 'silent! only')
  vim.cmd('enew')
  local seed = vim.fn.tempname()
  vim.fn.writefile({ 'seed' }, seed)
  vim.cmd('edit ' .. vim.fn.fnameescape(seed))
  local main = vim.api.nvim_get_current_win()

  vim.cmd('topleft vnew')
  local tree_win = vim.api.nvim_get_current_win()
  vim.bo.filetype = 'vv-explorer'
  Preview.remember_editor_win(main)

  return main, { win = tree_win, buf = vim.api.nvim_get_current_buf(), opts = Config.resolve(opts) }
end

---@param buf integer
---@return string
local function text_of(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
end

test('目录预览挂载 nofile scratch 并显示直接子项统计', function()
  local root = make_fixture()
  local main, state = open_layout()

  Preview.preview_dir(state, root)

  local buf = vim.api.nvim_win_get_buf(main)
  assert(vim.bo[buf].buftype == 'nofile', '目录预览必须用 nofile scratch，不能真的打开目录')
  assert(vim.bo[buf].readonly and not vim.bo[buf].modifiable, '目录预览必须只读')
  assert(vim.b[buf].vv_explorer_dir_info == true, '缺少目录预览归属标记')
  assert(vim.b[buf].vv_explorer_dir_path == vim.fs.normalize(root), '缺少目录路径标记')

  local text = text_of(buf)
  assert(text:find('Directory', 1, true), '缺少目录预览标题')
  assert(text:find('Items: 2 (1 dirs, 1 files)', 1, true), '直接子项统计不正确: ' .. text)

  Preview.discard(state)
  vim.fn.delete(root, 'rf')
end)

test('递归统计异步补算，跑完后换成最终值', function()
  local root = make_fixture()
  local main, state = open_layout()

  Preview.preview_dir(state, root)
  local buf = vim.api.nvim_win_get_buf(main)

  -- 首帧只有浅层数字，递归结果还没到
  assert(not text_of(buf):find('Total files: 2', 1, true), '递归结果不应在首帧就是最终值')

  vim.wait(3000, function() return text_of(buf):find('Total files: 2', 1, true) ~= nil end, 10)

  local text = text_of(buf)
  assert(text:find('Total files: 2', 1, true), '递归统计没有补算出文件数: ' .. text)
  assert(text:find('Total dirs: 1', 1, true), '递归统计没有补算出目录数: ' .. text)
  -- writefile 会补一个换行，两个文件是 10 + 20 字节
  assert(text:find('Total size: 30 B (30 bytes)', 1, true), '递归统计的字节数不正确: ' .. text)
  assert(not text:find('scanning', 1, true), '跑完之后不应再标记为扫描中')

  Preview.discard(state)
  vim.fn.delete(root, 'rf')
end)

test('同一目录重复触发不重建 buffer，避免打断在途统计', function()
  local root = make_fixture()
  local main, state = open_layout()

  Preview.preview_dir(state, root)
  local first = vim.api.nvim_win_get_buf(main)
  Preview.preview_dir(state, root)
  Preview.preview_dir(state, root)

  assert(vim.api.nvim_win_get_buf(main) == first, '重复预览同一目录不应重建 scratch buffer')

  Preview.discard(state)
  vim.fn.delete(root, 'rf')
end)

test('切到文件后过期统计不写回主窗', function()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  for index = 1, 1500 do
    vim.fn.writefile({ 'x' }, ('%s/f%04d.txt'):format(root, index))
  end
  local sibling = vim.fn.tempname()
  vim.fn.writefile({ 'sibling' }, sibling)

  -- 预算压到最小，保证切走时统计一定还在途
  local main, state = open_layout({ directory_preview = { budget_ms = 1 } })

  Preview.preview_dir(state, root)
  local dir_buf = vim.api.nvim_win_get_buf(main)
  assert(vim.b[dir_buf].vv_explorer_dir_info == true, '目录预览没有挂上')
  assert(not text_of(dir_buf):find('Total files: 1,500', 1, true), '统计不应在切走前就已完成')

  Preview.preview_file(state, sibling)
  assert(not vim.api.nvim_buf_is_valid(dir_buf), '被替换的目录 scratch 应当被回收')

  vim.wait(400, function() return false end, 10)

  local shown = vim.api.nvim_win_get_buf(main)
  assert(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(shown)) == vim.uv.fs_realpath(sibling),
    '过期的目录统计把主窗抢了回去')

  Preview.discard(state)
  vim.fn.delete(root, 'rf')
  vim.fn.delete(sibling)
end)

test('跑完的统计进缓存，回到同一目录直接是完成态', function()
  local root, nested = make_fixture()
  local main, state = open_layout()

  Preview.preview_dir(state, root)
  local buf = vim.api.nvim_win_get_buf(main)
  vim.wait(3000, function() return text_of(buf):find('Total files: 2', 1, true) ~= nil end, 10)
  assert(text_of(buf):find('Total files: 2', 1, true), '首轮统计没有完成，缓存无从谈起')

  Preview.preview_dir(state, nested)
  Preview.preview_dir(state, root)

  -- 命中缓存时首帧就是最终值，不经过 scanning 阶段
  local cached_buf = vim.api.nvim_win_get_buf(main)
  local text = text_of(cached_buf)
  assert(text:find('Total files: 2', 1, true), '回到同一目录应直接复用缓存结果: ' .. text)
  assert(not text:find('scanning', 1, true), '命中缓存不应再显示扫描中')

  Preview.invalidate_dir_cache(state)
  Preview.discard(state)
  vim.fn.delete(root, 'rf')
end)

test('directory_preview = false 时目录节点不改变主窗', function()
  local root = make_fixture()
  local main, state = open_layout({ directory_preview = false })
  local before = vim.api.nvim_win_get_buf(main)

  Preview.preview_dir(state, root)

  assert(vim.api.nvim_win_get_buf(main) == before, '关闭目录预览后不应替换主窗 buffer')

  Preview.discard(state)
  vim.fn.delete(root, 'rf')
end)

print('\n' .. string.rep('─', 50))
print(('共 %d 项: %d 通过, %d 失败'):format(passed + failed, passed, failed))
if failed > 0 then
  print('存在失败项')
  vim.cmd('cquit 1')
end
print('全部通过')

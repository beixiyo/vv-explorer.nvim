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
local Dir = require('vv-explorer.preview.dir')
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
  local main, state = open_layout({ directory_preview = { scan_on_demand = false } })

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
  local main, state = open_layout({ directory_preview = { scan_on_demand = false, budget_ms = 1 } })

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
  local main, state = open_layout({ directory_preview = { scan_on_demand = false } })

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

test('默认自动计算阈值内的小目录', function()
  local root = make_fixture()
  local main, state = open_layout()

  Preview.preview_dir(state, root)
  local buf = vim.api.nvim_win_get_buf(main)
  assert(vim.wait(3000, function()
    return text_of(buf):find('Total files: 2', 1, true) ~= nil
  end, 10), '阈值内的小目录应自动完成递归统计')
  assert(not text_of(buf):find('Hint:', 1, true), '自动统计完成后应移除快捷键提示')

  Preview.discard(state)
  vim.fn.delete(root, 'rf')
end)

test('自动探测达到阈值便停止，大目录仍可按 ⇧K 完整计算', function()
  local root = make_fixture()
  local main, state = open_layout({ directory_preview = { auto_scan_max_entries = 1 } })

  Preview.preview_dir(state, root)
  local buf = vim.api.nvim_win_get_buf(main)
  vim.wait(100, function() return false end, 10)
  assert(not text_of(buf):find('Total files:', 1, true), '达到自动探测阈值后不应显示部分结果')
  assert(text_of(buf):find('Hint: Press ⇧K to calculate directory totals', 1, true),
    '大目录应保留英文快捷键提示')

  Preview.scan_dir(state, root)
  assert(vim.wait(3000, function()
    return text_of(buf):find('Total files: 2', 1, true) ~= nil
  end, 10), '手动触发后应完成递归统计')
  assert(not text_of(buf):find('Hint:', 1, true), '开始统计后应移除按需提示')

  Preview.scan_dir(state, root)
  assert(not text_of(buf):find('scanning', 1, true), '已有缓存时重复触发不应重新扫描')

  Preview.discard(state)
  vim.fn.delete(root, 'rf')
end)

test('auto_scan_max_entries = 0 时不自动探测', function()
  local root = make_fixture()
  local main, state = open_layout({ directory_preview = { auto_scan_max_entries = 0 } })

  Preview.preview_dir(state, root)
  local buf = vim.api.nvim_win_get_buf(main)
  vim.wait(100, function() return false end, 10)
  assert(not text_of(buf):find('Total files:', 1, true), '配置为 0 时不应自动递归统计')
  assert(text_of(buf):find('Hint: Press ⇧K to calculate directory totals', 1, true),
    '禁用自动探测后应保留快捷键提示')

  Preview.discard(state)
  vim.fn.delete(root, 'rf')
end)

-- 面板关闭时属性页必须随之撤下（discard_info_preview）：属性页是一次性 scratch，
-- 留在真实编辑窗里既顶掉用户内容，也让在途递归统计失去归属

test('关闭面板时目录属性页换回预览开始前的文件', function()
  local root = make_fixture()
  local main, state = open_layout()
  local seed = vim.api.nvim_win_get_buf(main)

  Preview.preview_dir(state, root)
  assert(vim.api.nvim_win_get_buf(main) ~= seed, '目录预览没有挂上')

  Preview.discard_info_preview(state)
  assert(vim.api.nvim_win_get_buf(main) == seed, '关闭面板后主窗没有回到预览开始前的文件')

  vim.fn.delete(root, 'rf')
end)

-- 回归：恢复目标曾用「M.preview[state] 是否为 nil」判断预览链起点。主窗被 :e 换过之后
-- 追踪仍会残留，于是链起点判断失效，恢复目标停在更早的那个文件上，关面板会把用户
-- 正在编辑的文件顶掉
test('主窗被外部换过之后，恢复目标跟到用户当前的文件', function()
  local root = make_fixture()
  local main, state = open_layout()

  local previewed = vim.fn.tempname() .. '.txt'
  vim.fn.writefile({ 'previewed' }, previewed)
  Preview.preview_file(state, previewed)

  -- 用户在主窗里手动打开另一个文件：预览追踪没被清，但窗里已经是用户内容
  local opened = vim.fn.tempname() .. '.txt'
  vim.fn.writefile({ 'opened' }, opened)
  vim.api.nvim_win_call(main, function()
    vim.cmd('edit ' .. vim.fn.fnameescape(opened))
  end)
  local opened_buf = vim.api.nvim_win_get_buf(main)

  Preview.preview_dir(state, root)
  Preview.discard_info_preview(state)

  local shown = vim.api.nvim_win_get_buf(main)
  assert(shown == opened_buf, '关闭面板后应回到用户手动打开的文件，实际是: ' .. vim.api.nvim_buf_get_name(shown))

  vim.fn.delete(root, 'rf')
  vim.fn.delete(previewed)
  vim.fn.delete(opened)
end)

test('属性页被外部 wipe 后关闭仍取消扫描并清空追踪', function()
  local root = make_fixture()
  local main, state = open_layout({ directory_preview = { scan_on_demand = false, budget_ms = 1 } })

  Preview.preview_dir(state, root)
  local info = vim.api.nvim_win_get_buf(main)
  assert(Dir.scanning[state] ~= nil, '回归前提失败：目录扫描没有启动')

  local opened = vim.fn.tempname() .. '.txt'
  vim.fn.writefile({ 'opened' }, opened)
  vim.api.nvim_win_call(main, function()
    vim.cmd('edit ' .. vim.fn.fnameescape(opened))
  end)
  assert(not vim.api.nvim_buf_is_valid(info), '回归前提失败：外部 edit 没有 wipe 属性页')

  Preview.discard_info_preview(state)

  assert(Dir.scanning[state] == nil, '关闭面板后目录扫描仍在追踪')
  assert(Preview._preview[state] == nil, '关闭面板后失效属性页仍残留在预览单槽')

  vim.fn.delete(root, 'rf')
  vim.fn.delete(opened)
end)

test('二进制属性页同样随面板关闭而撤下', function()
  local main, state = open_layout()
  local seed = vim.api.nvim_win_get_buf(main)

  local binary = vim.fn.tempname() .. '.png'
  vim.fn.writefile({ 'not really a png' }, binary)
  Preview.preview_file(state, binary)

  local info = vim.api.nvim_win_get_buf(main)
  assert(vim.b[info].vv_explorer_binary_info == true, '二进制属性页没有挂上')

  Preview.discard_info_preview(state)
  assert(vim.api.nvim_win_get_buf(main) == seed, '关闭面板后主窗仍停在二进制属性页')

  vim.fn.delete(binary)
end)

test('原文件已失效时交给 restore_main_win，且回调在目标窗口上下文中执行', function()
  local root = make_fixture()
  local seen_win, seen_cur
  local main, state = open_layout({
    restore_main_win = function(win)
      seen_win = win
      seen_cur = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true))
    end,
  })
  local seed = vim.api.nvim_win_get_buf(main)

  Preview.preview_dir(state, root)
  local info = vim.api.nvim_win_get_buf(main)
  vim.api.nvim_buf_delete(seed, { force = true })

  Preview.discard_info_preview(state)

  assert(seen_win == main, 'restore_main_win 没有拿到主窗 winid')
  assert(seen_cur == main, 'restore_main_win 没有在主窗上下文中执行')
  assert(vim.api.nvim_win_get_buf(main) ~= info, '回调换过窗口后不应再兜底')

  vim.fn.delete(root, 'rf')
end)

-- vv-dashboard 是可选依赖，测试环境里并不存在，用 package.loaded 注入替身即可覆盖适配分支
---@param open fun()?
local function with_fake_dashboard(open, fn)
  package.loaded['vv-dashboard'] = open and { open = open } or nil
  local ok, err = pcall(fn)
  package.loaded['vv-dashboard'] = nil
  if not ok then
    error(err, 0)
  end
end

test('原文件已失效且未配置回调时交给 vv-dashboard', function()
  local root = make_fixture()
  local main, state = open_layout()
  local seed = vim.api.nvim_win_get_buf(main)
  local seen_cur

  with_fake_dashboard(function()
    seen_cur = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = 'dashboard'
    vim.api.nvim_win_set_buf(0, buf)
  end, function()
    Preview.preview_dir(state, root)
    vim.api.nvim_buf_delete(seed, { force = true })
    Preview.discard_info_preview(state)
  end)

  assert(seen_cur == main, 'vv-dashboard 没有在主窗上下文中打开，实际窗口: ' .. tostring(seen_cur))
  assert(vim.bo[vim.api.nvim_win_get_buf(main)].filetype == 'dashboard', '主窗没有换成 dashboard')

  vim.fn.delete(root, 'rf')
end)

-- vv-dashboard 自己在本 tab 里挑窗，布局不明确时可能顶掉别的编辑窗；
-- 这条规则不该在 vv-explorer 里复刻，只能保守地不尝试
test('本 tab 还有别的普通窗口时不冒险交给 vv-dashboard', function()
  local root = make_fixture()
  local main, state = open_layout()
  local seed = vim.api.nvim_win_get_buf(main)

  local extra = vim.fn.tempname() .. '.txt'
  vim.fn.writefile({ 'extra' }, extra)
  vim.api.nvim_win_call(main, function()
    vim.cmd('rightbelow split ' .. vim.fn.fnameescape(extra))
  end)

  local called = false
  local info
  with_fake_dashboard(function()
    called = true
  end, function()
    Preview.preview_dir(state, root)
    info = vim.api.nvim_win_get_buf(main)
    vim.api.nvim_buf_delete(seed, { force = true })
    Preview.discard_info_preview(state)
  end)

  assert(not called, '布局不明确时不应调用 vv-dashboard')
  assert(vim.api.nvim_win_get_buf(main) ~= info, '不尝试 dashboard 也必须把过期属性页换走')

  vim.fn.delete(root, 'rf')
  vim.fn.delete(extra)
end)

test('vv-dashboard 不可用时退化为空白 buffer，绝不留下过期属性页', function()
  local root = make_fixture()
  local main, state = open_layout()
  local seed = vim.api.nvim_win_get_buf(main)

  assert(package.loaded['vv-dashboard'] == nil, '本用例前提是 vv-dashboard 不可用')

  Preview.preview_dir(state, root)
  local info = vim.api.nvim_win_get_buf(main)
  vim.api.nvim_buf_delete(seed, { force = true })

  Preview.discard_info_preview(state)

  local shown = vim.api.nvim_win_get_buf(main)
  assert(shown ~= info, '没有恢复目标时仍把过期属性页留在了主窗')
  assert(vim.api.nvim_buf_get_name(shown) == '', '兜底应当是空白 buffer')

  vim.fn.delete(root, 'rf')
end)


-- vv-dashboard 是跨 tab 单例：已在别的 tab 打开时它的 open() 会先跳到那个窗口再返回，
-- 这一跳会触发 TabEnter / WinEnter。必须在调用前拦下，而不是事后比对 buffer
test('vv-dashboard 已在别处打开时不调用 open，直接退化为空白 buffer', function()
  local root = make_fixture()
  local main, state = open_layout()
  local seed = vim.api.nvim_win_get_buf(main)

  local called = false
  local info
  package.loaded['vv-dashboard'] = {
    is_open = function() return true end,
    open = function() called = true end,
  }
  local ok, err = pcall(function()
    Preview.preview_dir(state, root)
    info = vim.api.nvim_win_get_buf(main)
    vim.api.nvim_buf_delete(seed, { force = true })
    Preview.discard_info_preview(state)
  end)
  package.loaded['vv-dashboard'] = nil
  if not ok then error(err, 0) end

  assert(not called, 'dashboard 已打开时不应再调用 open')
  local shown = vim.api.nvim_win_get_buf(main)
  assert(shown ~= info, '跳过 dashboard 后仍把过期属性页留在了主窗')
  assert(vim.api.nvim_buf_get_name(shown) == '', '跳过 dashboard 后兜底应当是空白 buffer')

  vim.fn.delete(root, 'rf')
end)

print('\n' .. string.rep('─', 50))
print(('共 %d 项: %d 通过, %d 失败'):format(passed + failed, passed, failed))
if failed > 0 then
  print('存在失败项')
  vim.cmd('cquit 1')
end
print('全部通过')

-- 场景运行时初始化夹具；不参与 mini.test 收集。
return function()
  -- vv-explorer 目录属性预览：挂载、异步补算、取消与缓存
  --
  -- 覆盖目录预览区别于文件预览的四件事：
  --   ① 目录节点也能进主窗，且用 nofile scratch 而不是把目录当文件打开
  --   ② 递归统计是异步补算的，先出浅层数字，跑完再换成最终值
  --   ③ 光标移开后在途统计必须停下，且过期结果不许写回已经换掉的主窗
  --   ④ 跑完的结果进缓存，回到同一目录时不再重扫


  local root = vim.env.VV_TEST_REPO


  local Config = require('vv-explorer.config')
  local Dir = require('vv-explorer.preview.dir')
  local Preview = require('vv-explorer.preview')


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
  -- 可选 dashboard 用运行时替身覆盖适配分支。
  local function with_fake_dashboard(open, fn)
    package.loaded['vv-dashboard'] = open and { open = open } or nil
    local ok, err = pcall(fn)
    package.loaded['vv-dashboard'] = nil
    assert(ok, err)
  end
  return { with_fake_dashboard = with_fake_dashboard, Config = Config, Dir = Dir, Preview = Preview, make_fixture = make_fixture, open_layout = open_layout, text_of = text_of }
end

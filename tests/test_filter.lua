local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["过滤匹配模式、真实 Git 索引与路径补全保留正确范围"] = function()
  child.lua_func(function()
    -- vv-explorer 过滤匹配器行为

    local root = vim.env.VV_TEST_REPO

    local Filter = require('vv-explorer.filter')

    local cwd = '/project'
    local index = {
      cwd .. '/src/index.lua',
      cwd .. '/tests/index.lua',
      cwd .. '/src/component.ts',
    }
    local rels = Filter.build_rels(index, cwd)

    assert(vim.deep_equal(rels, {
      'src/index.lua',
      'tests/index.lua',
      'src/component.ts',
    }), 'build_rels 只能移除 cwd 前缀')

    assert(Filter.next_mode('fuzzy') == 'glob', 'fuzzy 必须切换到 glob')
    assert(Filter.next_mode('glob') == 'regex', 'glob 必须切换到 regex')
    assert(Filter.next_mode('regex') == 'fuzzy', 'regex 必须循环回 fuzzy')
    assert(Filter.next_mode('unknown') == 'fuzzy', '未知模式必须回落到 fuzzy')
    assert(Filter.display('regex').label == 'Regex', '模式展示 metadata 必须保持公开')

    local empty = Filter.match(index, rels, cwd, '', 'fuzzy')
    assert(empty.total_count == 0 and #empty.abs == 0, '空查询不得产生结果')

    local fuzzy = Filter.match(index, rels, cwd, 'idx', 'fuzzy')
    assert(fuzzy.total_count == 2, '文件名模糊匹配必须保留同名条目')
    assert(#fuzzy.positions == 2, '每个模糊匹配结果必须提供高亮位置')
    for result_index, rel in ipairs(fuzzy.rels) do
      local slash = assert(rel:find('/[^/]*$'))
      for _, position in ipairs(fuzzy.positions[result_index]) do
        assert(position >= slash, '文件名匹配位置必须偏移到完整相对路径')
      end
    end

    local limited = Filter.match(index, rels, cwd, 'idx', 'fuzzy', 1)
    assert(limited.total_count == 2, '结果限制必须保留限制前总数')
    assert(#limited.abs == 1 and #limited.positions == 1, '结果限制必须约束所有结果数组')

    local regex = Filter.match(index, rels, cwd, 'lua$', 'regex')
    assert(vim.deep_equal(regex.rels, {
      'src/index.lua',
      'tests/index.lua',
    }), 'regex 结果必须保持排序及相对路径')

    local glob = Filter.match(index, rels, cwd, '*.lua', 'glob')
    assert(vim.deep_equal(glob.rels, {
      'src/index.lua',
      'tests/index.lua',
    }), '文件名 glob 必须跨目录层级搜索')

    local shorthand = Filter.match(index, rels, cwd, 'src', 'glob')
    assert(vim.deep_equal(shorthand.rels, {
      'src/component.ts',
      'src/index.lua',
    }), 'glob 路径简写必须匹配路径及子项')

    local glob_list = Filter.match(index, rels, cwd, 'src, tests', 'glob')
    assert(vim.deep_equal(glob_list.rels, {
      'src/component.ts',
      'src/index.lua',
      'tests/index.lua',
    }), '顶层逗号必须组合 glob 简写条目')

    local excluded = Filter.match(index, rels, cwd, 'src, !*.ts', 'glob')
    assert(vim.deep_equal(excluded.rels, {
      'src/index.lua',
    }), '否定 glob 简写必须排除匹配条目')

    local visible, directories = Filter.visible_set({ cwd .. '/src/index.lua' }, cwd)
    assert(visible[cwd .. '/src/index.lua'], '匹配文件必须可见')
    assert(visible[cwd .. '/src'], '匹配文件的父目录必须可见')
    assert(directories[cwd .. '/src'], '匹配文件的父项必须标记为目录')
    assert(not visible[cwd], '过滤根目录不得作为子结果插入')

    local git_fixture = vim.fn.tempname()
    vim.fn.mkdir(git_fixture .. '/tracked-dir', 'p')
    vim.fn.writefile({ 'tracked' }, git_fixture .. '/tracked-dir/file.txt')
    vim.fn.writefile({ 'tracked hidden' }, git_fixture .. '/.tracked-hidden')
    vim.fn.writefile({ 'custom' }, git_fixture .. '/excluded.txt')
    vim.fn.writefile({ 'hidden' }, git_fixture .. '/.hidden-untracked')
    assert(vim.system({ 'git', 'init', '-q', git_fixture }):wait().code == 0)
    assert(vim.system({
      'git', '-C', git_fixture, 'add',
      'tracked-dir/file.txt', '.tracked-hidden', 'excluded.txt',
    }):wait().code == 0)

    local git_paths
    local git_directories
    assert(Filter.build_index(git_fixture, {
      hidden = false,
      show_ignored = false,
      custom = { 'excluded.txt' },
    }, function(paths, is_dir_map)
      git_paths = paths
      git_directories = is_dir_map
    end))
    assert(vim.wait(2000, function() return git_paths ~= nil end), 'Git 过滤索引超时')
    assert(git_paths and git_directories)
    ---@cast git_paths string[]
    ---@cast git_directories table<string, boolean>

    local git_set = {}
    for _, path in ipairs(git_paths) do git_set[path] = true end
    assert(not git_set[git_fixture .. '/.hidden-untracked'], '隐藏的 untracked 文件必须保持排除')
    assert(git_set[git_fixture .. '/.tracked-hidden'], 'tracked 隐藏文件必须遵守树可见性')
    assert(not git_set[git_fixture .. '/excluded.txt'], '自定义 glob 也必须排除已跟踪文件')
    assert(git_set[git_fixture .. '/tracked-dir'], 'Git 文件路径必须重建父目录')
    assert(git_directories[git_fixture .. '/tracked-dir'], '重建父项必须标记为目录')
    vim.fn.delete(git_fixture, 'rf')

    local descriptor = require('vv-explorer.completion').descriptor({
      root = { path = cwd },
      filter = {
        active = true,
        mode = 'fuzzy',
        index = index,
        index_rels = rels,
        is_dir_map = {},
      },
    })
    local completion = descriptor.complete({
      bufnr = 0,
      line = 'idx',
      cursor = { 2, 3 },
    }, {
      max_items = 1,
      scan_max_items = 1000,
      timeout_ms = 250,
    })
    assert(type(completion) == 'table')
    ---@cast completion vv-utils.path_completion.Result
    assert(#completion.items == 1, '过滤补全必须遵守共享最终候选上限')
    assert(completion.items[1].word:match('index%.lua$'), '过滤补全必须复用匹配路径')
    assert(completion.pre_filtered == true, '过滤补全必须声明已有排序')
    assert(completion.items[1].rank == 1, '过滤补全必须提供匹配排序值')

    local glob_index = {
      cwd .. '/packages',
      cwd .. '/packages/core',
      cwd .. '/packages/core/src',
      cwd .. '/src',
    }
    local glob_directories = {}
    for _, path in ipairs(glob_index) do glob_directories[path] = true end
    local glob_state = {
      root = { path = cwd },
      filter = {
        active = true,
        mode = 'glob',
        index = glob_index,
        index_rels = Filter.build_rels(glob_index, cwd),
        is_dir_map = glob_directories,
      },
    }
    local glob_descriptor = require('vv-explorer.completion').descriptor(glob_state)
    assert(glob_descriptor.enabled(), 'glob 过滤必须启用路径补全')
    local glob_completion = glob_descriptor.complete({
      bufnr = 0,
      line = 'core/sr',
      cursor = { 2, #'core/sr' },
    }, {
      max_items = 10,
      scan_max_items = 1000,
      timeout_ms = 250,
    })
    assert(type(glob_completion) == 'table')
    ---@cast glob_completion vv-utils.path_completion.Result
    assert(glob_completion.items[1].word == 'packages/core/src/', vim.inspect(glob_completion.items))
    assert(glob_completion.items[1].kind == 'Folder')
    assert(glob_completion.pre_filtered == true and glob_completion.items[1].rank == 1)

    package.loaded['blink.cmp.types'] = {
      CompletionItemKind = { File = 17, Folder = 19 },
    }
    local completion_buf = vim.api.nvim_create_buf(false, true)
    local Completion = require('vv-utils.completion')
    Completion.attach(completion_buf, glob_descriptor)
    local blink_response
    require('vv-utils.blink').new({ max_items = 10 }):get_completions({
      bufnr = completion_buf,
      line = 'core/sr',
      cursor = { 1, #'core/sr' },
    }, function(response) blink_response = response end)
    assert(blink_response and blink_response.items[1].textEdit.newText == 'packages/core/src/')
    assert(blink_response.items[1].kind == 19, 'Blink 适配必须保留索引中的 Folder 候选')
    Completion.detach(completion_buf)
    vim.api.nvim_buf_delete(completion_buf, { force = true })
    package.loaded['blink.cmp.types'] = nil

    glob_state.filter.mode = 'regex'
    assert(not glob_descriptor.enabled(), 'regex 过滤必须保持路径补全禁用')
  end)
end

return T

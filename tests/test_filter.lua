-- vv-explorer 过滤匹配器行为
-- 运行：nvim --headless -u NONE -l tests/test_filter.lua

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(root)

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
}), 'build_rels should remove only the cwd prefix')

assert(Filter.next_mode('fuzzy') == 'glob', 'fuzzy should advance to glob')
assert(Filter.next_mode('glob') == 'regex', 'glob should advance to regex')
assert(Filter.next_mode('regex') == 'fuzzy', 'regex should wrap to fuzzy')
assert(Filter.next_mode('unknown') == 'fuzzy', 'unknown mode should fall back to fuzzy')
assert(Filter.display('regex').label == 'Regex', 'mode display metadata should remain public')

local empty = Filter.match(index, rels, cwd, '', 'fuzzy')
assert(empty.total_count == 0 and #empty.abs == 0, 'empty query should not produce results')

local fuzzy = Filter.match(index, rels, cwd, 'idx', 'fuzzy')
assert(fuzzy.total_count == 2, 'basename fuzzy matching should retain duplicate basenames')
assert(#fuzzy.positions == 2, 'each fuzzy result should expose highlight positions')
for result_index, rel in ipairs(fuzzy.rels) do
  local slash = assert(rel:find('/[^/]*$'))
  for _, position in ipairs(fuzzy.positions[result_index]) do
    assert(position >= slash, 'basename positions should be offset into the full relative path')
  end
end

local limited = Filter.match(index, rels, cwd, 'idx', 'fuzzy', 1)
assert(limited.total_count == 2, 'result limit must preserve the pre-limit total')
assert(#limited.abs == 1 and #limited.positions == 1, 'result limit should cap all result arrays')

local regex = Filter.match(index, rels, cwd, 'lua$', 'regex')
assert(vim.deep_equal(regex.rels, {
  'src/index.lua',
  'tests/index.lua',
}), 'regex results should remain sorted and path-relative')

local glob = Filter.match(index, rels, cwd, '*.lua', 'glob')
assert(vim.deep_equal(glob.rels, {
  'src/index.lua',
  'tests/index.lua',
}), 'basename glob should search across directory levels')

local shorthand = Filter.match(index, rels, cwd, 'src', 'glob')
assert(vim.deep_equal(shorthand.rels, {
  'src/component.ts',
  'src/index.lua',
}), 'glob path shorthand should match both the path and its descendants')

local glob_list = Filter.match(index, rels, cwd, 'src, tests', 'glob')
assert(vim.deep_equal(glob_list.rels, {
  'src/component.ts',
  'src/index.lua',
  'tests/index.lua',
}), 'top-level commas should combine glob shorthand entries')

local excluded = Filter.match(index, rels, cwd, 'src, !*.ts', 'glob')
assert(vim.deep_equal(excluded.rels, {
  'src/index.lua',
}), 'negated glob shorthand should exclude matching entries')

local visible, directories = Filter.visible_set({ cwd .. '/src/index.lua' }, cwd)
assert(visible[cwd .. '/src/index.lua'], 'matched file should be visible')
assert(visible[cwd .. '/src'], 'matched file parent should be visible')
assert(directories[cwd .. '/src'], 'matched file parent should be marked as a directory')
assert(not visible[cwd], 'filter root should not be inserted as a child result')

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
assert(vim.wait(2000, function() return git_paths ~= nil end), 'git filter index timed out')
assert(git_paths and git_directories)
---@cast git_paths string[]
---@cast git_directories table<string, boolean>

local git_set = {}
for _, path in ipairs(git_paths) do git_set[path] = true end
assert(not git_set[git_fixture .. '/.hidden-untracked'], 'hidden untracked files should stay excluded')
assert(git_set[git_fixture .. '/.tracked-hidden'], 'tracked hidden files should follow Tree visibility')
assert(not git_set[git_fixture .. '/excluded.txt'], 'custom globs should exclude tracked files too')
assert(git_set[git_fixture .. '/tracked-dir'], 'git file paths should rebuild parent directories')
assert(git_directories[git_fixture .. '/tracked-dir'], 'rebuilt parents should be marked as directories')
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
assert(#completion.items == 1, 'filter completion should respect the shared final candidate limit')
assert(completion.items[1].word:match('index%.lua$'), 'filter completion should reuse matched paths')
assert(completion.pre_filtered == true, 'filter completion should declare its existing ranking')
assert(completion.items[1].rank == 1, 'filter completion should expose the matcher rank')

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
assert(glob_descriptor.enabled(), 'glob filter should enable path completion')
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
assert(blink_response.items[1].kind == 19, 'Blink adapter should preserve the indexed Folder candidate')
Completion.detach(completion_buf)
vim.api.nvim_buf_delete(completion_buf, { force = true })
package.loaded['blink.cmp.types'] = nil

glob_state.filter.mode = 'regex'
assert(not glob_descriptor.enabled(), 'regex filter should keep path completion disabled')

print('vv-explorer filter matcher: PASS')

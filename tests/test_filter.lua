-- vv-explorer filter matcher behavior
-- Run: nvim --headless -u NONE -l tests/test_filter.lua

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

local visible, directories = Filter.visible_set({ cwd .. '/src/index.lua' }, cwd)
assert(visible[cwd .. '/src/index.lua'], 'matched file should be visible')
assert(visible[cwd .. '/src'], 'matched file parent should be visible')
assert(directories[cwd .. '/src'], 'matched file parent should be marked as a directory')
assert(not visible[cwd], 'filter root should not be inserted as a child result')

print('vv-explorer filter matcher: PASS')

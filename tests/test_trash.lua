-- vv-explorer 回收站存储行为
-- 运行：nvim --headless -u NONE -l tests/test_trash.lua

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(root)

local Store = require('vv-explorer.trash.store')

local temporary = vim.fn.tempname()
local source_dir = temporary .. '/source'
local trash_dir = temporary .. '/trash'
vim.fn.mkdir(source_dir, 'p')

local store = Store.new({
  enabled = true,
  max_items = 10,
  warn_size_mb = 500,
  scan_on_open = false,
}, trash_dir)

local original = source_dir .. '/example.txt'
vim.fn.writefile({ 'payload' }, original)
local result = store:trash({ original })
assert(#result.trashed == 1 and #result.failed == 0, 'existing file should move into trash')
assert(vim.fn.filereadable(original) == 0, 'trashed file should leave its original path')

local entries = store:list()
assert(#entries == 1, 'trashed file and metadata should form one logical entry')
assert(entries[1].original_path == original, 'trash metadata should retain the original path')
assert(entries[1].basename == 'example.txt', 'trash metadata should retain the basename')
assert(entries[1].size_bytes > 0, 'trash metadata should retain the file size')

vim.fn.writefile({ 'replacement' }, original)
local restored = store:restore(entries[1])
assert(restored ~= original, 'restore should not overwrite a newly-created original path')
assert(vim.deep_equal(vim.fn.readfile(original), { 'replacement' }), 'restore must preserve the collision target')
assert(vim.deep_equal(vim.fn.readfile(restored), { 'payload' }), 'restore should recover the trashed payload')
assert(#store:list() == 0, 'restored entry should leave the trash index')

local orphan_path = trash_dir .. '/orphan.bin'
vim.fn.writefile({ 'orphan' }, orphan_path)
local orphan = assert(store:list()[1])
assert(orphan.original_path == '(unknown)', 'missing metadata should produce an explicit orphan entry')
local restored_orphan, orphan_error = pcall(store.restore, store, orphan)
assert(not restored_orphan, 'orphan entry must not restore into the current working directory')
assert(tostring(orphan_error):find('original path unknown', 1, true), 'orphan restore should explain the missing path')
store:delete_entry(orphan)
assert(vim.fn.filereadable(orphan_path) == 0, 'delete_entry should remove orphan payloads')

local missing = store:trash({ source_dir .. '/missing.txt' })
assert(#missing.trashed == 0 and #missing.failed == 1, 'missing source should be reported as a failed trash operation')

local limited_dir = temporary .. '/limited-trash'
local limited = Store.new({
  enabled = true,
  max_items = 1,
  warn_size_mb = 500,
  scan_on_open = false,
}, limited_dir)
local first = source_dir .. '/first.txt'
local second = source_dir .. '/second.txt'
vim.fn.writefile({ 'first' }, first)
vim.fn.writefile({ 'second' }, second)
limited:trash({ first, second })
assert(vim.wait(200, function() return #limited:list() == 1 end), 'max_items should prune older excess entries')
limited:empty()
assert(#limited:list() == 0, 'empty should remove payloads and metadata')

-- 容量统计：曾经调 `du -sb`，而 BSD / macOS 的 du 没有 `-b`，回调恒为 0，
-- 容量提醒（warn_size_mb）因此从未触发过
local sized_dir = temporary .. '/sized-trash'
local sized = Store.new({
  enabled = true,
  max_items = 10,
  warn_size_mb = 500,
  scan_on_open = false,
}, sized_dir)

local payload_dir = source_dir .. '/nested'
vim.fn.mkdir(payload_dir, 'p')
vim.fn.writefile({ string.rep('x', 63) }, source_dir .. '/big.txt')
vim.fn.writefile({ string.rep('y', 31) }, payload_dir .. '/inner.txt')
sized:trash({ source_dir .. '/big.txt', payload_dir })

local scanned
local scan_handle = sized:scan_size(function(bytes) scanned = bytes end)
assert(type(scan_handle.cancel) == 'function', 'scan_size should return a cancellable handle')
assert(vim.wait(5000, function() return scanned ~= nil end, 10), 'scan_size should report a size')
-- writefile 每行补一个换行：64 + 32，metadata 的 json 另算，故只断言下界与非零
assert(scanned >= 96, 'trash size should count nested payloads, got ' .. tostring(scanned))

local cancelled_bytes
local cancelled_handle = sized:scan_size(function(bytes) cancelled_bytes = bytes end)
cancelled_handle.cancel()
vim.wait(200, function() return false end, 10)
assert(cancelled_bytes == nil, 'a cancelled trash size scan must not report back')

vim.fn.delete(temporary, 'rf')
print('vv-explorer trash store: PASS')

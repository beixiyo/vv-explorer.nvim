-- 回收站面板在大量条目下仍应固定显示标题和操作提示
-- 运行：nvim --headless -u NONE -l tests/test_trash_panel.lua

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local utils = vim.fn.fnamemodify(root, ':h') .. '/vv-utils.nvim'
package.path = utils .. '/lua/?.lua;' .. utils .. '/lua/?/init.lua;' .. root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local entries = {}
for index = 1, 100 do
  entries[index] = {
    basename = ('file-%03d.txt'):format(index),
    original_path = ('/tmp/source/file-%03d.txt'):format(index),
    trashed_at = 1700000000 + index,
    size_bytes = index,
    trash_path = ('/tmp/trash/file-%03d.txt'):format(index),
    meta_path = ('/tmp/trash/file-%03d.json'):format(index),
  }
end

local cancelled = false
local store = {
  list = function() return entries end,
  scan_size = function(_, callback)
    callback(5050)
    return { cancel = function() cancelled = true end }
  end,
}

local Panel = require('vv-explorer.trash.panel')
Panel.setup()
Panel.open(store)

local window = vim.api.nvim_get_current_win()
local buffer = vim.api.nvim_win_get_buf(window)
local config = vim.api.nvim_win_get_config(window)
local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)

local function chunks_text(chunks)
  local parts = {}
  for _, chunk in ipairs(chunks or {}) do
    parts[#parts + 1] = chunk[1]
  end
  return table.concat(parts)
end

assert(#lines == #entries, '正文应只包含可滚动的回收站条目')
assert(config.height <= math.max(1, vim.o.lines - 4), '大量条目不应让浮窗越过屏幕边界')
assert(chunks_text(config.title):find('100 items', 1, true), '边框标题应固定显示条目数')
assert(chunks_text(config.title):find('4.9 KB', 1, true), '异步大小统计应更新边框标题')

local footer_before = chunks_text(config.footer)
vim.api.nvim_win_set_cursor(window, { #entries, 0 })
local footer_after = chunks_text(vim.api.nvim_win_get_config(window).footer)
assert(footer_before:find('Restore', 1, true), '边框 footer 应显示操作提示')
assert(footer_after == footer_before, '滚动到最后一项后 footer 仍应固定可见')

vim.api.nvim_win_close(window, true)
assert(cancelled, '关闭面板应取消大小扫描生命周期')

print('vv-explorer 回收站面板固定标题与页脚: PASS')

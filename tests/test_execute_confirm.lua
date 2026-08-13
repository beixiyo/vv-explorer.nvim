-- 文件执行确认浮窗：分层文本、语义高亮与确认键位

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local utils = vim.fn.fnamemodify(root, ':h') .. '/vv-utils.nvim'
package.path = utils .. '/lua/?.lua;' .. utils .. '/lua/?/init.lua;' .. package.path
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local Confirm = require('vv-explorer.execute_confirm')
local Keys = require('vv-utils.keys')
local confirmed = false
Confirm.open('/project/src/main.rs', '/project', { 'cargo', 'run' }, function()
  confirmed = true
end)

local window = vim.api.nvim_get_current_win()
local buffer = vim.api.nvim_win_get_buf(window)
assert(vim.bo[buffer].filetype == 'vv-exec-confirm', '确认框应使用共享确认 buffer')
assert(
  vim.api.nvim_win_get_config(window).title[1][1] == ' Run project entry? '
    and vim.api.nvim_win_get_config(window).title[1][2] == 'Title',
  '执行确认标题应显示在边框外层'
)
local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
assert(vim.deep_equal({ unpack(lines, 1, 8) }, {
  '  Project entry', '    /project', '  Working directory', '    /project', '', '  Command', '    $ cargo run', '',
}), '确认框应把标题放在边框，并分层显示入口、路径和命令')
assert(
  lines[9]:find('󰄬  ' .. Keys.display('<C-y>') .. '  Run', 1, true)
    and lines[9]:find('󰜺  q  Cancel', 1, true)
    and not lines[9]:find('Esc', 1, true),
  '确认框 footer 应使用共享图标和键位展示契约'
)

local marks = vim.api.nvim_buf_get_extmarks(buffer, -1, 0, -1, { details = true })
local groups = {}
for _, mark in ipairs(marks) do
  groups[mark[4].hl_group] = true
end
for _, group in ipairs({ 'Comment', 'Directory', 'String', 'DiagnosticOk' }) do
  assert(groups[group], '缺少语义高亮: ' .. group)
end

vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-y>', true, false, true), 'xt', false)
assert(confirmed, 'Ctrl+y 应确认并运行')
assert(not vim.api.nvim_win_is_valid(window), '确认后浮窗应关闭')

local single_path = "/project/scripts/hello world's.py"
Confirm.open(single_path, '/project/scripts', { 'python', single_path }, function() end, { target = 'file' })
local single_window = vim.api.nvim_get_current_win()
local single_buffer = vim.api.nvim_win_get_buf(single_window)
local single_lines = vim.api.nvim_buf_get_lines(single_buffer, 0, -1, false)
assert(vim.deep_equal({ single_lines[1], single_lines[2], single_lines[7] }, {
  '  File',
  '    ' .. single_path,
  [[    $ python '/project/scripts/hello world'\''s.py']],
}), '单文件正文不重复标题，目标与 argv 应使用无歧义的完整展示')
vim.api.nvim_feedkeys('n', 'xt', false)
assert(not vim.api.nvim_win_is_valid(single_window), '取消后确认浮窗应关闭')
print('vv-explorer execute confirm: PASS')

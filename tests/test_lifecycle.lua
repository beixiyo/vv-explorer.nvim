-- vv-explorer panel state integration
-- Run: nvim --headless -u NONE -l tests/test_lifecycle.lua

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vendors .. '/vv-icons.nvim')
vim.opt.runtimepath:prepend(root)

local values = { width = 'invalid', open = true }
local writes = {}
local handle = {
  get = function(_, field, default)
    local value = values[field]
    return value == nil and default or value
  end,
  set = function(_, field, value)
    values[field] = value
    writes[#writes + 1] = { field = field, value = value }
    return true
  end,
}

local function explorer_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == 'vv-explorer' then return win end
  end
  error('explorer window not found')
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, 'p')
local previous_cwd = vim.fn.getcwd()
vim.cmd.cd(vim.fn.fnameescape(tmp))
local target = tmp .. '/target.lua'
vim.fn.writefile({ 'return true' }, target)
vim.cmd.edit(vim.fn.fnameescape(target))
local target_buf = vim.api.nvim_get_current_buf()

local explorer = require('vv-explorer')
explorer.setup({
  state = handle,
  width = 33,
  persist_open = true,
  preview = false,
  watch = false,
  follow_file = true,
  git = false,
  diagnostics = false,
  trash = false,
  global_mappings = false,
})

vim.wait(100, function() return explorer.is_open() end)
assert(explorer.is_open(), 'persisted open intent should restore the explorer during setup')
assert(vim.api.nvim_win_get_width(explorer_win()) == 33, 'invalid persisted width should fall back to config')
assert(values.open == true, 'opening should persist visible intent')
assert(
  vim.api.nvim_get_current_buf() == target_buf,
  'restoring persisted open state must keep focus in the startup file buffer'
)

local expected_path = assert(vim.uv.fs_realpath(target))
assert(
  explorer.get_node_path() == expected_path,
  'restoring persisted open state should reveal the startup file without taking focus'
)

explorer.reveal()
assert(not explorer.is_open(), 'reveal should close an open explorer')

explorer.reveal()
assert(explorer.is_open(), 'reveal should open a closed explorer')
assert(
  explorer.get_node_path() == expected_path,
  'opening through reveal should focus the current file'
)

vim.cmd('vertical resize 47')
vim.api.nvim_exec_autocmds('WinResized', {})
vim.wait(250, function() return values.width == 47 end)
assert(values.width == 47, 'real :vertical resize should persist after debounce')

local resume = explorer.suspend()
assert(type(resume) == 'function', 'open explorer should provide a resume callback')
assert(not explorer.is_open(), 'suspend should hide the window')
assert(values.open == true, 'suspend must preserve visible intent')
local resume_win = vim.api.nvim_get_current_win()
local resume_buf = vim.api.nvim_get_current_buf()

resume()
assert(explorer.is_open(), 'resume should restore the window')
assert(vim.api.nvim_win_get_width(explorer_win()) == 47, 'resume should restore the tracked width')
assert(vim.api.nvim_get_current_win() == resume_win, 'resume should preserve the current window')
assert(vim.api.nvim_get_current_buf() == resume_buf, 'resume should preserve the current buffer')

explorer.close()
assert(not explorer.is_open(), 'close should hide the window')
assert(values.open == false, 'explicit close should persist closed intent')

local width_writes = 0
for _, write in ipairs(writes) do
  if write.field == 'width' then width_writes = width_writes + 1 end
end
assert(width_writes >= 1, 'width should be written through the registered state handle')

vim.cmd.cd(vim.fn.fnameescape(previous_cwd))
vim.fn.delete(tmp, 'rf')
print('vv-explorer lifecycle: PASS')

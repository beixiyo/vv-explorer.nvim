-- LSP 编辑 + 真实文件移动的集成：被移动文件自身的编辑必须落盘，部分失败必须只回滚 buffer、不在旧路径复活文件
--
-- 真实的：Transfer.execute_async / Installer / Fs.sync_buffers / WorkspaceEdit / 磁盘。
-- 桩掉的：LSP 客户端请求（返回固定 WorkspaceEdit）
-- 不覆盖：clipboard.lua 里「有一项失败就整体回滚」的策略本身，这里在 after_moves 里复刻了同样的判断

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ':h') .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(root)
vim.o.confirm = false

local temporary = vim.fn.tempname()
assert(vim.fn.mkdir(temporary, 'p') == 1)
temporary = assert(vim.uv.fs_realpath(temporary))

local function text_edit(path, line)
  return {
    [vim.uri_from_fname(path)] = {
      { range = { start = { line = line, character = 8 }, ['end'] = { line = line, character = 13 } }, newText = './new' },
    },
  }
end

local fixture -- 每个场景一套全新目录
local function edit_changes()
  return vim.tbl_extend('error',
    text_edit(fixture.src .. '/a.ts', 0),     -- 被移动文件自身
    text_edit(fixture.other, 0),              -- 别处未打开的文件
    text_edit(fixture.dirty, 1))              -- 已打开且用户有未保存修改
end

package.loaded['vv-utils.lsp.file_operations'] = {
  clients = function() return { { name = 'fixture-lsp' } } end,
  will_rename_many_async = function(_, _, on_done)
    on_done({ { edit = { changes = edit_changes() }, encoding = 'utf-16' } }, false)
  end,
  notify_did_rename_many = function() end,
}

local Transfer = require('vv-explorer.actions.transfer')
local Lsp = require('vv-explorer.lsp')

local function disk(path) return vim.fn.readfile(path)[1] end
local function exists(path) return vim.uv.fs_stat(path) ~= nil end

local function new_fixture(name)
  local base = temporary .. '/' .. name
  assert(vim.fn.mkdir(base .. '/src', 'p') == 1)
  assert(vim.fn.mkdir(base .. '/dst', 'p') == 1)
  local f = {
    src = base .. '/src', dst = base .. '/dst',
    other = base .. '/other.ts', dirty = base .. '/dirty.ts',
  }
  vim.fn.writefile({ 'import "./old"' }, f.src .. '/a.ts')
  vim.fn.writefile({ 'import "./a"' }, f.src .. '/b.ts')
  vim.fn.writefile({ 'import "./old"' }, f.other)
  vim.fn.writefile({ 'import "./old"' }, f.dirty)
  vim.cmd('silent! %bwipeout!')
  local buf = vim.fn.bufadd(f.dirty)
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'user unsaved edit', 'import "./old"' })
  f.dirty_buf = buf
  fixture = f
  return f
end

---@param sabotage_b? boolean 在 LSP 编辑应用之后、落盘之前改动 b.ts，让它的 commit 因源快照变化而失败
local function run(f, sabotage_b)
  local plan = Transfer.plan({ f.src .. '/a.ts', f.src .. '/b.ts' }, f.dst, 'cut')
  local pending
  local outcomes_seen
  local result
  Transfer.execute_async(plan, 'increment', {
    before_moves = function(moves, proceed)
      local renames = {}
      for _, move in ipairs(moves) do renames[#renames + 1] = { old_path = move.source, new_path = move.destination } end
      Lsp.will_rename_many_async(renames, 1000, function(_, edits)
        pending = edits
        if sabotage_b then vim.fn.writefile({ 'externally changed' }, f.src .. '/b.ts') end
        proceed()
      end)
    end,
    after_moves = function(outcomes)
      outcomes_seen = outcomes
      local all_moved = true
      for _, outcome in ipairs(outcomes) do all_moved = all_moved and outcome.moved end
      if pending then pending.settle(all_moved) end
    end,
  }, function(r) result = r end)
  assert(vim.wait(3000, function() return result ~= nil end), 'execute_async must finish')
  return result, outcomes_seen
end

local function modified_named_buffers()
  local names = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified and vim.api.nvim_buf_get_name(buf) ~= '' then
      names[#names + 1] = vim.api.nvim_buf_get_name(buf)
    end
  end
  return names
end

-- 场景 1：整批成功。被移动文件自身的编辑必须保存到新路径（改名后的 buffer 对已存在文件 :write 会 E13）
local f = new_fixture('success')
local result = run(f)
assert(result.completed == 2, 'both files must be moved')
assert(not exists(f.src .. '/a.ts'), 'moved file must be gone from the old path')
assert(disk(f.dst .. '/a.ts') == 'import "./new"', 'edits to the moved file itself must be saved at its new path')
assert(disk(f.other) == 'import "./new"', 'edits to other unopened files must be saved')
assert(disk(f.dirty) == 'import "./old"', 'a buffer with pre-existing user edits must not be saved implicitly')
local modified = modified_named_buffers()
assert(#modified == 1 and modified[1] == f.dirty, 'only the user dirty buffer may remain modified, got: ' .. vim.inspect(modified))

-- 场景 2：部分失败。整体回滚只能动 buffer：旧路径不能复活，临时 buffer 不能残留，用户文件不能被重写
f = new_fixture('partial')
local dirty_mtime = vim.uv.fs_stat(f.dirty).mtime
result = run(f, true)
assert(result.completed == 1 and #result.failed >= 1, 'b must fail and a must still move')
assert(not exists(f.src .. '/a.ts'), 'rollback must not recreate the moved file at its old path')
assert(disk(f.dst .. '/a.ts') == 'import "./old"', 'rolled-back edits must not reach the moved file on disk')
assert(disk(f.other) == 'import "./old"', 'rolled-back edits must not reach other files')
modified = modified_named_buffers()
assert(#modified == 1 and modified[1] == f.dirty,
  'rollback must not leave modified buffers except the user dirty one, got: ' .. vim.inspect(modified))
local restored_lines = vim.api.nvim_buf_get_lines(f.dirty_buf, 0, -1, false)
assert(restored_lines[1] == 'user unsaved edit' and restored_lines[2] == 'import "./old"',
  'rollback must restore the dirty buffer to the user own content')
local after = vim.uv.fs_stat(f.dirty).mtime
assert(after.sec == dirty_mtime.sec and after.nsec == dirty_mtime.nsec,
  'rollback must not rewrite the file behind a dirty buffer')

-- 场景 3：已加载、未修改但内容落后于磁盘的 buffer（外部改了文件、nvim 还没 checktime）不能被写盘覆盖
local notices = {}
local original_notify = vim.notify
vim.notify = function(message) notices[#notices + 1] = message end

f = new_fixture('stale')
vim.fn.bufload(vim.fn.bufadd(f.other))
vim.fn.writefile({ 'import "./old"', '// external change' }, f.other)
run(f)
assert(vim.fn.readfile(f.other)[2] == '// external change',
  'a stale buffer must not overwrite changes made to the file by another process')
assert(table.concat(notices, '\n'):find('not saved', 1, true), 'the user must be told the edit was not saved')

-- 场景 4：只读文件不能被 write! 写穿，也不能清掉 buffer 的 readonly
notices = {}
f = new_fixture('readonly')
assert(vim.uv.fs_chmod(f.other, tonumber('444', 8)))
run(f)
assert(disk(f.other) == 'import "./old"', 'a read-only file must not be written')
assert(table.concat(notices, '\n'):find('not saved', 1, true), 'the user must be told the edit was not saved')
vim.uv.fs_chmod(f.other, tonumber('644', 8))

-- 场景 5：用户原本就在 buffer 列表里的未加载 buffer（会话恢复、:badd）不能被当成临时 buffer wipe 掉
f = new_fixture('listed')
local listed = vim.fn.bufadd(f.other)
vim.bo[listed].buflisted = true -- bufadd 默认不在列表里；会话恢复出来的 buffer 是 listed 的
assert(vim.fn.buflisted(listed) == 1 and not vim.api.nvim_buf_is_loaded(listed))
run(f)
assert(disk(f.other) == 'import "./new"', 'edit must still be saved')
assert(vim.api.nvim_buf_is_valid(listed) and vim.fn.buflisted(listed) == 1,
  'a buffer the user already had listed must stay in the buffer list')
assert(not vim.api.nvim_buf_is_loaded(listed), 'the buffer must be unloaded again, not left loaded and modified')

f = new_fixture('listed-rollback')
listed = vim.fn.bufadd(f.other)
vim.bo[listed].buflisted = true
run(f, true)
assert(vim.api.nvim_buf_is_valid(listed) and vim.fn.buflisted(listed) == 1,
  'rollback must not wipe a buffer the user already had listed either')
assert(not vim.api.nvim_buf_is_loaded(listed), 'rollback must not leave the listed buffer loaded with rolled-back edits')

-- 场景 6：被移动的只读文件自身也是编辑目标。它的 buffer 已改名，会走 write!，
-- 只读检查是这里唯一的防线（没被移动的文件由普通 :write 自己拒绝，测不到这一层）
notices = {}
f = new_fixture('readonly-moved')
assert(vim.uv.fs_chmod(f.src .. '/a.ts', tonumber('444', 8)))
run(f)
assert(disk(f.dst .. '/a.ts') == 'import "./old"', 'a read-only file that was moved must not be written through')
assert(table.concat(notices, '\n'):find('not saved', 1, true), 'the user must be told the edit was not saved')
vim.uv.fs_chmod(f.dst .. '/a.ts', tonumber('644', 8))

-- 场景 7：最常见的真实情况——已加载、未修改、与磁盘一致的 buffer 作为编辑目标
local function raw(path) local file = assert(io.open(path, 'rb')); local content = file:read('*a'); file:close(); return content end
local function write_raw(path, content) local file = assert(io.open(path, 'wb')); file:write(content); file:close() end

for _, variant in ipairs({
  { name = 'lf', old = 'import "./old"\n', new = 'import "./new"\n' },
  { name = 'crlf', old = 'import "./old"\r\n', new = 'import "./new"\r\n' },
  { name = 'bom', old = '\239\187\191import "./old"\n', new = '\239\187\191import "./new"\n' },
}) do
  f = new_fixture('clean-' .. variant.name)
  write_raw(f.other, variant.old)
  local clean = vim.fn.bufadd(f.other)
  vim.fn.bufload(clean)
  assert(not vim.bo[clean].modified)
  run(f)
  assert(raw(f.other) == variant.new,
    variant.name .. ': a clean loaded buffer must be saved with its line endings/BOM preserved')
  assert(not vim.bo[clean].modified, variant.name .. ': the buffer must not stay modified after saving')

  -- 回滚：内容还原，且不能把干净 buffer 留成 modified
  f = new_fixture('clean-rollback-' .. variant.name)
  write_raw(f.other, variant.old)
  clean = vim.fn.bufadd(f.other)
  vim.fn.bufload(clean)
  run(f, true)
  assert(raw(f.other) == variant.old, variant.name .. ': rollback must not touch the disk')
  assert(vim.api.nvim_buf_get_lines(clean, 0, -1, false)[1]:find('old', 1, true),
    variant.name .. ': rollback must restore the buffer content')
  assert(not vim.bo[clean].modified, variant.name .. ': rollback must not leave a clean buffer modified')
end

vim.notify = original_notify
vim.fn.delete(temporary, 'rf')
print('vv-explorer LSP move integration test: ok')

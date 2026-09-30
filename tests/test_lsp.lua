-- vv-explorer LSP 适配层：willRenameFiles 编辑先应用、后由 settle 决定保存或回滚
--
-- 只替换 LSP 客户端请求，WorkspaceEdit / buffer / 磁盘都是真实的

local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local root = vim.fn.fnamemodify(this, ':h:h')
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ':h') .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(root)

local temporary = vim.fn.tempname()
assert(vim.fn.mkdir(temporary, 'p') == 1)
temporary = assert(vim.uv.fs_realpath(temporary))

local unopened = temporary .. '/unopened.ts'      -- 未打开：编辑后应保存、临时 buffer 应清理
local dirty = temporary .. '/dirty.ts'            -- 已打开且用户有未保存修改：编辑后不得替用户保存
local moved_file = temporary .. '/moved.ts'       -- 被移动文件自身也是编辑目标
for _, path in ipairs({ unopened, dirty, moved_file }) do vim.fn.writefile({ 'import "./old"' }, path) end

local dirty_buf = vim.fn.bufadd(dirty)
vim.fn.bufload(dirty_buf)
vim.api.nvim_buf_set_lines(dirty_buf, 0, -1, false, { 'user unsaved edit', 'import "./old"' })

local function text_edit(path, line)
  return {
    [vim.uri_from_fname(path)] = {
      { range = { start = { line = line, character = 8 }, ['end'] = { line = line, character = 13 } }, newText = './new' },
    },
  }
end

local fixture_clients = { { name = 'fixture-lsp' } }
local edit_lines
package.loaded['vv-utils.lsp.file_operations'] = {
  clients = function() return fixture_clients end,
  will_rename_async = function(_, _, _, on_done)
    local changes = vim.tbl_extend('error', text_edit(unopened, 0), text_edit(moved_file, 0), text_edit(dirty, 1))
    edit_lines = changes
    on_done({ { edit = { changes = changes }, encoding = 'utf-16' } }, false)
  end,
  notify_did_rename = function() end,
}

local Lsp = require('vv-explorer.lsp')

local function request()
  local timed_out, pending
  Lsp.will_rename_async('/x/old.ts', '/x/new.ts', 1000, function(t, p) timed_out, pending = t, p end)
  assert(timed_out == false and pending, 'edits must be applied and returned as pending')
  return pending
end

local function disk(path) return vim.fn.readfile(path)[1] end
local function loaded_buf(path)
  local bufnr = vim.fn.bufnr(path)
  return bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) and bufnr or nil
end

-- 1) 应用后、settle 前：磁盘必须保持原样，否则 cut 的源快照复验会失败
local pending = request()
assert(disk(unopened) == 'import "./old"', 'edits must not be written before the file operation finishes')
assert(disk(moved_file) == 'import "./old"', 'moved file must stay untouched on disk until it is moved')
assert(loaded_buf(unopened), 'edit must be applied into a buffer')

-- 2) 移动失败：全部回滚，不留隐藏 modified buffer，用户自己的未保存修改保留
pending.settle(false)
assert(disk(unopened) == 'import "./old"', 'rollback must leave disk unchanged')
assert(not loaded_buf(unopened), 'rollback must remove temporary buffers')
assert(vim.api.nvim_buf_get_lines(dirty_buf, 0, -1, false)[1] == 'user unsaved edit',
  'rollback must restore the dirty buffer to its state before the edit')
assert(vim.bo[dirty_buf].modified, 'rollback must keep the user unsaved state')
pending.settle(true) -- 幂等：已 settle 后再调用不能生效
assert(disk(unopened) == 'import "./old"', 'settle must be idempotent')

-- 3) 移动成功：未打开的文件被保存并清理；用户已有未保存修改的 buffer 不被写盘
local notified = {}
local original_notify = vim.notify
vim.notify = function(message, level) notified[#notified + 1] = { message, level } end
pending = request()
pending.settle(true)
vim.notify = original_notify

assert(disk(unopened) == 'import "./new"', 'unopened file must be saved so the user does not miss the edit')
assert(disk(moved_file) == 'import "./new"', 'edited moved file must be saved too')
assert(not loaded_buf(unopened) and not loaded_buf(moved_file), 'temporary buffers must be cleaned up after saving')
assert(disk(dirty) == 'import "./old"', 'a buffer with pre-existing user edits must not be saved implicitly')
assert(vim.bo[dirty_buf].modified, 'dirty buffer must stay modified')
assert(#notified == 1 and notified[1][1]:find('unsaved changes', 1, true),
  'user must be told that a dirty buffer was edited but not saved')

vim.fn.delete(temporary, 'rf')
print('vv-explorer LSP adapter test: ok')

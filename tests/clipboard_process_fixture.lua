-- 共享剪贴板跨 Neovim 进程读写夹具

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local utils = vim.fn.fnamemodify(root, ':h') .. '/vv-utils.nvim'
vim.opt.runtimepath:prepend(utils)
vim.opt.runtimepath:prepend(root)

local Store = require('vv-explorer.clipboard_store')
local mode = assert(vim.env.VV_EXPLORER_CLIPBOARD_TEST_MODE)
local path = assert(vim.env.VV_EXPLORER_CLIPBOARD_TEST_SOURCE)
local ready_path = vim.env.VV_EXPLORER_CLIPBOARD_TEST_READY
local release_path = vim.env.VV_EXPLORER_CLIPBOARD_TEST_RELEASE
local result_path = vim.env.VV_EXPLORER_CLIPBOARD_TEST_RESULT

if mode == 'write-hold' then
  local record, error_message = Store.write('copy', { path })
  assert(record and not error_message, error_message)
  assert(ready_path and release_path)
  assert(vim.fn.writefile({ 'ready' }, ready_path) == 0)
  assert(vim.wait(10000, function() return vim.fn.filereadable(release_path) == 1 end, 5),
    'clipboard writer timed out waiting for release')
elseif mode == 'read' then
  local record, error_message = Store.read()
  assert(record and not error_message, error_message)
  assert(record.mode == 'copy' and #record.paths == 1 and record.paths[1] == vim.fs.normalize(path))
elseif mode == 'write-cut-hold' then
  local record, error_message = Store.write('cut', { path .. '-first', path .. '-remaining' })
  assert(record and not error_message, error_message)
  assert(ready_path and release_path)
  assert(vim.fn.writefile({ 'ready' }, ready_path) == 0)
  assert(vim.wait(10000, function() return vim.fn.filereadable(release_path) == 1 end, 5),
    'cut clipboard writer timed out waiting for release')
elseif mode == 'partial-cut-hold' then
  local record, error_message = Store.read()
  assert(record and not error_message, error_message)
  assert(record.mode == 'cut' and #record.paths == 2)
  local updated, current, replace_error = Store.replace_if_current(record, 'cut', { record.paths[2] }, {
    owner_id = record.owner_id,
    claim_ownership = false,
  })
  assert(updated and not replace_error, replace_error)
  assert(current and #current.paths == 1 and current.paths[1] == record.paths[2])
  assert(ready_path and release_path)
  assert(vim.fn.writefile({ 'ready' }, ready_path) == 0)
  assert(vim.wait(10000, function() return vim.fn.filereadable(release_path) == 1 end, 5),
    'partial cut consumer timed out waiting for release')
elseif mode == 'read-cut-remaining' then
  local record, error_message = Store.read()
  assert(record and not error_message, error_message)
  assert(record.mode == 'cut' and #record.paths == 1 and record.paths[1] == vim.fs.normalize(path .. '-remaining'))
elseif mode == 'write-watch' then
  local record, error_message = Store.write('copy', { path })
  assert(record and not error_message, error_message)
  assert(ready_path and result_path)
  local unsubscribe = Store.subscribe(function(current, subscribe_error)
    assert(not subscribe_error, subscribe_error)
    if not current then assert(vim.fn.writefile({ 'cleared' }, result_path) == 0) end
  end)
  assert(vim.fn.writefile({ 'ready' }, ready_path) == 0)
  assert(vim.wait(10000, function() return vim.fn.filereadable(result_path) == 1 end, 5),
    'clipboard owner timed out waiting for remote clear')
  unsubscribe()
elseif mode == 'clear' then
  local record, error_message = Store.read()
  assert(record and not error_message, error_message)
  local cleared, _, clear_error = Store.clear(record)
  assert(cleared and not clear_error, clear_error)
elseif mode == 'empty' then
  local record, error_message = Store.read()
  assert(not record and not error_message, error_message)
elseif mode == 'owner-release-race' then
  -- 在退出读取和 CAS 之间，consumer 提交同一 owner 的部分进度
  local old = assert(Store.write('cut', { path .. '-first', path .. '-remaining' }))
  local read = Store.read
  local injected = false
  Store.read = function()
    local record, error_message = read()
    if not injected then
      injected = true
      assert(Store.replace_if_current(old, 'cut', { path .. '-remaining' }, {
        owner_id = old.owner_id,
        claim_ownership = false,
      }))
    end
    return record, error_message
  end
  local released, release_error = Store.release_owned()
  Store.read = read
  assert(released and not release_error, release_error)
  assert(Store.read() == nil, 'owner exit must clear consumer progress with the same owner')

  -- 同一竞争窗口如果出现新 owner，退出必须保留其记录
  assert(Store.write('copy', { path .. '-old-owner' }))
  local state = require('vv-utils.state').register('vv-explorer', 'clipboard')
  local newer = vim.deepcopy(old)
  newer.id = 'new-owner-record'
  newer.owner_id = 'different-owner'
  Store.read = function()
    local record, error_message = read()
    Store.read = read
    assert(state:set('record', newer))
    return record, error_message
  end
  assert(Store.release_owned())
  assert(Store.read().id == newer.id, 'owner exit must preserve another owner after a CAS race')
  assert(Store.clear(newer))
elseif mode == 'cas-protect' then
  local old = assert(Store.write('cut', { path .. '-old' }))
  local current = assert(Store.write('copy', { path .. '-new' }))
  local cleared, observed, clear_error = Store.clear(old)
  assert(not cleared and not clear_error, clear_error)
  assert(observed and observed.id == current.id, 'stale clear must observe the newer clipboard')

  local replaced, replacement, replace_error = Store.replace_if_current(old, 'cut', {})
  assert(not replaced and not replace_error, replace_error)
  assert(replacement and replacement.id == current.id, 'stale cut completion must preserve the newer clipboard')
else
  error('unknown clipboard fixture mode: ' .. mode)
end

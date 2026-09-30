-- vv-explorer LSP 文件操作适配层
--
-- 协议请求与 WorkspaceEdit 安全应用来自 vv-utils；本模块只保留 explorer 的
-- 异步超时回调和通知方式
local FileOperations = require('vv-utils.lsp.file_operations')
local WorkspaceEdit = require('vv-utils.lsp.workspace_edit')

local M = {}

---返回当前支持 workspace/willRenameFiles 的客户端列表
---@return vim.lsp.Client[]
function M.will_rename_clients()
  return FileOperations.clients('willRename')
end

---@class VVExplorerLspPendingEdits
---@field settle fun(moved: boolean) 文件操作结束后收尾；moved=true 保存未被用户改过的目标，false 回滚全部编辑

---@class VVExplorerLspEditTarget
---@field bufnr integer
---@field keep_unsaved boolean 应用前 buffer 已有用户未保存修改，不自动保存
---@field temporary boolean 应用前文件未加载，buffer 由 WorkspaceEdit 临时创建

---@param transaction table
---@return VVExplorerLspEditTarget[]
local function collect_targets(transaction)
  local targets = {}
  for _, state in pairs(transaction.states or {}) do
    targets[#targets + 1] = {
      bufnr = vim.uri_to_bufnr(state.uri),
      keep_unsaved = state.modified == true,
      temporary = state.bufnr == nil,
    }
  end
  return targets
end

---@param transaction table
---@param targets VVExplorerLspEditTarget[]
---@param moved boolean
local function settle_edits(transaction, targets, moved)
  if not moved then
    -- 文件没移动成功：编辑尚未落盘，只需还原 buffer 并清掉临时 buffer
    local ok, restore_error = pcall(WorkspaceEdit.restore, transaction)
    if not ok then vim.notify('vv-explorer: ' .. tostring(restore_error), vim.log.levels.ERROR) end
    return
  end

  local unsaved, failed = 0, {}
  for _, target in ipairs(targets) do
    local bufnr = target.bufnr
    if not vim.api.nvim_buf_is_valid(bufnr) then goto continue end

    if target.keep_unsaved then
      unsaved = unsaved + 1
    elseif vim.bo[bufnr].modified then
      -- 此时 buffer 已被 Fs.sync_buffers 改到新路径；文件不存在说明改名没有跟上，
      -- 写盘会在旧路径重新生成文件，宁可放弃保存
      local name = vim.api.nvim_buf_get_name(bufnr)
      if not vim.uv.fs_stat(name) then
        failed[#failed + 1] = name
      else
        local ok = pcall(vim.api.nvim_buf_call, bufnr, function() vim.cmd('silent noautocmd write') end)
        if not ok or vim.bo[bufnr].modified then failed[#failed + 1] = name end
      end
    end

    if target.temporary and not vim.bo[bufnr].modified and #vim.fn.win_findbuf(bufnr) == 0 then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
    ::continue::
  end

  if #failed > 0 then
    vim.notify('vv-explorer: LSP edits were applied but not saved:\n' .. table.concat(failed, '\n'), vim.log.levels.WARN)
  end
  if unsaved > 0 then
    vim.notify(('vv-explorer: LSP edited %d buffer(s) that already had unsaved changes; not saved'):format(unsaved),
      vim.log.levels.WARN)
  end
end

---把 willRenameFiles 编辑应用到 buffer，但不写盘
---@param edits { edit: table, encoding: string }[]
---@return VVExplorerLspPendingEdits?
local function apply_pending(edits)
  if #edits == 0 then return nil end

  local transaction, prepare_error = WorkspaceEdit.prepare(edits)
  if not transaction then
    vim.notify('vv-explorer: ' .. prepare_error.message, vim.log.levels.ERROR)
    return nil
  end
  local applied, apply_error = WorkspaceEdit.apply(transaction, { save = false })
  if not applied then
    vim.notify('vv-explorer: ' .. apply_error.message, vim.log.levels.ERROR)
    return nil
  end

  local targets = collect_targets(transaction)
  local settled = false
  return {
    settle = function(moved)
      if settled then return end
      settled = true
      local ok, settle_error = pcall(settle_edits, transaction, targets, moved)
      if not ok then vim.notify('vv-explorer: ' .. tostring(settle_error), vim.log.levels.ERROR) end
    end,
  }
end

---异步收集 willRenameFiles 编辑并应用到 buffer，**不保存**
---
---不能在移动前保存：编辑常常包含被移动文件自身或其子树，提前写盘会让 cut 的源快照复验失败，
---造成「别处 import 已改并落盘、文件却没移动」。调用方必须在文件操作结束后调用
---`pending.settle(moved)`：成功则保存未被用户改过的目标并清理临时 buffer，失败则整体回滚
---
---on_done 恒被调用一次；编辑失败或没有编辑时 pending 为 nil
---@param old_path string
---@param new_path string
---@param timeout_ms integer
---@param on_done fun(timed_out: boolean, pending: VVExplorerLspPendingEdits?)
function M.will_rename_async(old_path, new_path, timeout_ms, on_done)
  FileOperations.will_rename_async(old_path, new_path, timeout_ms, function(edits, timed_out)
    local ok, pending = pcall(apply_pending, edits)
    if not ok then
      vim.notify('vv-explorer: ' .. tostring(pending), vim.log.levels.ERROR)
      pending = nil
    end
    on_done(timed_out, pending)
  end)
end

---发送 workspace/didRenameFiles 通知
---@param old_path string
---@param new_path string
function M.did_rename(old_path, new_path)
  FileOperations.notify_did_rename(old_path, new_path)
end

return M

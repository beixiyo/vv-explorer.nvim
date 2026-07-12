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

---异步收集并安全应用 willRenameFiles 编辑
---@param old_path string
---@param new_path string
---@param timeout_ms integer
---@param on_done fun(timed_out: boolean)
function M.will_rename_async(old_path, new_path, timeout_ms, on_done)
  FileOperations.will_rename_async(old_path, new_path, timeout_ms, function(edits, timed_out)
    local transaction, prepare_error = WorkspaceEdit.prepare(edits)
    if not transaction then
      vim.notify('vv-explorer: ' .. prepare_error.message, vim.log.levels.ERROR)
      return on_done(timed_out)
    end
    local applied, apply_error = WorkspaceEdit.apply(transaction, { save = false })
    if not applied then
      vim.notify('vv-explorer: ' .. apply_error.message, vim.log.levels.ERROR)
    end
    on_done(timed_out)
  end)
end

---发送 workspace/didRenameFiles 通知
---@param old_path string
---@param new_path string
function M.did_rename(old_path, new_path)
  FileOperations.notify_did_rename(old_path, new_path)
end

return M

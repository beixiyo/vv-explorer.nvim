-- vv-explorer.lsp — LSP 文件操作协议层（willRenameFiles / didRenameFiles）
--
-- 纯协议：不持有 UI 状态，不依赖 render / tree / state
-- UI 编排（loading 动画、state 标记、render 调用）在调用方（crud.lua）完成

local M = {}

--- 返回当前支持 workspace/willRenameFiles 的客户端列表
---@return vim.lsp.Client[]
function M.will_rename_clients()
  return vim.tbl_filter(function(c)
    return vim.tbl_get(c, 'server_capabilities', 'workspace', 'fileOperations', 'willRename') ~= nil
  end, vim.lsp.get_clients())
end

--- 向支持 willRenameFiles 的客户端发异步请求，收集并 apply workspace edits
---
--- - 所有客户端响应完毕 → on_done(false)
--- - timeout_ms 超时 → on_done(true)
--- - 无支持客户端 → 立即 on_done(false)（不启动 timer）
---@param old_path string
---@param new_path string
---@param timeout_ms integer
---@param on_done fun(timed_out: boolean)
function M.will_rename_async(old_path, new_path, timeout_ms, on_done)
  local params = {
    files = { { oldUri = vim.uri_from_fname(old_path), newUri = vim.uri_from_fname(new_path) } },
  }
  local clients = M.will_rename_clients()

  if #clients == 0 then
    on_done(false)
    return
  end

  local pending  = #clients
  local settled  = false

  local timer = vim.uv.new_timer()
  timer:start(timeout_ms, 0, vim.schedule_wrap(function()
    if settled then return end
    settled = true
    timer:stop()
    pcall(function() timer:close() end)
    on_done(true)
  end))

  for _, client in ipairs(clients) do
    client:request('workspace/willRenameFiles', params, function(err, result)
      if settled then return end
      if not err and result then
        vim.lsp.util.apply_workspace_edit(result, client.offset_encoding)
      end
      pending = pending - 1
      if pending == 0 then
        settled = true
        timer:stop()
        pcall(function() timer:close() end)
        on_done(false)
      end
    end)
  end
end

--- 向支持 didRenameFiles 的客户端发通知（fire-and-forget）
---@param old_path string
---@param new_path string
function M.did_rename(old_path, new_path)
  local params = {
    files = { { oldUri = vim.uri_from_fname(old_path), newUri = vim.uri_from_fname(new_path) } },
  }
  for _, client in ipairs(vim.lsp.get_clients()) do
    if vim.tbl_get(client, 'server_capabilities', 'workspace', 'fileOperations', 'didRename') then
      client:notify('workspace/didRenameFiles', params)
    end
  end
end

return M

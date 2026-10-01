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
---@field path string 应用编辑时的文件路径；buffer 名与它不同说明 buffer 已被 Fs.sync_buffers 改名
---@field temporary boolean 应用前文件未加载，buffer 由 WorkspaceEdit 临时创建
---@field listed_unloaded boolean 应用前 buffer 已存在但未加载（会话恢复、:badd），结束后只能卸载，不能 wipe
---@field lines? string[] 应用前的 buffer 内容（仅原本已加载的目标）
---@field modified boolean 应用前 buffer 已有用户未保存修改：不自动保存，回滚时恢复该状态
---@field disk_content? string 应用前的磁盘内容，保存前用来确认磁盘没被外部改过

---@param transaction table
---@param listed_unloaded table<string, boolean> 应用前已存在但未加载的目标 uri
---@return VVExplorerLspEditTarget[]
local function collect_targets(transaction, listed_unloaded)
  local targets = {}
  for _, state in pairs(transaction.states or {}) do
    targets[#targets + 1] = {
      bufnr = state.bufnr or vim.uri_to_bufnr(state.uri),
      path = state.path,
      temporary = state.bufnr == nil,
      listed_unloaded = listed_unloaded[state.uri] == true,
      lines = state.lines,
      modified = state.modified == true,
      disk_content = state.disk_content,
    }
  end
  return targets
end

---@param path string
---@return string?
local function read_file(path)
  local file = io.open(path, 'rb')
  if not file then return nil end
  local content = file:read('*a')
  file:close()
  return content
end

---buffer 内容是否与磁盘内容一致，容忍 CRLF、BOM 与末尾换行
---@param lines string[]
---@param content string
---@return boolean
local function same_as_disk(lines, content)
  local disk = vim.split(content, '\n', { plain = true })
  if disk[#disk] == '' then table.remove(disk) end
  if #disk == 0 then disk = { '' } end
  for index, line in ipairs(disk) do disk[index] = (line:gsub('\r$', '')) end
  disk[1] = (disk[1]:gsub('^\239\187\191', ''))
  return vim.deep_equal(disk, lines)
end

---按名字精确查找 buffer；不用 vim.fn.bufnr，它会把路径当通配模式，`[id].tsx` 之类的文件名会匹配失败
---@param path string
---@return boolean
local function has_buffer_named(path)
  -- resolve 与 WorkspaceEdit 的 find_loaded_buffer 保持一致：LSP 返回的 URI 可能经过符号链接，
  -- 而 Neovim 的 buffer 名是解析后的真实路径
  local resolved = vim.fn.resolve(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= '' and vim.fn.resolve(name) == resolved then return true end
  end
  return false
end

---丢弃为编辑创建或加载的 buffer；用户原本就有的未加载 buffer 只卸载，仍留在 buffer 列表里
---@param target VVExplorerLspEditTarget
local function discard_buffer(target)
  if not vim.api.nvim_buf_is_valid(target.bufnr) then return end
  if target.listed_unloaded then
    pcall(vim.api.nvim_buf_delete, target.bufnr, { unload = true, force = true })
  else
    pcall(vim.api.nvim_buf_delete, target.bufnr, { force = true })
  end
end

---只回滚 buffer，绝不写盘：编辑从未落盘，而文件可能已被移走，
---此时按旧路径写回磁盘会在原位置重新生成文件；buffer 也可能已被改名，不能再按旧 URI 查找
---@param targets VVExplorerLspEditTarget[]
local function rollback_buffers(targets)
  for _, target in ipairs(targets) do
    local bufnr = target.bufnr
    if not vim.api.nvim_buf_is_valid(bufnr) then goto continue end
    if target.temporary then
      discard_buffer(target)
    elseif target.lines then
      pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, target.lines)
      vim.bo[bufnr].modified = target.modified
    end
    ::continue::
  end
end

---保存单个目标；返回是否成功
---
---失败的理由都宁可少存也不冒险覆盖：只读文件、磁盘已被外部改过、已加载的 buffer 本就落后于磁盘。
---buffer 已被 Fs.sync_buffers 改到新路径时，对已存在的文件 `:write` 会报 E13，只有这时才用
---`write!`；没改名的 buffer 保留普通 `:write`，让 Neovim 自己的「文件已被改动」检查继续生效
---@param target VVExplorerLspEditTarget
---@return boolean
local function save_target(target)
  local bufnr = target.bufnr
  if vim.bo[bufnr].readonly then return false end

  local name = vim.api.nvim_buf_get_name(bufnr)
  -- readonly 选项只反映加载时的权限；buffer 加载之后文件才被改成只读时，write! 会照样写穿
  if not vim.uv.fs_access(name, 'W') then return false end
  if target.disk_content == nil or read_file(name) ~= target.disk_content then return false end
  if target.lines and not same_as_disk(target.lines, target.disk_content) then return false end

  local command = name ~= target.path and 'silent noautocmd write!' or 'silent noautocmd write'
  local ok = pcall(vim.api.nvim_buf_call, bufnr, function() vim.cmd(command) end)
  return ok and not vim.bo[bufnr].modified
end

---@param targets VVExplorerLspEditTarget[]
---@param moved boolean
local function settle_edits(targets, moved)
  if not moved then
    rollback_buffers(targets)
    return
  end

  local unsaved, failed = 0, {}
  for _, target in ipairs(targets) do
    local bufnr = target.bufnr
    if not vim.api.nvim_buf_is_valid(bufnr) then goto continue end

    if target.modified then
      unsaved = unsaved + 1
    elseif vim.bo[bufnr].modified and not save_target(target) then
      failed[#failed + 1] = vim.api.nvim_buf_get_name(bufnr)
    end

    if target.temporary and not vim.bo[bufnr].modified and #vim.fn.win_findbuf(bufnr) == 0 then
      discard_buffer(target)
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
  -- 必须在 apply 之前记录：apply 会加载文件，之后无法区分「刚创建」与「原本就在列表里」
  local listed_unloaded = {}
  for _, state in pairs(transaction.states or {}) do
    if not state.bufnr and has_buffer_named(state.path) then listed_unloaded[state.uri] = true end
  end

  local applied, apply_error = WorkspaceEdit.apply(transaction, { save = false })
  if not applied then
    vim.notify('vv-explorer: ' .. apply_error.message, vim.log.levels.ERROR)
    return nil
  end

  local targets = collect_targets(transaction, listed_unloaded)
  local settled = false
  return {
    settle = function(moved)
      if settled then return end
      settled = true
      local ok, settle_error = pcall(settle_edits, targets, moved)
      if not ok then vim.notify('vv-explorer: ' .. tostring(settle_error), vim.log.levels.ERROR) end
    end,
  }
end

---异步收集 willRenameFiles 编辑并应用到 buffer，**不保存**
---
---多个文件放进同一个请求：服务端返回一份互相一致的编辑，总等待时间只受 timeout_ms 约束
---
---不能在移动前保存：编辑常常包含被移动文件自身或其子树，提前写盘会让 cut 的源快照复验失败，
---造成「别处 import 已改并落盘、文件却没移动」。调用方必须在文件操作结束后调用
---`pending.settle(moved)`：全部成功则保存未被用户改过的目标并清理临时 buffer，否则整体回滚
---
---on_done 恒被调用一次；编辑失败或没有编辑时 pending 为 nil
---@param renames VVLspFileRename[]
---@param timeout_ms integer
---@param on_done fun(timed_out: boolean, pending: VVExplorerLspPendingEdits?)
function M.will_rename_many_async(renames, timeout_ms, on_done)
  FileOperations.will_rename_many_async(renames, timeout_ms, function(edits, timed_out)
    local ok, pending = pcall(apply_pending, edits)
    if not ok then
      vim.notify('vv-explorer: ' .. tostring(pending), vim.log.levels.ERROR)
      pending = nil
    end
    on_done(timed_out, pending)
  end)
end

---单个文件的 willRenameFiles，语义同 will_rename_many_async
---@param old_path string
---@param new_path string
---@param timeout_ms integer
---@param on_done fun(timed_out: boolean, pending: VVExplorerLspPendingEdits?)
function M.will_rename_async(old_path, new_path, timeout_ms, on_done)
  M.will_rename_many_async({ { old_path = old_path, new_path = new_path } }, timeout_ms, on_done)
end

---发送 workspace/didRenameFiles 通知
---@param old_path string
---@param new_path string
function M.did_rename(old_path, new_path)
  FileOperations.notify_did_rename(old_path, new_path)
end

---一次发送包含多个文件的 workspace/didRenameFiles 通知
---@param renames VVLspFileRename[]
function M.did_rename_many(renames)
  FileOperations.notify_did_rename_many(renames)
end

return M

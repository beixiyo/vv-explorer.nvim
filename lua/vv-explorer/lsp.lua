-- vv-explorer LSP 文件操作适配层
--
-- 协议请求与 WorkspaceEdit 安全应用来自 vv-utils；本模块只保留 explorer 的
-- 异步超时回调和通知方式
local FileOperations = require('vv-utils.lsp.file_operations')
local WorkspaceEdit = require('vv-utils.lsp.workspace_edit')

local M = {}

---通知里最多列出的被更新文件数
local MAX_LISTED_FILES = 8

---返回当前支持 workspace/willRenameFiles 的客户端列表
---@return vim.lsp.Client[]
function M.will_rename_clients()
  return FileOperations.clients('willRename')
end

---@class VVExplorerLspPendingEdits
---@field settle fun(moved: boolean) 文件操作结束后收尾；moved=true 保存未被用户改过的目标，false 回滚全部编辑

---@class VVExplorerLspEditTarget
---@field bufnr integer
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
---
---一律用 `write!`。LSP 编辑使 buffer 处于已修改状态，而 Fs.sync_buffers 从不重读已修改的 buffer，
---改名带来的 notedited 仍在，普通 `:write` 会 E13；没改名的 buffer 用普通 `:write` 则会在文件只是被
---touch 过（内容不变）时弹出阻塞式 y/n 提示。`write!` 会跳过 Neovim 自己的只读与「文件已被改动」检查，
---所以下面几道检查是**唯一防线**，不是冗余保险：readonly / fs_access / 磁盘内容比对 / buffer 与磁盘一致性
---@param target VVExplorerLspEditTarget
---@return boolean
local function save_target(target)
  local bufnr = target.bufnr
  if vim.bo[bufnr].readonly then return false end

  local name = vim.api.nvim_buf_get_name(bufnr)
  -- readonly 选项只反映加载时的权限；加载之后才被 chmod 成只读时它仍是 false，write! 会照样写穿
  if not vim.uv.fs_access(name, 'W') then return false end
  if target.disk_content == nil or read_file(name) ~= target.disk_content then return false end
  if target.lines and not same_as_disk(target.lines, target.disk_content) then return false end

  local ok = pcall(vim.api.nvim_buf_call, bufnr, function() vim.cmd('silent noautocmd write!') end)
  return ok and not vim.bo[bufnr].modified
end

---LSP 因文件改名改写了其它文件时告知用户：这些改动是自动保存的，不通知的话用户可能永远不知道
---@param names string[] 已保存的文件
local function notify_updated(names)
  if #names == 0 then return end

  table.sort(names)
  local lines = { ('vv-explorer: LSP updated references in %d file(s):'):format(#names) }
  for index, name in ipairs(names) do
    if index > MAX_LISTED_FILES then
      lines[#lines + 1] = ('  … and %d more'):format(#names - MAX_LISTED_FILES)
      break
    end
    lines[#lines + 1] = '  ' .. vim.fn.fnamemodify(name, ':~:.')
  end
  vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO)
end

---@param targets VVExplorerLspEditTarget[]
---@param moved boolean
local function settle_edits(targets, moved)
  if not moved then
    rollback_buffers(targets)
    return
  end

  local unsaved, failed, saved = 0, {}, {}
  for _, target in ipairs(targets) do
    local bufnr = target.bufnr
    if not vim.api.nvim_buf_is_valid(bufnr) then goto continue end

    -- 保存之后临时 buffer 可能被丢弃，名字要先取
    local name = vim.api.nvim_buf_get_name(bufnr)
    if target.modified then
      unsaved = unsaved + 1
    elseif vim.bo[bufnr].modified then
      if save_target(target) then
        saved[#saved + 1] = name
      else
        failed[#failed + 1] = name
      end
    end

    if target.temporary and not vim.bo[bufnr].modified and #vim.fn.win_findbuf(bufnr) == 0 then
      discard_buffer(target)
    end
    ::continue::
  end

  notify_updated(saved)
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

---把整批移动结果映射成 LSP 收尾动作：编辑整体 settle、必要时 WARN、只对已移动的条目发 didRename
---
---编辑是按「整批都会移动」计算的：只要有一项失败，其余 import 就可能指向不存在的路径，
---无法只保留部分编辑，因此整体回滚，宁可让已移动文件的 import 保持旧值
---@param pending VVExplorerLspPendingEdits? willRenameFiles 产生的待收尾编辑；没有编辑时为 nil
---@param outcomes { source: string, destination: string, moved: boolean }[]
---@return VVExplorerLspBatchSettlement
function M.settle_batch(pending, outcomes)
  local moved_renames, all_moved = {}, true
  for _, outcome in ipairs(outcomes) do
    if outcome.moved then
      moved_renames[#moved_renames + 1] = { old_path = outcome.source, new_path = outcome.destination }
    else
      all_moved = false
    end
  end

  if pending then pending.settle(all_moved) end
  if pending and not all_moved and #moved_renames > 0 then
    vim.notify('vv-explorer: some moves failed; LSP import edits were rolled back, '
      .. 'imports of the moved files were not updated', vim.log.levels.WARN)
  end
  M.did_rename_many(moved_renames)

  return { all_moved = all_moved, moved_renames = moved_renames }
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

---@class VVExplorerLspBatchSettlement
---@field all_moved boolean 整批是否全部移动成功；决定编辑是保存还是回滚
---@field moved_renames VVLspFileRename[] 已发送 didRename 的条目（仅已移动）

return M

-- 文件传输计划与执行的业务编排

local Paths = require('vv-explorer.transfer.paths')
local Snapshot = require('vv-explorer.transfer.snapshot')
local Reservation = require('vv-explorer.transfer.reservation')
local Installer = require('vv-explorer.transfer.installer')

local M = {}

---@class VVExplorerTransferEntry
---@field source string
---@field destination string
---@field destination_path string
---@field source_snapshot table
---@field destination_snapshot table
---@field conflict boolean

---@class VVExplorerTransferPlan
---@field mode 'copy'|'cut'
---@field destination_dir string
---@field entries VVExplorerTransferEntry[]
---@field failed string[]
---@field conflicts integer

---@param paths string[]
---@param destination_dir string
---@param mode 'copy'|'cut'
---@return VVExplorerTransferPlan
function M.plan(paths, destination_dir, mode)
  assert(mode == 'copy' or mode == 'cut', "transfer mode must be 'copy' or 'cut'")
  destination_dir = Paths.normalize(destination_dir)
  local plan = { mode = mode, destination_dir = destination_dir, entries = {}, failed = {}, conflicts = 0 }
  local destinations = {}
  local destination_identity = Paths.identity(destination_dir)

  for _, raw_source in ipairs(paths) do
    local source = Paths.normalize(raw_source)
    local destination = vim.fs.joinpath(destination_dir, vim.fs.basename(source))
    local destination_path = Paths.operation_path(destination)
    -- A symlink source is copied as a link by Fs.copy, so its target is not a
    -- recursive source subtree.  Use the lexical link path for this check;
    -- regular directories still use their resolved filesystem identity.
    local source_identity = Paths.is_symlink(source) and source or Paths.identity(source)
    if Paths.under(destination_identity, source_identity) then
      plan.failed[#plan.failed + 1] = 'skip: ' .. source .. ' → inside itself'
    elseif destinations[destination_path] then
      plan.failed[#plan.failed + 1] = 'skip: multiple sources target ' .. destination
    else
      destinations[destination_path] = true
      local source_snapshot = Snapshot.snapshot(source)
      if source_snapshot.error then
        plan.failed[#plan.failed + 1] = 'could not snapshot source: ' .. source_snapshot.error
      elseif not source_snapshot.exists then
        plan.failed[#plan.failed + 1] = 'source is no longer available: ' .. source
      else
        local destination_snapshot = Snapshot.snapshot(destination_path)
        if destination_snapshot.error then
          plan.failed[#plan.failed + 1] = 'could not snapshot destination: ' .. destination_snapshot.error
        else
          local conflict = destination_snapshot.exists
          if conflict then plan.conflicts = plan.conflicts + 1 end
          plan.entries[#plan.entries + 1] = {
            source = source,
            destination = destination,
            destination_path = destination_path,
            source_snapshot = source_snapshot,
            destination_snapshot = destination_snapshot,
            conflict = conflict,
          }
        end
      end
    end
  end

  return plan
end

---@class VVExplorerTransferHooks
---@field before_move? fun(source: string, destination: string, proceed: fun()) cut 落盘前调用；destination 为最终逻辑路径，异步完成后必须调用 proceed；抛错视为已 proceed
---@field after_move? fun(source: string, destination: string, moved: boolean) cut 落盘尝试结束后调用（无论成败，只要调用过 before_move 的同一条目都会走到这里）；抛错会被忽略

---@class VVExplorerTransferResult
---@field last_dest string?
---@field completed integer
---@field completed_sources string[]
---@field failed string[]
---@field warnings string[]

---@class VVExplorerPreparedTransfer
---@field source string
---@field destination string 最终逻辑路径（increment 后可能与 entry.destination 不同）
---@field commit fun(): boolean 真正落盘并写入 result；返回是否成功

---@param plan VVExplorerTransferPlan
---@param policy 'overwrite'|'increment'
local function check_args(plan, policy)
  assert(policy == 'overwrite' or policy == 'increment',
    "transfer policy must be 'overwrite' or 'increment'")
  assert(plan.mode == 'copy' or plan.mode == 'cut',
    "transfer mode must be 'copy' or 'cut'")
end

---校验并预留目标；失败时把原因写入 result 并返回 nil。落盘留给 commit，便于调用方在两步之间等待异步工作
---@param plan VVExplorerTransferPlan
---@param policy 'overwrite'|'increment'
---@param entry VVExplorerTransferEntry
---@param reserved table<string, boolean>
---@param result VVExplorerTransferResult
---@return VVExplorerPreparedTransfer?
local function prepare_entry(plan, policy, entry, reserved, result)
  local logical_destination = entry.destination
  local destination = Paths.operation_path(logical_destination)
  if entry.destination_path and destination ~= entry.destination_path then
    result.failed[#result.failed + 1] = 'destination parent changed before paste: '
      .. logical_destination
    return nil
  end

  if not Snapshot.same(entry.source_snapshot, Snapshot.snapshot(entry.source)) then
    result.failed[#result.failed + 1] = 'source changed before paste: ' .. entry.source
    return nil
  end

  if policy == 'overwrite'
    and not Snapshot.same(entry.destination_snapshot, Snapshot.snapshot(destination))
  then
    result.failed[#result.failed + 1] = 'destination changed before overwrite: ' .. entry.destination
    return nil
  end

  local source_root = entry.source_snapshot.entries and entry.source_snapshot.entries['']
  local reservation
  if policy == 'increment' then
    local reserved_destination
    for _ = 1, 100 do
      local candidate_ok, candidate = pcall(
        Paths.unique_unreserved,
        destination, reserved, source_root and source_root.type == 'directory'
      )
      if not candidate_ok then
        result.failed[#result.failed + 1] = tostring(candidate)
        return nil
      end
      reserved[candidate] = true
      local reserve_ok, candidate_reservation = pcall(
        Reservation.reserve, candidate, source_root and source_root.type == 'directory'
      )
      if not reserve_ok then
        result.failed[#result.failed + 1] = tostring(candidate_reservation)
        return nil
      end
      if candidate_reservation then
        reserved_destination = candidate
        reservation = candidate_reservation
        break
      end
    end

    if not reserved_destination then
      result.failed[#result.failed + 1] = 'unable to reserve an incremented destination for '
        .. destination
      return nil
    end

    destination = reserved_destination
    logical_destination = vim.fs.joinpath(plan.destination_dir, vim.fs.basename(destination))
    local candidate_path_ok, candidate_path_error = Paths.check_operation_path(
      logical_destination, destination
    )

    if not candidate_path_ok then
      local reservation_error = Reservation.cleanup(reservation)
      result.failed[#result.failed + 1] = candidate_path_error
      if reservation_error then result.failed[#result.failed + 1] = reservation_error end
      return nil
    end
  end

  local destination_snapshot = policy == 'overwrite'
    and entry.destination_snapshot
    or reservation.snapshot
  if destination_snapshot.error then
    local reservation_error = Reservation.cleanup(reservation)
    result.failed[#result.failed + 1] = 'could not snapshot destination: ' .. destination_snapshot.error
    if reservation_error then result.failed[#result.failed + 1] = reservation_error end
    return nil
  end


  return {
    source = entry.source,
    destination = logical_destination,
    commit = function()
      local ok, warning_or_error = pcall(function()
        if plan.mode == 'cut' then
          return Installer.install_move(entry.source, destination, entry.source_snapshot,
            destination_snapshot, reservation, logical_destination)
        end
        return Installer.install_copy(entry.source, destination, destination_snapshot,
          entry.source_snapshot, reservation, logical_destination)
      end)

      if ok then
        result.last_dest = logical_destination
        result.completed = result.completed + 1
        result.completed_sources[#result.completed_sources + 1] = entry.source
        if warning_or_error then result.warnings[#result.warnings + 1] = warning_or_error end
        return true
      end

      local reservation_error = Reservation.cleanup(reservation)
      if reservation_error then warning_or_error = tostring(warning_or_error) .. '\n' .. reservation_error end
      result.failed[#result.failed + 1] = tostring(warning_or_error)
      return false
    end,
  }
end

---@param plan VVExplorerTransferPlan
---@return VVExplorerTransferResult
local function new_result(plan)
  return {
    last_dest = nil,
    completed = 0,
    completed_sources = {},
    failed = vim.deepcopy(plan.failed),
    warnings = {},
  }
end

---同步执行整个计划
---@param plan VVExplorerTransferPlan
---@param policy 'overwrite'|'increment'
---@return VVExplorerTransferResult
function M.execute(plan, policy)
  check_args(plan, policy)
  local result = new_result(plan)
  local reserved = {}

  for _, entry in ipairs(plan.entries) do
    local prepared = prepare_entry(plan, policy, entry, reserved, result)
    if prepared then prepared.commit() end
  end

  return result
end

---按条目串行执行，cut 在每条落盘前后触发 hooks；用于需要异步等待外部系统（如 LSP）的场景
---
---调用方负责防止并发调用和 UI 过期回写
---@param plan VVExplorerTransferPlan
---@param policy 'overwrite'|'increment'
---@param hooks VVExplorerTransferHooks
---@param on_done fun(result: VVExplorerTransferResult)
function M.execute_async(plan, policy, hooks, on_done)
  check_args(plan, policy)
  local result = new_result(plan)
  local reserved = {}
  local index = 0
  local step

  ---proceed 可能被同步调用，统一 schedule，避免多条目时 pcall 嵌套过深
  local function next_entry() vim.schedule(step) end

  step = function()
    index = index + 1
    local entry = plan.entries[index]
    if not entry then return on_done(result) end

    local prepared_ok, prepared = pcall(prepare_entry, plan, policy, entry, reserved, result)
    if not prepared_ok then
      result.failed[#result.failed + 1] = tostring(prepared)
      return next_entry()
    end
    if not prepared then return next_entry() end

    local settled = false
    local function proceed()
      if settled then return end
      settled = true
      local commit_ok, moved = pcall(prepared.commit)
      if not commit_ok then
        result.failed[#result.failed + 1] = tostring(moved)
        moved = false
      end
      if plan.mode == 'cut' and hooks.after_move then
        pcall(hooks.after_move, prepared.source, prepared.destination, moved)
      end
      next_entry()
    end

    if plan.mode == 'cut' and hooks.before_move then
      local ok = pcall(hooks.before_move, prepared.source, prepared.destination, proceed)
      if not ok then proceed() end
    else
      proceed()
    end
  end

  step()
end

---拖放仍使用无交互的递增策略
---@param paths string[]
---@param destination_dir string
---@param mode 'copy'|'cut'
function M.apply(paths, destination_dir, mode)
  return M.execute(M.plan(paths, destination_dir, mode), 'increment')
end

return M

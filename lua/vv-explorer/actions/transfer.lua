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
---@field covered table<string, string[]> cut 时被另一个已选源路径包含的子项，key 为包含它的源路径；不单独执行，包含者移动成功后视为已完成

---@param paths string[]
---@param destination_dir string
---@param mode 'copy'|'cut'
---@return VVExplorerTransferPlan
function M.plan(paths, destination_dir, mode)
  assert(mode == 'copy' or mode == 'cut', "transfer mode must be 'copy' or 'cut'")
  destination_dir = Paths.normalize(destination_dir)
  local plan = { mode = mode, destination_dir = destination_dir, entries = {}, failed = {}, conflicts = 0, covered = {} }
  local destinations = {}
  local destination_identity = Paths.identity(destination_dir)
  local entry_sources = {}

  ---@param source string
  local function plan_source(source)
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
          entry_sources[#entry_sources + 1] = source
        end
      end
    end
  end

  -- cut 时目录及其子项同批出现：只移动目录。子项若也执行，会向 LSP 发出互相矛盾的 rename，
  -- 且目录移走后子项的源快照必然失效。
  --
  -- 由外向内处理：只有祖先「已成为条目」，子项才算被覆盖——祖先在规划阶段就失败（如粘进自身）时，
  -- 子项仍应独立执行；先处理外层也保证子项挂到最外层祖先，而不是中间层。
  -- 祖先是符号链接时不覆盖：移动链接不会带走它指向的目录里的内容
  local ordered = {}
  for index, raw_source in ipairs(paths) do
    local source = Paths.normalize(raw_source)
    local _, depth = source:gsub('/', '')
    ordered[#ordered + 1] = { source = source, index = index, depth = depth }
  end
  table.sort(ordered, function(left, right)
    -- copy 不去重，保持用户选择的顺序：同名冲突时谁先被规划谁胜出，行为与去重引入前一致
    if mode == 'cut' and left.depth ~= right.depth then return left.depth < right.depth end
    return left.index < right.index
  end)
  local order = {}
  for _, item in ipairs(ordered) do
    if order[item.source] == nil then order[item.source] = item.index end
  end

  for _, item in ipairs(ordered) do
    local container
    if mode == 'cut' then
      for _, entry_source in ipairs(entry_sources) do
        if entry_source ~= item.source and Paths.under(item.source, entry_source)
          and not Paths.is_symlink(entry_source)
        then
          container = entry_source
          break
        end
      end
    end

    if container then
      plan.covered[container] = plan.covered[container] or {}
      table.insert(plan.covered[container], item.source)
    else
      plan_source(item.source)
    end
  end

  -- 处理顺序是由外向内，输出仍按用户选择的顺序，粘贴结果与焦点才可预期
  table.sort(plan.entries, function(left, right) return order[left.source] < order[right.source] end)

  return plan
end

---@class VVExplorerTransferMove
---@field source string
---@field destination string 最终逻辑路径（increment 后可能与 entry.destination 不同）

---@class VVExplorerTransferMoveOutcome : VVExplorerTransferMove
---@field moved boolean

---@class VVExplorerTransferHooks
---@field before_moves? fun(moves: VVExplorerTransferMove[], proceed: fun()) cut 落盘前对**整批**调用一次；异步完成后必须调用 proceed；抛错视为已 proceed
---@field after_moves? fun(outcomes: VVExplorerTransferMoveOutcome[]) 整批落盘尝试结束后调用（无论成败）；抛错会被忽略

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
        for _, covered in ipairs(plan.covered and plan.covered[entry.source] or {}) do
          result.completed_sources[#result.completed_sources + 1] = covered
        end
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

---先预留全部条目，cut 在整批落盘前后各触发一次 hooks；用于需要异步等待外部系统（如 LSP）的场景
---
---整批一起交给外部系统，才能合并成一个请求；代价是等待期间所有目标都处于预留状态。
---调用方负责防止并发调用和 UI 过期回写。on_done 恒被异步调用一次
---@param plan VVExplorerTransferPlan
---@param policy 'overwrite'|'increment'
---@param hooks VVExplorerTransferHooks
---@param on_done fun(result: VVExplorerTransferResult)
function M.execute_async(plan, policy, hooks, on_done)
  check_args(plan, policy)
  local result = new_result(plan)
  local reserved = {}

  ---@type VVExplorerPreparedTransfer[]
  local prepared_list = {}
  for _, entry in ipairs(plan.entries) do
    local ok, prepared = pcall(prepare_entry, plan, policy, entry, reserved, result)
    if not ok then
      result.failed[#result.failed + 1] = tostring(prepared)
    elseif prepared then
      prepared_list[#prepared_list + 1] = prepared
    end
  end

  -- 只有 proceed 会调度 run，且 proceed 自带幂等守卫，run 天然只执行一次
  local function run()
    local outcomes = {}
    for _, prepared in ipairs(prepared_list) do
      local commit_ok, moved = pcall(prepared.commit)
      if not commit_ok then
        result.failed[#result.failed + 1] = tostring(moved)
        moved = false
      end
      outcomes[#outcomes + 1] = { source = prepared.source, destination = prepared.destination, moved = moved }
    end

    if plan.mode == 'cut' and hooks.after_moves and #outcomes > 0 then
      pcall(hooks.after_moves, outcomes)
    end
    on_done(result)
  end

  -- proceed 可能被同步调用，统一 schedule，保证 on_done 恒为异步
  local proceeded = false
  local function proceed()
    if proceeded then return end
    proceeded = true
    vim.schedule(run)
  end

  if plan.mode == 'cut' and hooks.before_moves and #prepared_list > 0 then
    local moves = {}
    for _, prepared in ipairs(prepared_list) do
      moves[#moves + 1] = { source = prepared.source, destination = prepared.destination }
    end
    local ok = pcall(hooks.before_moves, moves, proceed)
    if not ok then proceed() end
  else
    proceed()
  end
end

---拖放仍使用无交互的递增策略
---@param paths string[]
---@param destination_dir string
---@param mode 'copy'|'cut'
function M.apply(paths, destination_dir, mode)
  return M.execute(M.plan(paths, destination_dir, mode), 'increment')
end

return M

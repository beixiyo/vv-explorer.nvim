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

---@param plan VVExplorerTransferPlan
---@param policy 'overwrite'|'increment'
---@return {last_dest:string?, completed:integer, completed_sources:string[], failed:string[], warnings:string[]}
function M.execute(plan, policy)
  assert(policy == 'overwrite' or policy == 'increment',
    "transfer policy must be 'overwrite' or 'increment'")
  assert(plan.mode == 'copy' or plan.mode == 'cut',
    "transfer mode must be 'copy' or 'cut'")
  local result = {
    last_dest = nil,
    completed = 0,
    completed_sources = {},
    failed = vim.deepcopy(plan.failed),
    warnings = {},
  }
  local reserved = {}

  for _, entry in ipairs(plan.entries) do
    local logical_destination = entry.destination
    local destination = Paths.operation_path(logical_destination)
    if entry.destination_path and destination ~= entry.destination_path then
      result.failed[#result.failed + 1] = 'destination parent changed before paste: '
        .. logical_destination
      goto continue
    end

    if not Snapshot.same(entry.source_snapshot, Snapshot.snapshot(entry.source)) then
      result.failed[#result.failed + 1] = 'source changed before paste: ' .. entry.source
      goto continue
    end

    if policy == 'overwrite'
      and not Snapshot.same(entry.destination_snapshot, Snapshot.snapshot(destination))
    then
      result.failed[#result.failed + 1] = 'destination changed before overwrite: ' .. entry.destination
      goto continue
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
          goto continue
        end
        reserved[candidate] = true
        local reserve_ok, candidate_reservation = pcall(
          Reservation.reserve, candidate, source_root and source_root.type == 'directory'
        )
        if not reserve_ok then
          result.failed[#result.failed + 1] = tostring(candidate_reservation)
          goto continue
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
        goto continue
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
        goto continue
      end
    end

    local destination_snapshot = policy == 'overwrite'
      and entry.destination_snapshot
      or reservation.snapshot
    if destination_snapshot.error then
      local reservation_error = Reservation.cleanup(reservation)
      result.failed[#result.failed + 1] = 'could not snapshot destination: ' .. destination_snapshot.error
      if reservation_error then result.failed[#result.failed + 1] = reservation_error end
      goto continue
    end

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
    else
      local reservation_error = Reservation.cleanup(reservation)
      if reservation_error then warning_or_error = tostring(warning_or_error) .. '\n' .. reservation_error end
      result.failed[#result.failed + 1] = tostring(warning_or_error)
    end

    ::continue::
  end

  return result
end

---拖放仍使用无交互的递增策略
---@param paths string[]
---@param destination_dir string
---@param mode 'copy'|'cut'
function M.apply(paths, destination_dir, mode)
  return M.execute(M.plan(paths, destination_dir, mode), 'increment')
end

return M

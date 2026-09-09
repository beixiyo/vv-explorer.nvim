-- 文件传输的事务安装：staging、替换、移动和跨设备 cut

local Fs = require('vv-utils.fs')
local Transaction = require('vv-utils.transaction')
local Paths = require('vv-explorer.transfer.paths')
local Snapshot = require('vv-explorer.transfer.snapshot')
local Reservation = require('vv-explorer.transfer.reservation')
local TempSlot = require('vv-explorer.transfer.temp_slot')

local uv = vim.uv or vim.loop

local function run_transaction(operations)
  local ok, error_message = Transaction.new({ operations = operations }):apply()
  if not ok then error(error_message) end
end

local function check_expected(path, expected, label)
  if not expected then return true end
  local actual = Snapshot.snapshot(path)
  if expected.error then return false, expected.error end
  if actual.error then return false, actual.error end
  if not Snapshot.same(expected, actual) then
    return false, label .. ' changed before rename'
  end
  return true
end

local function check_path_guard(opts, label)
  if not opts.path_guard then return true end
  local ok, valid, error_message = pcall(opts.path_guard)
  if not ok then return false, tostring(valid) end
  if not valid then return false, error_message or (label .. ' path changed') end
  return true
end

local function cleanup_failed_backup(backup_slot, destination, preserve)
  if not backup_slot then return end

  local has_payload = uv.fs_lstat(backup_slot.payload) ~= nil
  local has_disposal = uv.fs_lstat(backup_slot.disposal) ~= nil
  if preserve and (has_payload or has_disposal) then
    local recovery, recovery_error = Reservation.preserve_backup(backup_slot, destination)
    if recovery then
      local message = 'original destination preserved at ' .. recovery
      if recovery_error then message = message .. '; ' .. tostring(recovery_error) end
      return message
    end
    return 'backup preservation failed: ' .. tostring(recovery_error)
  end

  local cleaned, cleanup_error = backup_slot:cleanup()
  if not cleaned then return cleanup_error end
end

local function rename_operation(name, source, destination, opts)
  opts = opts or {}
  return {
    name = name,
    validate = function()
      local path_ok, path_error = check_path_guard(opts, name)
      if not path_ok then return false, path_error end
      local source_ok, source_error = check_expected(source, opts.source_snapshot, name .. ' source')
      if not source_ok then return false, source_error end
      if opts.validate_destination ~= false then
        local destination_ok, destination_error = check_expected(
          destination, opts.destination_snapshot, name .. ' destination'
        )
        if not destination_ok then return false, destination_error end
      end
      return true
    end,
    apply = function()
      local path_ok, path_error = check_path_guard(opts, name)
      if not path_ok then return false, Transaction.failure(path_error, false) end
      local source_ok, source_error = check_expected(source, opts.source_snapshot, name .. ' source')
      if not source_ok then return false, Transaction.failure(source_error, false) end
      local destination_ok, destination_error = check_expected(
        destination, opts.destination_snapshot, name .. ' destination'
      )
      if not destination_ok then return false, Transaction.failure(destination_error, false) end

      local ok, error_message = pcall(Fs.rename, source, destination)
      if not ok then return false, Transaction.failure(error_message, false) end

      if opts.verify_destination and opts.source_snapshot
        and not Snapshot.same(opts.source_snapshot, Snapshot.snapshot(destination), { ignore_ctime = true })
      then
        return false, Transaction.failure('filesystem entry changed during ' .. name, true)
      end
      if opts.on_moved then opts.on_moved(destination) end
      return true
    end,
    compensate = function()
      if not Fs.exists(destination) then return true end
      if not Fs.exists(source) then
        local restored, restore_error = pcall(Fs.rename, destination, source)
        if restored then return true end
        if not opts.recover_on_conflict then return false, restore_error end
      elseif not opts.recover_on_conflict then
        return true
      end

      local recovery, recovery_error = Reservation.preserve_backup(opts.source_slot, source)
      if not recovery then return false, recovery_error end
      if opts.on_recovery then opts.on_recovery(recovery) end
      return true
    end,
  }
end

local function isolate_source(source, source_snapshot)
  local slot = TempSlot.create(Paths.operation_path(source), 'source')
  slot:set_expected(source_snapshot)
  local isolated, isolate_error = pcall(run_transaction, {
    rename_operation('isolate source', source, slot.payload, {
      source_snapshot = source_snapshot,
      destination_snapshot = { exists = false },
      verify_destination = true,
      recover_on_conflict = true,
      source_slot = slot,
    }),
  })
  if isolated then
    local stage_snapshot = Snapshot.snapshot(slot.payload)
    if stage_snapshot.exists and not stage_snapshot.error then
      return slot, stage_snapshot
    end

    local snapshot_error = stage_snapshot.error or 'isolated source disappeared after rename'
    local restored, restore_error = Reservation.restore_isolated_source(slot, source, true)
    if not restored then snapshot_error = snapshot_error .. '\n' .. restore_error end
    error(snapshot_error)
  end

  local restored, restore_error = Reservation.restore_isolated_source(slot, source)
  if not restored then isolate_error = tostring(isolate_error) .. '\n' .. restore_error end
  error(isolate_error)
end

local function install_copy(
  source, destination, destination_snapshot, source_snapshot, reservation, logical_destination
)
  local path_ok, path_error = Paths.check_operation_path(logical_destination, destination)
  if not path_ok then error(path_error) end

  local modified = Paths.modified_buffer_under(destination)
  if modified then error('destination has a modified buffer: ' .. modified) end

  local stage_slot = TempSlot.create(destination, 'stage')
  local stage = stage_slot.payload
  local staged, stage_error = pcall(Fs.copy, source, stage)
  if not staged then
    local cleaned, cleanup_error = stage_slot:cleanup()
    if not cleaned then stage_error = tostring(stage_error) .. '\n' .. cleanup_error end
    local reservation_error = Reservation.cleanup(reservation)
    if reservation_error then stage_error = tostring(stage_error) .. '\n' .. reservation_error end
    error(stage_error)
  end

  local staged_snapshot = Snapshot.snapshot(stage)
  if staged_snapshot.error then
    local cleaned, cleanup_error = stage_slot:cleanup()
    local reservation_error = Reservation.cleanup(reservation)
    local error_message = staged_snapshot.error
    if not cleaned then error_message = error_message .. '\n' .. cleanup_error end
    if reservation_error then error_message = error_message .. '\n' .. reservation_error end
    error(error_message)
  end
  stage_slot:set_expected(staged_snapshot)
  if source_snapshot and not Snapshot.same(source_snapshot, Snapshot.snapshot(source)) then
    local cleaned, cleanup_error = stage_slot:cleanup()
    local error_message = 'source changed during staging: ' .. source
    if not cleaned then error_message = error_message .. '\n' .. cleanup_error end
    local reservation_error = Reservation.cleanup(reservation)
    if reservation_error then error_message = error_message .. '\n' .. reservation_error end
    error(error_message)
  end

  local operations = {}
  local backup_slot
  local recovery_warning
  if destination_snapshot.exists then
    backup_slot = TempSlot.create(destination, 'backup')
    backup_slot:set_expected(destination_snapshot)
    operations[#operations + 1] = rename_operation(
      'backup destination', destination, backup_slot.payload, {
        source_snapshot = destination_snapshot,
        destination_snapshot = { exists = false },
        verify_destination = true,
        recover_on_conflict = true,
        source_slot = backup_slot,
        on_moved = function(path)
          local backup_snapshot = Snapshot.snapshot(path)
          if backup_snapshot.error
            or not Snapshot.same(destination_snapshot, backup_snapshot, { ignore_ctime = true })
          then
            error(backup_snapshot.error or 'backup destination changed during isolation')
          end
        end,
        path_guard = function()
          return Paths.check_operation_path(logical_destination, destination)
        end,
        on_recovery = function(path)
          recovery_warning = Reservation.recovery_message(path, reservation)
        end,
      }
    )
  end
  operations[#operations + 1] = rename_operation('publish staged copy', stage, destination, {
    source_snapshot = staged_snapshot,
    destination_snapshot = { exists = false },
    validate_destination = false,
    source_slot = stage_slot,
    path_guard = function()
      return Paths.check_operation_path(logical_destination, destination)
    end,
  })

  local committed, commit_error = pcall(run_transaction, operations)
  if not committed then
    local cleanup_errors = {}
    local stage_cleaned, stage_cleanup_error = stage_slot:cleanup()
    if not stage_cleaned then cleanup_errors[#cleanup_errors + 1] = stage_cleanup_error end
    local reservation_errors = {}
    local reservation_error = Reservation.cleanup(reservation)
    if reservation_error then reservation_errors[#reservation_errors + 1] = reservation_error end
    local backup_cleanup_error = cleanup_failed_backup(backup_slot, destination, not reservation)
    if backup_cleanup_error then cleanup_errors[#cleanup_errors + 1] = backup_cleanup_error end
    if recovery_warning then commit_error = tostring(commit_error) .. '\n' .. recovery_warning end
    if #reservation_errors > 0 then
      commit_error = tostring(commit_error) .. '\n' .. table.concat(reservation_errors, '\n')
    end
    if #cleanup_errors > 0 then
      commit_error = tostring(commit_error) .. '\n' .. table.concat(cleanup_errors, '\n')
    end
    error(commit_error)
  end

  Paths.checktime_under(destination)
  local warnings = {}
  local stage_released, stage_release_error = stage_slot:release_empty()
  if not stage_released then
    warnings[#warnings + 1] = 'staged copy cleanup failed: ' .. tostring(stage_release_error)
  end
  if backup_slot then
    local cleaned, cleanup_error = backup_slot:cleanup()
    if not cleaned then
      if reservation then
        warnings[#warnings + 1] = 'replacement committed; increment reservation cleanup failed: '
          .. tostring(cleanup_error)
      else
        local recovery, recovery_error = Reservation.preserve_backup(backup_slot, destination)
        if recovery then
          warnings[#warnings + 1] = 'replacement committed; original destination preserved at ' .. recovery
        else
          warnings[#warnings + 1] = 'replacement committed but backup cleanup failed: '
            .. tostring(cleanup_error) .. ' (' .. tostring(recovery_error) .. ')'
        end
      end
    end
  end
  if #warnings > 0 then return table.concat(warnings, '\n') end
end

local function install_move(
  source, destination, source_snapshot, destination_snapshot, reservation, logical_destination
)
  local path_ok, path_error = Paths.check_operation_path(logical_destination, destination)
  if not path_ok then error(path_error) end

  local modified = Paths.modified_buffer_under(destination)
  if modified then
    local reservation_error = Reservation.cleanup(reservation)
    local error_message = 'destination has a modified buffer: ' .. modified
    if reservation_error then error_message = error_message .. '\n' .. reservation_error end
    error(error_message)
  end

  -- Follow a destination-parent symlink: the rename target may live on a
  -- different device even when the symlink inode itself does not.
  local parent_stat = vim.uv.fs_stat(vim.fs.dirname(destination))
  local source_root = source_snapshot.entries and source_snapshot.entries['']
  local same_device = source_root and parent_stat
    and source_root.dev ~= nil and source_root.dev == parent_stat.dev
  if not same_device then
    local isolated_ok, isolated_slot, isolated_snapshot = pcall(
      isolate_source, source, source_snapshot
    )
    if not isolated_ok then
      local reservation_error = Reservation.cleanup(reservation)
      local error_message = tostring(isolated_slot)
      if reservation_error then error_message = error_message .. '\n' .. reservation_error end
      error(error_message)
    end
    local copied, warning_or_error = pcall(
      install_copy, isolated_slot.payload, destination, destination_snapshot, isolated_snapshot,
      reservation, logical_destination
    )
    if not copied then
      local restored, restore_error = Reservation.restore_isolated_source(isolated_slot, source, true)
      local message = tostring(warning_or_error)
      local reservation_error = Reservation.cleanup(reservation)
      if reservation_error then message = message .. '\n' .. reservation_error end
      if not restored then message = message .. '\n' .. restore_error end
      error(message)
    end

    if not Snapshot.same(isolated_snapshot, Snapshot.snapshot(isolated_slot.payload)) then
      local restored, restore_error = Reservation.restore_isolated_source(isolated_slot, source, true)
      local message = 'source changed after copy; source was not removed'
      if not restored then message = message .. '\n' .. restore_error end
      error(message)
    end

    local removed, remove_error = isolated_slot:cleanup()
    if not removed then
      local restored, restore_error = Reservation.restore_isolated_source(isolated_slot, source, true)
      local cleanup_error = 'move installed but source cleanup failed: ' .. tostring(remove_error)
      if restored then
        cleanup_error = cleanup_error .. '; source restored at ' .. source
      else
        cleanup_error = cleanup_error .. '; ' .. tostring(restore_error)
      end
      error(cleanup_error)
    end

    Fs.sync_buffers(Paths.operation_path(source), destination)
    return warning_or_error
  end

  local operations = {}
  local backup_slot
  local recovery_warning
  if destination_snapshot.exists then
    backup_slot = TempSlot.create(destination, 'backup')
    backup_slot:set_expected(destination_snapshot)
    operations[#operations + 1] = rename_operation(
      'backup destination', destination, backup_slot.payload, {
        source_snapshot = destination_snapshot,
        destination_snapshot = { exists = false },
        verify_destination = true,
        recover_on_conflict = true,
        source_slot = backup_slot,
        on_moved = function(path)
          local backup_snapshot = Snapshot.snapshot(path)
          if backup_snapshot.error
            or not Snapshot.same(destination_snapshot, backup_snapshot, { ignore_ctime = true })
          then
            error(backup_snapshot.error or 'backup destination changed during isolation')
          end
        end,
        path_guard = function()
          return Paths.check_operation_path(logical_destination, destination)
        end,
        on_recovery = function(path)
          recovery_warning = Reservation.recovery_message(path, reservation)
        end,
      }
    )
  end
  operations[#operations + 1] = rename_operation('move source', source, destination, {
    source_snapshot = source_snapshot,
    destination_snapshot = { exists = false },
    validate_destination = false,
    path_guard = function()
      return Paths.check_operation_path(logical_destination, destination)
    end,
  })
  local committed, commit_error = pcall(run_transaction, operations)
  if not committed then
    local reservation_errors = {}
    local reservation_error = Reservation.cleanup(reservation)
    if reservation_error then reservation_errors[#reservation_errors + 1] = reservation_error end
    local backup_cleanup_error = cleanup_failed_backup(backup_slot, destination, not reservation)
    if backup_cleanup_error then reservation_errors[#reservation_errors + 1] = backup_cleanup_error end
    if recovery_warning then commit_error = tostring(commit_error) .. '\n' .. recovery_warning end
    if #reservation_errors > 0 then
      commit_error = tostring(commit_error) .. '\n' .. table.concat(reservation_errors, '\n')
    end
    error(commit_error)
  end

  Fs.sync_buffers(Paths.operation_path(source), destination)
  Paths.checktime_under(destination)
  if backup_slot then
    local cleaned, cleanup_error = backup_slot:cleanup()
    if not cleaned then
      if reservation then
        return 'move committed; increment reservation cleanup failed: '
          .. tostring(cleanup_error)
      end
      local recovery, recovery_error = Reservation.preserve_backup(backup_slot, destination)
      if recovery then return 'move committed; original destination preserved at ' .. recovery end
      return 'move committed but backup cleanup failed: ' .. tostring(cleanup_error)
        .. ' (' .. tostring(recovery_error) .. ')'
    end
  end
end

return {
  install_copy = install_copy,
  install_move = install_move,
}

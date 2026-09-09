-- 文件传输的目标预留、原子清理与恢复路径

local Fs = require('vv-utils.fs')
local Snapshot = require('vv-explorer.transfer.snapshot')
local TempSlot = require('vv-explorer.transfer.temp_slot')

local uv = vim.uv or vim.loop

local function recovery_sibling(destination)
  local directory = vim.fs.dirname(destination)
  local basename = vim.fs.basename(destination)
  for attempt = 1, 100 do
    local suffix = attempt == 1 and ' (recovery)' or (' (recovery %d)'):format(attempt)
    local candidate = vim.fs.joinpath(directory, basename .. suffix)
    if not Fs.exists(candidate) then return candidate end
  end
  error('unable to allocate a recovery path beside ' .. destination)
end

local function preserve_slot(slot, destination)
  local recovery = recovery_sibling(destination)
  local moved, move_error = slot:move_payload(recovery)
  if not moved then return nil, move_error end
  return recovery, move_error
end

local function cleanup_reservation(reservation, path)
  if not reservation then return end
  path = path or reservation.path

  reservation.cleanup_results = reservation.cleanup_results or {}
  if reservation.cleanup_results[path] ~= nil then
    return reservation.cleanup_results[path] or nil
  end

  local slot = TempSlot.create(path, 'cleanup')
  local isolated, isolate_error = pcall(Fs.rename, path, slot.payload)
  if not isolated then
    pcall(slot.release_empty, slot)
    if not Fs.exists(path) then return end
    local error_message = 'reserved destination isolation failed: ' .. tostring(isolate_error)
    reservation.cleanup_results[path] = error_message
    return error_message
  end

  local isolated_snapshot = Snapshot.snapshot(slot.payload)
  if isolated_snapshot.error then
    reservation.cleanup_results[path] = isolated_snapshot.error
    return isolated_snapshot.error
  end
  slot:set_expected(isolated_snapshot)

  local is_reservation = not reservation.snapshot.error
    and Snapshot.same(reservation.snapshot, isolated_snapshot, { ignore_ctime = true })
  if not is_reservation then
    local restored, restore_error
    if not Fs.exists(path) then
      restored, restore_error = slot:move_payload(path)
    end
    if restored then
      restore_error = 'reserved destination changed; preserved at ' .. path
    else
      local recovery, recovery_error = preserve_slot(slot, path)
      if recovery then
        restore_error = 'reserved destination changed; preserved at ' .. recovery
      else
        restore_error = 'reserved destination changed and recovery failed: '
          .. tostring(restore_error or recovery_error)
      end
    end
    reservation.cleanup_results[path] = restore_error
    return restore_error
  end

  local removed, remove_error = slot:cleanup()
  if removed then
    reservation.cleanup_results[path] = false
    return
  end

  -- The original reservation path is empty after isolation. Restore the
  -- owned placeholder there when cleanup fails; only an occupied path uses a
  -- visible recovery name.
  local restored_disposal, disposal_error = slot:make_payload_available()
  if restored_disposal and not Fs.exists(path) then
    local restored, restore_error = slot:move_payload(path)
    if restored then
      local error_message = 'reserved destination cleanup failed: ' .. tostring(remove_error)
      reservation.cleanup_results[path] = error_message
      return error_message
    end
    disposal_error = restore_error
  end

  local recovery, recovery_error = preserve_slot(slot, path)
  local error_message
  if recovery then
    error_message = 'reserved destination cleanup failed: ' .. tostring(remove_error)
      .. '; placeholder preserved at ' .. recovery
  else
    error_message = 'reserved destination cleanup failed: ' .. tostring(remove_error)
      .. ' (' .. tostring(disposal_error or recovery_error) .. ')'
  end
  reservation.cleanup_results[path] = error_message
  return error_message
end

local function recovery_message(path, reservation)
  if not reservation then return 'original destination preserved at ' .. path end

  local reservation_error = cleanup_reservation(reservation, path)
  if reservation_error then
    return 'reserved destination preserved at ' .. path .. ': ' .. reservation_error
  end
end

-- Fs.exists followed by Fs.rename is not a reservation: another process may
-- create the incremented name between those calls. Reserve the final name
-- with the OS exclusive-create primitives before publishing a staged transfer.
local function reserve_destination(path, is_directory)
  if Fs.exists(path) then return nil end

  Fs.mkdir_p(vim.fs.dirname(path))
  if Fs.exists(path) then return nil end

  if is_directory then
    local created, create_error = uv.fs_mkdir(path, 493)
    if not created then
      if create_error and tostring(create_error):find('EEXIST', 1, true) then return nil end
      error('reserve destination failed: ' .. path .. ' — ' .. tostring(create_error))
    end
  else
    local fd, open_error = uv.fs_open(path, 'wx', 420)
    if not fd then
      if open_error and tostring(open_error):find('EEXIST', 1, true) then return nil end
      error('reserve destination failed: ' .. path .. ' — ' .. tostring(open_error))
    end
    local closed, close_error = uv.fs_close(fd)
    if not closed then
      pcall(uv.fs_unlink, path)
      error('reserve destination close failed: ' .. path .. ' — ' .. tostring(close_error))
    end
  end

  local reservation = Snapshot.snapshot(path)
  if reservation.error then
    pcall(Fs.delete, path)
    error(reservation.error)
  end
  return { path = path, snapshot = reservation }
end

local function restore_isolated_source(slot, source, require_stage)
  if not slot then
    if require_stage then return false, 'isolated source disappeared before recovery' end
    return true
  end

  local available, availability_error = slot:make_payload_available()
  if not available then
    local recovery, recovery_error = preserve_slot(slot, source)
    if recovery then return false, 'isolated source preserved at ' .. recovery end

    local released, release_error = slot:release_empty()
    if released then return not require_stage end
    return false, availability_error or recovery_error or (
      'isolated source disappeared before recovery: ' .. tostring(release_error)
    )
  end

  local valid, validation_error = slot:validate()
  if not valid then return false, validation_error end
  if not Fs.exists(source) then
    local restored, restore_error = slot:move_payload(source)
    if restored then return true, restore_error end
  end

  local recovery, recovery_error = preserve_slot(slot, source)
  if recovery then return false, 'isolated source preserved at ' .. recovery end
  return false, tostring(recovery_error)
end

return {
  reserve = reserve_destination,
  cleanup = cleanup_reservation,
  recovery_message = recovery_message,
  preserve_backup = preserve_slot,
  restore_isolated_source = restore_isolated_source,
}

-- 文件传输集成：递增保留、完整覆盖、快照复验与 cut 语义

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local utils = vim.fn.fnamemodify(root, ':h') .. '/vv-utils.nvim'
vim.opt.runtimepath:prepend(utils)
vim.opt.runtimepath:prepend(root)

local Transfer = require('vv-explorer.actions.transfer')

local temporary = vim.fn.tempname()
local sources = temporary .. '/sources'
local destination = temporary .. '/destination'
assert(vim.fn.mkdir(sources .. '/widget', 'p') == 1)
assert(vim.fn.mkdir(destination .. '/widget', 'p') == 1)
vim.fn.writefile({ 'new' }, sources .. '/widget/shared.txt')
vim.fn.writefile({ 'source-only' }, sources .. '/widget/source-only.txt')
vim.fn.writefile({ 'old' }, destination .. '/widget/shared.txt')
vim.fn.writefile({ 'destination-only' }, destination .. '/widget/destination-only.txt')

local invalid_mode_ok, invalid_mode_error = pcall(Transfer.plan, {}, destination, 'merge')
assert(not invalid_mode_ok and tostring(invalid_mode_error):find('transfer mode', 1, true),
  'plan must reject modes outside the copy/cut union')

local increment_plan = Transfer.plan({ sources .. '/widget' }, destination, 'copy')
assert(increment_plan.conflicts == 1, 'existing destination must be reported before mutation')
local invalid_policy_ok, invalid_policy_error = pcall(Transfer.execute, increment_plan, 'merge')
assert(not invalid_policy_ok and tostring(invalid_policy_error):find('transfer policy', 1, true),
  'execute must reject policies outside the overwrite/increment union')
local increment = Transfer.execute(increment_plan, 'increment')
assert(increment.completed == 1, 'increment paste should complete')
assert(vim.fn.readfile(destination .. '/widget/shared.txt')[1] == 'old', 'increment must preserve destination')
assert(vim.fn.readfile(destination .. '/widget (copy)/shared.txt')[1] == 'new', 'increment must copy source')

local overwrite_plan = Transfer.plan({ sources .. '/widget' }, destination, 'copy')
local overwrite = Transfer.execute(overwrite_plan, 'overwrite')
assert(overwrite.completed == 1, 'overwrite paste should complete')
assert(vim.fn.readfile(destination .. '/widget/shared.txt')[1] == 'new', 'overwrite must use source content')
assert(vim.fn.filereadable(destination .. '/widget/destination-only.txt') == 0,
  'overwrite must replace the whole directory instead of merging')

local stale_plan = Transfer.plan({ sources .. '/widget' }, destination, 'copy')
assert(vim.uv.fs_rename(destination .. '/widget', destination .. '/widget-old'))
assert(vim.fn.mkdir(destination .. '/widget', 'p') == 1)
vim.fn.writefile({ 'changed-again' }, destination .. '/widget/shared.txt')
local stale = Transfer.execute(stale_plan, 'overwrite')
assert(stale.completed == 0 and #stale.failed == 1, 'changed destination must reject overwrite')
assert(vim.fn.readfile(destination .. '/widget/shared.txt')[1] == 'changed-again',
  'rejected overwrite must preserve the new destination')

local descendant_plan = Transfer.plan({ sources .. '/widget' }, destination, 'copy')
vim.fn.writefile({ 'descendant changed while the conflict modal was open' }, destination .. '/widget/shared.txt')
local descendant = Transfer.execute(descendant_plan, 'overwrite')
assert(descendant.completed == 0 and #descendant.failed == 1,
  'changed directory descendants must reject overwrite')
assert(vim.fn.readfile(destination .. '/widget/shared.txt')[1]
  == 'descendant changed while the conflict modal was open',
  'rejected descendant overwrite must preserve the changed file')

local root_source = sources .. '/root-path'
vim.fn.writefile({ 'root path' }, root_source)
local root_plan = Transfer.plan({ root_source }, '/', 'copy')
assert(root_plan.destination_dir == '/', 'filesystem root must retain its trailing separator')
assert(root_plan.entries[1].destination == '/root-path',
  'pasting into filesystem root must not produce a relative destination')

local source_alias = temporary .. '/widget-alias'
assert(vim.uv.fs_symlink(sources .. '/widget', source_alias), 'test symlink must be created')
local symlink_subtree_plan = Transfer.plan({ sources .. '/widget' }, source_alias, 'copy')
assert(#symlink_subtree_plan.entries == 0 and #symlink_subtree_plan.failed == 1,
  'a symlinked destination into the source subtree must be rejected')
assert(symlink_subtree_plan.failed[1]:find('inside itself', 1, true),
  'symlinked self-subtree rejection must explain the skipped source')

local Fs = require('vv-utils.fs')
local physical_alias_destination = temporary .. '/physical-alias-destination'
local logical_alias_destination = temporary .. '/logical-alias-destination'
assert(vim.fn.mkdir(physical_alias_destination, 'p') == 1)
assert(vim.uv.fs_symlink(physical_alias_destination, logical_alias_destination))
local alias_source = sources .. '/alias-source.txt'
vim.fn.writefile({ 'symlinked destination parent' }, alias_source)
local alias_plan = Transfer.plan({ alias_source }, logical_alias_destination, 'copy')
assert(alias_plan.entries[1].destination == logical_alias_destination .. '/alias-source.txt',
  'plan output must preserve the explorer destination alias')
assert(alias_plan.entries[1].destination_path == physical_alias_destination .. '/alias-source.txt',
  'filesystem operations must resolve the destination parent symlink')
local alias_result = Transfer.execute(alias_plan, 'increment')
assert(alias_result.completed == 1, 'copy through a symlinked destination parent should complete')
assert(alias_result.last_dest == logical_alias_destination .. '/alias-source.txt',
  'paste focus path must remain in the explorer destination namespace')
assert(vim.fn.readfile(physical_alias_destination .. '/alias-source.txt')[1]
  == 'symlinked destination parent',
  'symlinked destination parent must receive the copied entry')

local retarget_source = sources .. '/retarget-source.txt'
local retarget_a = temporary .. '/retarget-a'
local retarget_b = temporary .. '/retarget-b'
local retarget_parent = temporary .. '/retarget-parent'
vim.fn.writefile({ 'retarget source' }, retarget_source)
assert(vim.fn.mkdir(retarget_a, 'p') == 1)
assert(vim.fn.mkdir(retarget_b, 'p') == 1)
assert(vim.uv.fs_symlink(retarget_a, retarget_parent))
local retarget_plan = Transfer.plan({ retarget_source }, retarget_parent, 'copy')
assert(vim.fn.delete(retarget_parent) == 0)
assert(vim.uv.fs_symlink(retarget_b, retarget_parent))
local retarget_before_execute = Transfer.execute(retarget_plan, 'increment')
assert(retarget_before_execute.completed == 0 and #retarget_before_execute.failed == 1,
  'a destination parent retarget before execute must abort the paste')
assert(vim.fn.filereadable(retarget_a .. '/retarget-source.txt') == 0
  and vim.fn.filereadable(retarget_b .. '/retarget-source.txt') == 0,
  'a pre-execute destination retarget must not copy to either target')

assert(vim.fn.delete(retarget_parent) == 0)
assert(vim.uv.fs_symlink(retarget_a, retarget_parent))
local retarget_boundary_plan = Transfer.plan({ retarget_source }, retarget_parent, 'copy')
local retarget_copy = Fs.copy
local retargeted_during_stage = false
Fs.copy = function(source_path, destination_path)
  local copied = retarget_copy(source_path, destination_path)
  if not retargeted_during_stage
    and destination_path:find('%.vv%-explorer%-stage%-', 1, false)
  then
    retargeted_during_stage = true
    assert(vim.fn.delete(retarget_parent) == 0)
    assert(vim.uv.fs_symlink(retarget_b, retarget_parent))
  end
  return copied
end
local retarget_at_boundary = Transfer.execute(retarget_boundary_plan, 'increment')
Fs.copy = retarget_copy
assert(retargeted_during_stage, 'install boundary retarget must be exercised')
assert(retarget_at_boundary.completed == 0 and #retarget_at_boundary.failed == 1,
  'a destination parent retarget during staging must abort the paste')
assert(vim.fn.filereadable(retarget_a .. '/retarget-source.txt') == 0
  and vim.fn.filereadable(retarget_b .. '/retarget-source.txt') == 0,
  'an install boundary retarget must release its reservation without publishing')
assert(vim.fn.glob(retarget_a .. '/.retarget-source.txt.vv-explorer-*', false, true)[1] == nil,
  'an install boundary retarget must not leave a reservation cleanup orphan')

local physical_source_parent = temporary .. '/physical-source-parent'
local logical_source_parent = temporary .. '/logical-source-parent'
assert(vim.fn.mkdir(physical_source_parent, 'p') == 1)
assert(vim.uv.fs_symlink(physical_source_parent, logical_source_parent))
local logical_cut_source = logical_source_parent .. '/sync-source.txt'
local physical_cut_source = physical_source_parent .. '/sync-source.txt'
vim.fn.writefile({ 'sync source' }, logical_cut_source)
local sync_plan = Transfer.plan({ logical_cut_source }, destination, 'cut')
local sync_buffers = Fs.sync_buffers
local synced_source
local synced_destination
Fs.sync_buffers = function(source_path, destination_path)
  synced_source = source_path
  synced_destination = destination_path
end
local sync_result = Transfer.execute(sync_plan, 'increment')
Fs.sync_buffers = sync_buffers
assert(sync_result.completed == 1, 'cut through a symlinked source parent should complete')
assert(synced_source == physical_cut_source,
  'cut buffer synchronization must use the physical source path')
assert(synced_destination == destination .. '/sync-source.txt',
  'cut buffer synchronization must keep the physical destination path')
assert(vim.fn.filereadable(physical_cut_source) == 0,
  'cut through a symlinked source parent must remove the physical source')
assert(vim.fn.readfile(destination .. '/sync-source.txt')[1] == 'sync source',
  'cut through a symlinked source parent must publish the source')

local symlink_source_target = temporary .. '/symlink-source-target'
local symlink_source = temporary .. '/symlink-source'
assert(vim.fn.mkdir(symlink_source_target, 'p') == 1)
assert(vim.uv.fs_symlink(symlink_source_target, symlink_source))
local symlink_source_plan = Transfer.plan({ symlink_source }, symlink_source_target, 'copy')
assert(#symlink_source_plan.entries == 1,
  'a symlink source must not be rejected merely because its target contains the destination')
local symlink_source_result = Transfer.execute(symlink_source_plan, 'increment')
assert(symlink_source_result.completed == 1, 'copying a symlink source should complete')
local copied_symlink = symlink_source_target .. '/symlink-source'
local copied_symlink_stat = vim.uv.fs_lstat(copied_symlink)
assert(copied_symlink_stat and copied_symlink_stat.type == 'link',
  'copying a symlink source must preserve the link entry')
assert(vim.uv.fs_readlink(copied_symlink) == symlink_source_target,
  'copying a symlink source must preserve its link target')

local reservation_source = sources .. '/reservation-race.txt'
local reservation_destination = destination .. '/reservation-race.txt'
vim.fn.writefile({ 'reservation source' }, reservation_source)
local reservation_plan = Transfer.plan({ reservation_source }, destination, 'copy')
local reservation_copy = Fs.copy
local concurrent_create_blocked = false
Fs.copy = function(source_path, destination_path)
  local copied = reservation_copy(source_path, destination_path)
  if destination_path:find('%.vv%-explorer%-stage%-', 1, false) then
    local fd, create_error = vim.uv.fs_open(reservation_destination, 'wx', 420)
    if fd then
      vim.uv.fs_close(fd)
    else
      concurrent_create_blocked = tostring(create_error):find('EEXIST', 1, true) ~= nil
    end
  end
  return copied
end
local reservation_result = Transfer.execute(reservation_plan, 'increment')
Fs.copy = reservation_copy
assert(concurrent_create_blocked,
  'an atomic concurrent create must observe the increment destination reservation')
assert(reservation_result.completed == 1, 'reserved increment destination should still publish')
assert(vim.fn.readfile(reservation_destination)[1] == 'reservation source',
  'increment publish must not overwrite a concurrent reservation')

local reservation_backup_source = sources .. '/reservation-backup-race.txt'
local reservation_backup_destination = destination .. '/reservation-backup-race.txt'
vim.fn.writefile({ 'reservation backup source' }, reservation_backup_source)
local reservation_backup_plan = Transfer.plan(
  { reservation_backup_source }, destination, 'copy'
)
local reservation_backup_rename = Fs.rename
local reservation_backup_injected = false
Fs.rename = function(source_path, destination_path)
  local renamed = reservation_backup_rename(source_path, destination_path)
  if not reservation_backup_injected
    and destination_path:find('%.vv%-explorer%-backup%-', 1, false)
  then
    reservation_backup_injected = true
    vim.fn.writefile({ 'created after reservation backup' }, reservation_backup_destination)
  end
  return renamed
end
local reservation_backup_result = Transfer.execute(reservation_backup_plan, 'increment')
Fs.rename = reservation_backup_rename
assert(reservation_backup_result.completed == 0 and #reservation_backup_result.failed == 1,
  'a target created after an increment reservation backup must abort the publish')
assert(vim.fn.readfile(reservation_backup_destination)[1] == 'created after reservation backup',
  'a concurrent target after reservation backup must survive')
assert(vim.fn.glob(destination .. '/.*vv-explorer-backup-*', false, true)[1] == nil,
  'increment publish failure must not leave a hidden backup orphan')
assert(vim.fn.filereadable(reservation_backup_destination .. ' (recovery)') == 0,
  'an empty increment reservation must not leave a visible recovery orphan')

local reservation_cleanup_source = sources .. '/reservation-cleanup-failure.txt'
local reservation_cleanup_destination = destination .. '/reservation-cleanup-failure.txt'
vim.fn.writefile({ 'reservation cleanup source' }, reservation_cleanup_source)
local reservation_cleanup_plan = Transfer.plan(
  { reservation_cleanup_source }, destination, 'copy'
)
local reservation_cleanup_delete = Fs.delete
local reservation_cleanup_failed = false
Fs.delete = function(path)
  if path:find('%.vv%-explorer%-backup%-', 1, false) then
    reservation_cleanup_failed = true
    error('injected reservation backup cleanup failure')
  end
  if reservation_cleanup_failed then error('injected reservation cleanup failure') end
  return reservation_cleanup_delete(path)
end
local reservation_cleanup_result = Transfer.execute(reservation_cleanup_plan, 'increment')
Fs.delete = reservation_cleanup_delete
assert(reservation_cleanup_failed, 'reservation backup cleanup failure must be exercised')
assert(reservation_cleanup_result.completed == 1 and #reservation_cleanup_result.failed == 0,
  'reservation cleanup failure must not roll back a committed copy')
assert(#reservation_cleanup_result.warnings == 1
  and reservation_cleanup_result.warnings[1]:find('increment reservation cleanup', 1, true),
  'reservation cleanup failure must be reported with reservation-specific text')
assert(vim.fn.readfile(reservation_cleanup_destination)[1] == 'reservation cleanup source',
  'reservation cleanup failure must preserve the committed destination')
assert(vim.fn.filereadable(reservation_cleanup_destination .. ' (recovery)') == 0,
  'reservation cleanup failure must not create an empty visible recovery')

-- Exhausting the historical 100-name range must fail only that entry (or find
-- the next name), without aborting earlier completed transfers in the batch.
local exhaustion_first_source = sources .. '/exhaustion-first.txt'
local exhaustion_source = sources .. '/exhaustion.txt'
vim.fn.writefile({ 'first exhaustion source' }, exhaustion_first_source)
vim.fn.writefile({ 'exhaustion source' }, exhaustion_source)
vim.fn.writefile({ 'existing exhaustion destination' }, destination .. '/exhaustion.txt')
for index = 1, 100 do
  local suffix = index == 1 and ' (copy)' or (' (copy %d)'):format(index)
  vim.fn.writefile({ 'occupied ' .. tostring(index) }, destination .. '/exhaustion' .. suffix .. '.txt')
end
local exhaustion_ok, exhaustion_result = pcall(function()
  return Transfer.execute(Transfer.plan(
    { exhaustion_first_source, exhaustion_source }, destination, 'copy'
  ), 'increment')
end)
assert(exhaustion_ok, tostring(exhaustion_result))
assert(exhaustion_result.completed == 2 and #exhaustion_result.failed == 0,
  'more than 100 increment candidates must not abort the transfer batch')
assert(vim.fn.readfile(destination .. '/exhaustion-first.txt')[1] == 'first exhaustion source',
  'the transfer before an exhausted candidate must remain completed')
assert(vim.fn.readfile(destination .. '/exhaustion (copy 101).txt')[1] == 'exhaustion source',
  'increment must continue past the historical 100-name range')

-- A failed stage copy may leave a payload that another actor has taken over.
-- The private temp container must be retained instead of deleting that payload
-- by its guessed pathname.
local stage_race_source = sources .. '/stage-race.txt'
vim.fn.writefile({ 'stage source' }, stage_race_source)
local stage_race_plan = Transfer.plan({ stage_race_source }, destination, 'copy')
local stage_copy = Fs.copy
local stage_payload
Fs.copy = function(source_path, destination_path)
  if destination_path:find('%.vv%-explorer%-stage%-', 1, false) then
    stage_payload = destination_path
    vim.fn.writefile({ 'external stage payload' }, destination_path)
    error('injected stage preemption')
  end
  return stage_copy(source_path, destination_path)
end
local stage_race = Transfer.execute(stage_race_plan, 'increment')
Fs.copy = stage_copy
assert(stage_race.completed == 0 and #stage_race.failed == 1,
  'a preempted stage must fail without reporting a completed copy')
assert(stage_payload and vim.fn.readfile(stage_payload)[1] == 'external stage payload',
  'a preempted stage payload must not be deleted')
assert(vim.fn.isdirectory(vim.fs.dirname(stage_payload)) == 1,
  'a preempted stage must retain its private container')
local stage_container_stat = vim.uv.fs_stat(vim.fs.dirname(stage_payload))
assert(stage_container_stat and stage_container_stat.mode % 4096 == 448,
  'a private stage container must use 0700 permissions')

-- A committed overwrite must not delete a backup payload replaced after the
-- transaction. The identity check must leave the owned container visible.
local backup_replacement_source = sources .. '/backup-replacement.txt'
local backup_replacement_destination = destination .. '/backup-replacement.txt'
vim.fn.writefile({ 'new backup replacement source' }, backup_replacement_source)
vim.fn.writefile({ 'old backup replacement destination' }, backup_replacement_destination)
local backup_replacement_plan = Transfer.plan(
  { backup_replacement_source }, destination, 'copy'
)
local Paths = require('vv-explorer.transfer.paths')
local original_checktime = Paths.checktime_under
local backup_payload
local backup_replacement_injected = false
Paths.checktime_under = function(...)
  local result = original_checktime(...)
  if not backup_replacement_injected then
    local container = vim.fn.glob(
      destination .. '/.backup-replacement.txt.vv-explorer-backup-*', false, true
    )[1]
    backup_payload = container and vim.fs.joinpath(container, 'payload') or nil
    assert(backup_payload and vim.fn.filereadable(backup_payload) == 1,
      'committed backup payload must exist before the cleanup boundary')
    assert(vim.uv.fs_unlink(backup_payload))
    vim.fn.writefile({ 'external backup replacement' }, backup_payload)
    backup_replacement_injected = true
  end
  return result
end
local backup_replacement = Transfer.execute(backup_replacement_plan, 'overwrite')
Paths.checktime_under = original_checktime
assert(backup_replacement.completed == 1,
  'a committed overwrite must remain completed after backup cleanup replacement')
assert(backup_replacement_injected, 'committed backup replacement must exercise cleanup')
assert(backup_payload and vim.fn.readfile(backup_payload)[1] == 'external backup replacement',
  'a committed backup replacement must not be deleted')
assert(vim.fn.isdirectory(vim.fs.dirname(backup_payload)) == 1,
  'a replaced backup must retain its owned container')

-- If deleting an owned backup disposal fails after the replacement commits,
-- restore that payload and move it to a visible recovery path. The private
-- container must not be left behind as an invisible recovery orphan.
local backup_cleanup_failure_source = sources .. '/backup-cleanup-failure.txt'
local backup_cleanup_failure_destination = destination .. '/backup-cleanup-failure.txt'
vim.fn.writefile({ 'new backup cleanup source' }, backup_cleanup_failure_source)
vim.fn.writefile({ 'old backup cleanup destination' }, backup_cleanup_failure_destination)
local backup_cleanup_failure_plan = Transfer.plan(
  { backup_cleanup_failure_source }, destination, 'copy'
)
local backup_cleanup_delete = Fs.delete
local backup_cleanup_delete_injected = false
Fs.delete = function(path)
  if path:find('%.vv%-explorer%-backup%-', 1, false) and path:sub(-8) == '/dispose' then
    backup_cleanup_delete_injected = true
    error('injected committed backup cleanup failure')
  end
  return backup_cleanup_delete(path)
end
local backup_cleanup_ok, backup_cleanup_result = pcall(function()
  return Transfer.execute(backup_cleanup_failure_plan, 'overwrite')
end)
Fs.delete = backup_cleanup_delete
assert(backup_cleanup_ok, tostring(backup_cleanup_result))
assert(backup_cleanup_delete_injected,
  'committed backup cleanup failure must exercise disposal deletion')
assert(backup_cleanup_result.completed == 1 and #backup_cleanup_result.failed == 0,
  'committed backup cleanup failure must not roll back the replacement')
assert(vim.fn.readfile(backup_cleanup_failure_destination)[1] == 'new backup cleanup source',
  'the replacement must remain at the destination after backup cleanup failure')
assert(vim.fn.readfile(backup_cleanup_failure_destination .. ' (recovery)')[1]
  == 'old backup cleanup destination',
  'the old destination must be moved to visible recovery after backup cleanup failure')
assert(vim.fn.glob(
  destination .. '/.backup-cleanup-failure.txt.vv-explorer-backup-*', false, true
)[1] == nil, 'backup cleanup failure must not leave a hidden backup container')

-- A recursive cleanup may remove some descendants before a later descendant
-- rejects removal (for example, a read-only child directory). The remaining
-- owned disposal must still become a visible recovery tree.
local partial_cleanup_source = sources .. '/partial-cleanup-dir'
local partial_cleanup_destination = destination .. '/partial-cleanup-dir'
vim.fn.mkdir(partial_cleanup_source, 'p')
vim.fn.mkdir(partial_cleanup_destination .. '/read-only', 'p')
vim.fn.writefile({ 'new partial cleanup content' }, partial_cleanup_source .. '/new.txt')
vim.fn.writefile({ 'must remain recoverable' }, partial_cleanup_destination .. '/read-only/keep.txt')
vim.fn.writefile({ 'another old file' }, partial_cleanup_destination .. '/other.txt')
assert(vim.uv.fs_chmod(partial_cleanup_destination .. '/read-only', 365))
local partial_cleanup_plan = Transfer.plan({ partial_cleanup_source }, destination, 'copy')
local partial_cleanup_delete = Fs.delete
local partial_cleanup_injected = false
Fs.delete = function(path)
  if not partial_cleanup_injected
    and path:find('%.partial%-cleanup%-dir%.vv%-explorer%-backup%-', 1, false)
    and path:sub(-8) == '/dispose'
  then
    partial_cleanup_injected = true
    partial_cleanup_delete(vim.fs.joinpath(path, 'other.txt'))
    return partial_cleanup_delete(path)
  end
  return partial_cleanup_delete(path)
end
local partial_cleanup_ok, partial_cleanup_result = pcall(function()
  return Transfer.execute(partial_cleanup_plan, 'overwrite')
end)
Fs.delete = partial_cleanup_delete
assert(partial_cleanup_ok, tostring(partial_cleanup_result))
assert(partial_cleanup_injected, 'partial disposal cleanup must be exercised')
assert(partial_cleanup_result.completed == 1 and #partial_cleanup_result.failed == 0,
  'partial backup cleanup must not roll back a committed copy')
assert(vim.fn.readfile(partial_cleanup_destination .. '/new.txt')[1]
  == 'new partial cleanup content', 'the replacement must remain at the destination')
assert(vim.fn.readfile(partial_cleanup_destination .. ' (recovery)/read-only/keep.txt')[1]
  == 'must remain recoverable', 'remaining disposal content must be visible in recovery')
assert(vim.uv.fs_lstat(partial_cleanup_destination .. ' (recovery)/other.txt') == nil,
  'a descendant already removed before cleanup failure must stay removed')
assert(vim.uv.fs_chmod(
  partial_cleanup_destination .. ' (recovery)/read-only', 493
))
assert(vim.fn.glob(
  destination .. '/.partial-cleanup-dir.vv-explorer-backup-*', false, true
)[1] == nil, 'partial cleanup recovery must not leave a hidden backup container')

-- If a failed transaction cannot restore its backup because the destination
-- directory becomes unwritable, retaining the payload is safer than cleaning
-- the only copy of the old destination.
if vim.fn.has('unix') == 1 then
  local failed_backup_source = sources .. '/failed-backup.txt'
  local failed_backup_destination = destination .. '/failed-backup.txt'
  vim.fn.writefile({ 'new failed backup content' }, failed_backup_source)
  vim.fn.writefile({ 'unique old failed backup content' }, failed_backup_destination)
  local failed_backup_plan = Transfer.plan({ failed_backup_source }, destination, 'copy')
  local failed_backup_rename = Fs.rename
  local failed_backup_locked = false
  Fs.rename = function(source_path, destination_path)
    local renamed = failed_backup_rename(source_path, destination_path)
    if not failed_backup_locked
      and destination_path:find('%.failed%-backup%.txt%.vv%-explorer%-backup%-', 1, false)
    then
      failed_backup_locked = true
      assert(vim.uv.fs_chmod(destination, 320))
    end
    return renamed
  end
  local failed_backup_ok, failed_backup_result = pcall(function()
    return Transfer.execute(failed_backup_plan, 'overwrite')
  end)
  Fs.rename = failed_backup_rename
  assert(vim.uv.fs_chmod(destination, 493))
  assert(failed_backup_ok, tostring(failed_backup_result))
  assert(failed_backup_locked, 'failed transaction backup protection must be exercised')
  assert(failed_backup_result.completed == 0 and #failed_backup_result.failed == 1,
    'failed backup restoration must remain a failed transfer')
  local failed_backup_container = vim.fn.glob(
    destination .. '/.failed-backup.txt.vv-explorer-backup-*', false, true
  )[1]
  assert(failed_backup_container and vim.fn.readfile(
    vim.fs.joinpath(failed_backup_container, 'payload')
  )[1] == 'unique old failed backup content',
    'failed transaction must retain the only old destination payload')
  assert(vim.fn.filereadable(failed_backup_destination) == 0,
    'failed transaction must not publish a partial replacement')
end

local race_source = sources .. '/race.txt'
local race_destination = destination .. '/race.txt'
vim.fn.writefile({ 'planned source' }, race_source)
vim.fn.writefile({ 'planned destination' }, race_destination)
local race_plan = Transfer.plan({ race_source }, destination, 'copy')
local original_copy = Fs.copy
Fs.copy = function(source_path, destination_path)
  original_copy(source_path, destination_path)
  vim.fn.writefile({ 'concurrent destination update that must survive' }, race_destination)
end
local race = Transfer.execute(race_plan, 'overwrite')
Fs.copy = original_copy
assert(race.completed == 0 and #race.failed == 1,
  'destination changes during staging must abort the replacement')
assert(vim.fn.readfile(race_destination)[1] == 'concurrent destination update that must survive',
  'transaction rollback must restore the destination changed during staging')

local backup_race_source = sources .. '/backup-race.txt'
local backup_race_destination = destination .. '/backup-race.txt'
vim.fn.writefile({ 'backup source' }, backup_race_source)
vim.fn.writefile({ 'backup destination' }, backup_race_destination)
local backup_race_plan = Transfer.plan({ backup_race_source }, destination, 'copy')
local original_rename = Fs.rename
local injected_destination = false
Fs.rename = function(source_path, destination_path)
  local result = original_rename(source_path, destination_path)
  if not injected_destination and destination_path:find('%.vv%-explorer%-backup%-', 1, false) then
    injected_destination = true
    vim.fn.writefile({ 'created after backup' }, backup_race_destination)
  end
  return result
end
local backup_race = Transfer.execute(backup_race_plan, 'overwrite')
Fs.rename = original_rename
assert(backup_race.completed == 0 and #backup_race.failed == 1,
  'a target created after backup must abort without reporting success')
assert(vim.fn.readfile(backup_race_destination)[1] == 'created after backup',
  'a target created after backup must survive rollback')
local recovery_path = backup_race_destination .. ' (recovery)'
assert(vim.fn.readfile(recovery_path)[1] == 'backup destination',
  'the replaced destination must be moved to an explicit recovery path')
assert(vim.fn.glob(destination .. '/.backup-race.txt.vv-explorer-backup-*', false, true)[1] == nil,
  'failed overwrite must not leave an orphaned hidden backup')

local cut_source = sources .. '/move-me'
assert(vim.fn.mkdir(cut_source, 'p') == 1)
vim.fn.writefile({ 'moved' }, cut_source .. '/new.txt')
assert(vim.fn.mkdir(destination .. '/move-me', 'p') == 1)
vim.fn.writefile({ 'old' }, destination .. '/move-me/old.txt')
local cut = Transfer.execute(Transfer.plan({ cut_source }, destination, 'cut'), 'overwrite')
assert(cut.completed == 1, 'cut overwrite should complete')
assert(vim.fn.isdirectory(cut_source) == 0, 'cut overwrite must remove the source')
assert(vim.fn.filereadable(destination .. '/move-me/new.txt') == 1, 'cut overwrite must install source')
assert(vim.fn.filereadable(destination .. '/move-me/old.txt') == 0, 'cut overwrite must replace destination')

local shared_memory = '/dev/shm'
local source_device = vim.uv.fs_stat(temporary)
local shared_device = vim.uv.fs_stat(shared_memory)
if source_device and shared_device and source_device.dev ~= shared_device.dev then
  local cross_destination = ('%s/vv-explorer-transfer-%s-%s'):format(
    shared_memory,
    vim.uv.os_getpid(),
    vim.uv.hrtime()
  )
  local cross_source = sources .. '/cross-device'
  assert(vim.fn.mkdir(cross_source, 'p') == 1)
  assert(vim.fn.mkdir(cross_destination .. '/cross-device', 'p') == 1)
  vim.fn.writefile({ 'new cross-device content' }, cross_source .. '/new.txt')
  vim.fn.writefile({ 'old cross-device content' }, cross_destination .. '/cross-device/old.txt')

  local cross_cut = Transfer.execute(Transfer.plan({ cross_source }, cross_destination, 'cut'), 'overwrite')
  assert(cross_cut.completed == 1, 'cross-device cut overwrite should complete')
  assert(vim.fn.isdirectory(cross_source) == 0, 'cross-device cut must remove the source after publishing')
  assert(vim.fn.filereadable(cross_destination .. '/cross-device/new.txt') == 1,
    'cross-device cut must publish the complete source')
  assert(vim.fn.filereadable(cross_destination .. '/cross-device/old.txt') == 0,
    'cross-device cut overwrite must replace the complete destination')

  local cross_race_source = sources .. '/cross-device-race'
  local cross_race_destination = cross_destination .. '/cross-device-race'
  assert(vim.fn.mkdir(cross_race_source, 'p') == 1)
  vim.fn.writefile({ 'original cross-device content' }, cross_race_source .. '/payload.txt')

  local original_delete = Fs.delete
  local injected_source_replacement = false
  Fs.delete = function(path)
    if not injected_source_replacement then
      injected_source_replacement = true
      vim.fn.writefile({ 'concurrent replacement must survive' }, cross_race_source)
    end
    return original_delete(path)
  end
  local cross_race_ok, cross_race = pcall(function()
    return Transfer.execute(Transfer.plan({ cross_race_source }, cross_destination, 'cut'), 'overwrite')
  end)
  Fs.delete = original_delete

  assert(cross_race_ok, 'cross-device cleanup race must not escape the transfer result')
  assert(injected_source_replacement, 'cross-device cleanup race must exercise the delete boundary')
  assert(cross_race.completed == 1, 'cross-device cut must complete after isolating the source')
  assert(vim.fn.readfile(cross_race_destination .. '/payload.txt')[1] == 'original cross-device content',
    'cross-device cut must copy from the isolated source snapshot')
  assert(vim.fn.readfile(cross_race_source)[1] == 'concurrent replacement must survive',
    'a source-path replacement during cleanup must not be silently deleted')

  local cross_failure_source = sources .. '/cross-device-copy-failure'
  local cross_failure_destination = cross_destination .. '/cross-device-copy-failure'
  assert(vim.fn.mkdir(cross_failure_source, 'p') == 1)
  vim.fn.writefile({ 'must be restored after copy failure' }, cross_failure_source .. '/payload.txt')
  local original_copy = Fs.copy
  Fs.copy = function(source_path, destination_path)
    if destination_path:find('%.vv%-explorer%-stage%-', 1, false) then
      error('injected cross-device copy failure')
    end
    return original_copy(source_path, destination_path)
  end
  local cross_failure_ok, cross_failure = pcall(function()
    return Transfer.execute(Transfer.plan({ cross_failure_source }, cross_destination, 'cut'), 'overwrite')
  end)
  Fs.copy = original_copy

  assert(cross_failure_ok, 'cross-device copy failure must be returned in the transfer result')
  assert(cross_failure.completed == 0 and #cross_failure.failed == 1,
    'cross-device copy failure must not report a completed cut')
  assert(vim.fn.readfile(cross_failure_source .. '/payload.txt')[1] == 'must be restored after copy failure',
    'failed cross-device copy must restore the original source path')
  assert(vim.fn.isdirectory(cross_failure_destination) == 0,
    'failed cross-device copy must not publish a destination')
  assert(vim.fn.glob(sources .. '/.cross-device-copy-failure.vv-explorer-source-*', false, true)[1] == nil,
    'failed cross-device copy must not leave an isolated source staging path')

  local cleanup_restore_source = sources .. '/cross-device-cleanup-restore'
  local cleanup_restore_destination = cross_destination .. '/cross-device-cleanup-restore'
  assert(vim.fn.mkdir(cleanup_restore_source, 'p') == 1)
  vim.fn.writefile({ 'must survive cleanup failure' }, cleanup_restore_source .. '/payload.txt')
  local cleanup_delete = Fs.delete
  Fs.delete = function(path)
    error('injected source cleanup failure')
  end
  local cleanup_restore_ok, cleanup_restore = pcall(function()
    return Transfer.execute(Transfer.plan({ cleanup_restore_source }, cross_destination, 'cut'), 'overwrite')
  end)
  Fs.delete = cleanup_delete

  assert(cleanup_restore_ok, 'cleanup failure must be returned in the transfer result')
  assert(cleanup_restore.completed == 0 and #cleanup_restore.failed == 1,
    'cleanup failure must not report a completed cut')
  assert(vim.fn.readfile(cleanup_restore_source .. '/payload.txt')[1] == 'must survive cleanup failure',
    'cleanup failure with an empty source path must restore the original source')
  assert(vim.fn.isdirectory(cleanup_restore_source .. ' (recovery)') == 0,
    'cleanup failure with an empty source path must not create recovery unnecessarily')
  assert(vim.fn.filereadable(cleanup_restore_destination .. '/payload.txt') == 1,
    'a successful cross-device copy remains available when source cleanup fails')

  local cleanup_recovery_source = sources .. '/cross-device-cleanup-recovery'
  local cleanup_recovery_destination = cross_destination .. '/cross-device-cleanup-recovery'
  assert(vim.fn.mkdir(cleanup_recovery_source, 'p') == 1)
  vim.fn.writefile({ 'must be preserved in recovery' }, cleanup_recovery_source .. '/payload.txt')
  local replacement_delete = Fs.delete
  local replacement_created = false
  Fs.delete = function()
    if not replacement_created then
      replacement_created = true
      vim.fn.writefile({ 'concurrent source replacement' }, cleanup_recovery_source)
      error('injected cleanup failure after source replacement')
    end
    return replacement_delete(path)
  end
  local cleanup_recovery_ok, cleanup_recovery = pcall(function()
    return Transfer.execute(Transfer.plan({ cleanup_recovery_source }, cross_destination, 'cut'), 'overwrite')
  end)
  Fs.delete = replacement_delete

  assert(cleanup_recovery_ok, 'cleanup failure with a replacement must be returned in the transfer result')
  assert(cleanup_recovery.completed == 0 and #cleanup_recovery.failed == 1,
    'cleanup failure with a replacement must not report a completed cut')
  assert(vim.fn.readfile(cleanup_recovery_source)[1] == 'concurrent source replacement',
    'a concurrent source replacement must remain at the original path')
  assert(vim.fn.readfile(cleanup_recovery_source .. ' (recovery)/payload.txt')[1]
    == 'must be preserved in recovery',
    'the isolated source must move to visible recovery when the source path is occupied')
  assert(vim.fn.isdirectory(cleanup_recovery_destination) == 1,
    'the copied destination remains available after source cleanup recovery')

  local partial_source_cleanup = sources .. '/cross-device-partial-cleanup'
  local partial_source_cleanup_destination = cross_destination .. '/cross-device-partial-cleanup'
  assert(vim.fn.mkdir(partial_source_cleanup .. '/read-only', 'p') == 1)
  vim.fn.writefile({ 'must remain in source recovery' }, partial_source_cleanup .. '/read-only/keep.txt')
  vim.fn.writefile({ 'removed before cleanup failed' }, partial_source_cleanup .. '/other.txt')
  assert(vim.uv.fs_chmod(partial_source_cleanup .. '/read-only', 365))
  local partial_source_cleanup_delete = Fs.delete
  local partial_source_cleanup_injected = false
  Fs.delete = function(path)
    if not partial_source_cleanup_injected
      and path:find('cross%-device%-partial%-cleanup%.vv%-explorer%-source%-', 1, false)
      and path:sub(-8) == '/dispose'
    then
      partial_source_cleanup_injected = true
      partial_source_cleanup_delete(vim.fs.joinpath(path, 'other.txt'))
      return partial_source_cleanup_delete(path)
    end
    return partial_source_cleanup_delete(path)
  end
  local partial_source_cleanup_ok, partial_source_cleanup_result = pcall(function()
    return Transfer.execute(Transfer.plan(
      { partial_source_cleanup }, cross_destination, 'cut'
    ), 'overwrite')
  end)
  Fs.delete = partial_source_cleanup_delete
  assert(partial_source_cleanup_ok, tostring(partial_source_cleanup_result))
  assert(partial_source_cleanup_injected, 'partial source disposal cleanup must be exercised')
  assert(partial_source_cleanup_result.completed == 0 and #partial_source_cleanup_result.failed == 1,
    'partial source cleanup must keep the cut marked as failed')
  assert(vim.fn.readfile(
    partial_source_cleanup .. ' (recovery)/read-only/keep.txt'
  )[1] == 'must remain in source recovery',
    'remaining source content must be visible in recovery')
  assert(vim.fn.isdirectory(partial_source_cleanup) == 0,
    'the original source path must stay absent after source recovery')
  assert(vim.uv.fs_lstat(partial_source_cleanup .. ' (recovery)/other.txt') == nil,
    'a source descendant removed before cleanup failure must stay removed')
  assert(vim.fn.isdirectory(partial_source_cleanup_destination) == 1,
    'the copied destination must remain available after source recovery')
  assert(vim.uv.fs_chmod(
    partial_source_cleanup .. ' (recovery)/read-only', 493
  ))
  vim.fn.delete(cross_destination, 'rf')
end

vim.fn.delete(temporary, 'rf')
print('vv-explorer transfer: PASS')

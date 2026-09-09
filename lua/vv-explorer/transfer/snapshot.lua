-- 文件传输的递归文件系统快照与一致性比较

local uv = vim.uv or vim.loop

local function stat_snapshot(stat, path)
  local mtime = stat.mtime or {}
  local ctime = stat.ctime or {}
  local entry = {
    dev = stat.dev,
    ino = stat.ino,
    type = stat.type,
    mode = stat.mode,
    size = stat.size,
    mtime_sec = mtime.sec,
    mtime_nsec = mtime.nsec,
    ctime_sec = ctime.sec,
    ctime_nsec = ctime.nsec,
  }
  if stat.type == 'link' then
    local target, error_message = uv.fs_readlink(path)
    if not target then
      return nil, 'readlink failed for ' .. path .. ': ' .. tostring(error_message)
    end
    entry.link_target = target
  end
  return entry
end

-- Directory replacement must validate descendants as well as the root entry:
-- changing a child file does not necessarily change the parent directory mtime.
-- This is a synchronous O(number of descendants) manifest, intentionally used
-- at paste planning/execution boundaries rather than on cursor-movement paths.
local function snapshot(path)
  local stat = uv.fs_lstat(path)
  if not stat then return { exists = false } end
  local result = {
    exists = true,
    entries = {},
  }

  local function visit(current, relative)
    local current_stat = uv.fs_lstat(current)
    if not current_stat then
      result.error = 'filesystem entry disappeared while snapshotting ' .. current
      return false
    end
    local entry, entry_error = stat_snapshot(current_stat, current)
    if not entry then
      result.error = entry_error
      return false
    end
    result.entries[relative] = entry
    if current_stat.type ~= 'directory' then return true end

    local scan, scan_error = uv.fs_scandir(current)
    if not scan then
      result.error = 'directory scan failed for ' .. current .. ': ' .. tostring(scan_error)
      return false
    end

    while true do
      local name = uv.fs_scandir_next(scan)
      if not name then break end
      local child = vim.fs.joinpath(current, name)
      local child_relative = relative == '' and name or vim.fs.joinpath(relative, name)
      if not visit(child, child_relative) then return false end
    end
    return true
  end

  visit(path, '')
  return result
end

local function same_snapshot(first, second, opts)
  opts = opts or {}
  if first.error or second.error then return false end
  if first.exists ~= second.exists then return false end
  if not first.exists then return true end

  for relative, first_entry in pairs(first.entries) do
    local second_entry = second.entries[relative]
    if not second_entry then return false end
    for key, value in pairs(first_entry) do
      local ignored_ctime = opts.ignore_ctime
        and (key == 'ctime_sec' or key == 'ctime_nsec')
      if not ignored_ctime and second_entry[key] ~= value then return false end
    end
    for key, value in pairs(second_entry) do
      local ignored_ctime = opts.ignore_ctime
        and (key == 'ctime_sec' or key == 'ctime_nsec')
      if not ignored_ctime and first_entry[key] ~= value then return false end
    end
  end
  for relative in pairs(second.entries) do
    if not first.entries[relative] then return false end
  end
  return true
end

return {
  snapshot = snapshot,
  same = same_snapshot,
}

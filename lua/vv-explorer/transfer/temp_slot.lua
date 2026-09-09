-- 文件传输的独占临时容器

local Fs = require('vv-utils.fs')
local Snapshot = require('vv-explorer.transfer.snapshot')

local uv = vim.uv or vim.loop

local M = {}
local Slot = {}
Slot.__index = Slot

local DIRECTORY_MODE = 448 -- 0700
local PAYLOAD_NAME = 'payload'
local DISPOSAL_NAME = 'dispose'

local function same_identity(first, second)
  if not first or not second or first.type ~= second.type then return false end
  if first.dev ~= nil and first.ino ~= nil
      and second.dev ~= nil and second.ino ~= nil
  then
    return first.dev == second.dev and first.ino == second.ino
  end
  return first.mode == second.mode
    and first.size == second.size
    and first.mtime.sec == second.mtime.sec
    and (first.mtime.nsec or 0) == (second.mtime.nsec or 0)
    and first.ctime.sec == second.ctime.sec
    and (first.ctime.nsec or 0) == (second.ctime.nsec or 0)
end

local function list_entries(path)
  local scan, scan_error = uv.fs_scandir(path)
  if not scan then return nil, scan_error end

  local entries = {}
  while true do
    local name = uv.fs_scandir_next(scan)
    if not name then break end
    entries[#entries + 1] = name
  end
  return entries
end

local function empty_directory(path)
  local entries, scan_error = list_entries(path)
  if not entries then return false, tostring(scan_error) end
  if #entries > 0 then
    return false, 'owned temp container is not empty: ' .. path
  end
  local removed, remove_error = uv.fs_rmdir(path)
  if removed then return true end
  return false, tostring(remove_error)
end

local function preserve_message(slot, message)
  return tostring(message) .. '; preserved at ' .. slot.container
end

---@param path string
---@param kind string
---@return table
function M.create(path, kind)
  path = vim.fs.normalize(path)
  local parent = vim.fs.dirname(path)
  local basename = vim.fs.basename(path)
  Fs.mkdir_p(parent)

  local template = vim.fs.joinpath(parent, ('.%s.vv-explorer-%s-XXXXXX'):format(basename, kind))
  local container, create_error = uv.fs_mkdtemp(template)
  if not container then
    error('unable to create private temp container beside ' .. path .. ': ' .. tostring(create_error))
  end

  local chmod_ok, chmod_error = uv.fs_chmod(container, DIRECTORY_MODE)
  if not chmod_ok then
    pcall(uv.fs_rmdir, container)
    error('unable to protect private temp container ' .. container .. ': ' .. tostring(chmod_error))
  end

  local identity = uv.fs_lstat(container)
  if not identity then
    pcall(uv.fs_rmdir, container)
    error('private temp container disappeared: ' .. container)
  end

  return setmetatable({
    container = container,
    payload = vim.fs.joinpath(container, PAYLOAD_NAME),
    disposal = vim.fs.joinpath(container, DISPOSAL_NAME),
    identity = identity,
    expected = nil,
  }, Slot)
end

---@param snapshot table
function Slot:set_expected(snapshot)
  self.expected = snapshot
end

---@return boolean, string?, table?
function Slot:validate()
  local container = uv.fs_lstat(self.container)
  if not same_identity(self.identity, container) then
    return false, 'owned temp container changed: ' .. self.container
  end

  local actual = Snapshot.snapshot(self.payload)
  if actual.error then return false, actual.error end
  if not self.expected then
    if actual.exists then
      return false, preserve_message(self, 'owned temp payload has no identity snapshot')
    end
    return true, nil, actual
  end
  if not Snapshot.same(self.expected, actual, { ignore_ctime = true }) then
    return false, preserve_message(self, 'owned temp payload changed')
  end
  return true, nil, actual
end

---@return boolean, string?
function Slot:release_empty()
  local container = uv.fs_lstat(self.container)
  if not same_identity(self.identity, container) then
    return false, 'owned temp container changed: ' .. self.container
  end

  local removed, remove_error = empty_directory(self.container)
  if not removed then return false, preserve_message(self, remove_error) end
  self.closed = true
  return true
end

---@return boolean, string?
function Slot:cleanup()
  if self.closed then return true end

  if not uv.fs_lstat(self.payload) then return self:release_empty() end

  local valid, validation_error = self:validate()
  if not valid then return false, validation_error end

  if not self.expected then
    return false, preserve_message(self, 'owned temp payload has no identity snapshot')
  end

  local move_call_ok, moved, move_error = pcall(uv.fs_rename, self.payload, self.disposal)
  if not move_call_ok or not moved then
    return false, preserve_message(self, move_error or moved)
  end

  local disposed_snapshot = Snapshot.snapshot(self.disposal)
  if disposed_snapshot.error
    or not Snapshot.same(self.expected, disposed_snapshot, { ignore_ctime = true })
  then
    return false, preserve_message(self, disposed_snapshot.error or 'owned temp payload changed')
  end
  self.disposal_identity = vim.deepcopy(uv.fs_lstat(self.disposal))

  local removed, remove_error = pcall(Fs.delete, self.disposal)
  if not removed then return false, preserve_message(self, remove_error) end
  if uv.fs_lstat(self.disposal) then
    return false, preserve_message(self, 'owned temp payload was not removed')
  end
  if uv.fs_lstat(self.payload) then
    return false, preserve_message(self, 'temp payload was replaced during cleanup')
  end

  return self:release_empty()
end

-- 删除 disposal 失败后，只在 disposal 根仍是本次移动出的对象时保留其余内容
-- 不重新要求完整快照相等：删除失败本身可能已经移除了部分子项，但根身份校验仍拒绝外部替换
---@param destination string
---@return boolean, string?
function Slot:move_disposal(destination)
  local container = uv.fs_lstat(self.container)
  if not same_identity(self.identity, container) then
    return false, 'owned temp container changed: ' .. self.container
  end

  local disposal = uv.fs_lstat(self.disposal)
  if not disposal then return false, preserve_message(self, 'owned temp disposal is missing') end
  if not self.disposal_identity or not same_identity(self.disposal_identity, disposal) then
    return false, preserve_message(self, 'owned temp disposal changed')
  end
  if uv.fs_lstat(destination) then
    return false, 'destination already exists: ' .. destination
  end

  local moved, move_error = pcall(Fs.rename, self.disposal, destination)
  if not moved then return false, tostring(move_error) end
  local released, release_error = self:release_empty()
  if not released then
    return true, 'private temp container cleanup failed: ' .. tostring(release_error)
  end
  return true
end

-- 清理尝试将 payload 移到 disposal 后，恢复可继续处理的 payload
-- 调用方不应根据 slot 路径自行推断所有权；此方法会在恢复前校验容器与 payload 身份
---@return boolean, string?
function Slot:make_payload_available()
  local container = uv.fs_lstat(self.container)
  if not same_identity(self.identity, container) then
    return false, 'owned temp container changed: ' .. self.container
  end

  if uv.fs_lstat(self.payload) then
    local valid, validation_error = self:validate()
    if not valid then return false, validation_error end
    return true
  end
  if not uv.fs_lstat(self.disposal) then
    return false, preserve_message(self, 'owned temp payload is missing')
  end

  local disposed_snapshot = Snapshot.snapshot(self.disposal)
  if disposed_snapshot.error
    or not self.expected
    or not Snapshot.same(self.expected, disposed_snapshot, { ignore_ctime = true })
  then
    return false, preserve_message(self, disposed_snapshot.error or 'owned temp disposal changed')
  end

  local restore_call_ok, restored, restore_error = pcall(
    uv.fs_rename, self.disposal, self.payload
  )
  if not restore_call_ok or not restored then
    return false, preserve_message(self, restore_error or restored)
  end
  local valid, validation_error = self:validate()
  if not valid then return false, validation_error end
  return true
end

---@param destination string
---@return boolean, string?
function Slot:move_payload(destination)
  local valid, validation_error = self:make_payload_available()
  if not valid then
    local moved, move_error = self:move_disposal(destination)
    if moved then return moved, move_error end
    return false, validation_error or move_error
  end

  if not uv.fs_lstat(self.payload) then
    return false, preserve_message(self, 'owned temp payload is missing')
  end

  if uv.fs_lstat(destination) then
    return false, 'destination already exists: ' .. destination
  end

  local moved, move_error = pcall(Fs.rename, self.payload, destination)
  if not moved then return false, tostring(move_error) end
  local released, release_error = self:release_empty()
  if not released then
    return true, 'private temp container cleanup failed: ' .. tostring(release_error)
  end
  return true
end

return M

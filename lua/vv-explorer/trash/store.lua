-- 回收站存储与可恢复的文件系统操作

local Fs = require('vv-utils.fs')

local uv = vim.uv or vim.loop

---@class VVExplorerTrashEntry
---@field trash_name string
---@field trash_path string
---@field meta_path string
---@field original_path string
---@field trashed_at integer
---@field size_bytes integer
---@field basename string

---@class VVExplorerTrashStore
---@field private config VVExplorerTrashConfig
---@field private trash_dir string
local Store = {}
Store.__index = Store

local function xdg_data()
  return vim.env.XDG_DATA_HOME or (vim.env.HOME .. '/.local/share')
end

local function dir_size_sync(path)
  local total = 0
  local handle = uv.fs_scandir(path)
  if not handle then return 0 end
  while true do
    local name, entry_type = uv.fs_scandir_next(handle)
    if not name then break end
    local full_path = path .. '/' .. name
    if entry_type == 'directory' then
      total = total + dir_size_sync(full_path)
    else
      local stat = uv.fs_stat(full_path)
      if stat then total = total + stat.size end
    end
  end
  return total
end

local function entry_size(path)
  local stat = uv.fs_stat(path)
  if not stat then return 0 end
  if stat.type == 'directory' then return dir_size_sync(path) end
  return stat.size
end

---@param opts VVExplorerTrashConfig
---@param trash_dir? string
---@return VVExplorerTrashStore
function Store.new(opts, trash_dir)
  local self = setmetatable({
    config = opts,
    trash_dir = trash_dir or (xdg_data() .. '/vv-explorer/trash'),
  }, Store)

  if opts.enabled then Fs.mkdir_p(self.trash_dir) end
  return self
end

function Store:enabled()
  return self.config.enabled
end

function Store:enforce_max_items()
  if not self.config.max_items then return end
  local entries = self:list()
  if #entries <= self.config.max_items then return end
  for index = self.config.max_items + 1, #entries do
    pcall(Fs.delete, entries[index].trash_path)
    pcall(Fs.delete, entries[index].meta_path)
  end
end

---@param paths string[]
---@return {trashed:string[], failed:string[]}
function Store:trash(paths)
  local trashed = {}
  local failed = {}
  for _, path in ipairs(paths) do
    local timestamp = string.format('%010d', os.time())
    local basename = vim.fs.basename(path)
    local trash_name = timestamp .. '_' .. basename
    local destination = self.trash_dir .. '/' .. trash_name

    local counter = 0
    while Fs.exists(destination) or Fs.exists(destination .. '.meta.json') do
      counter = counter + 1
      trash_name = timestamp .. '_' .. counter .. '_' .. basename
      destination = self.trash_dir .. '/' .. trash_name
    end

    local size = entry_size(path)
    local ok, error_message = pcall(Fs.rename, path, destination)
    if not ok then
      failed[#failed + 1] = tostring(error_message)
    else
      local metadata = vim.json.encode({
        original_path = path,
        trashed_at = os.time(),
        size_bytes = size,
      })
      pcall(Fs.write_all, destination .. '.meta.json', metadata)
      trashed[#trashed + 1] = path
    end
  end

  if #trashed > 0 then
    vim.schedule(function() self:enforce_max_items() end)
  end
  return { trashed = trashed, failed = failed }
end

---@return VVExplorerTrashEntry[]
function Store:list()
  local handle = uv.fs_scandir(self.trash_dir)
  if not handle then return {} end

  local entries = {}
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then break end
    if name:sub(-10) == '.meta.json' then goto continue end

    local trash_path = self.trash_dir .. '/' .. name
    local meta_path = trash_path .. '.meta.json'
    local metadata = {}
    local read_ok, raw = pcall(Fs.read_all, meta_path)
    if read_ok and raw and raw ~= '' then
      local decode_ok, parsed = pcall(vim.json.decode, raw)
      if decode_ok then metadata = parsed end
    end

    entries[#entries + 1] = {
      trash_name = name,
      trash_path = trash_path,
      meta_path = meta_path,
      original_path = metadata.original_path or '(unknown)',
      trashed_at = metadata.trashed_at or 0,
      size_bytes = metadata.size_bytes or 0,
      basename = metadata.original_path and vim.fs.basename(metadata.original_path) or name,
    }
    ::continue::
  end

  table.sort(entries, function(first, second)
    return first.trashed_at > second.trashed_at
  end)
  return entries
end

---@param entry VVExplorerTrashEntry
---@return string
function Store:restore(entry)
  local destination = entry.original_path
  if
    not destination
    or destination == '(unknown)'
    or not vim.startswith(vim.fs.normalize(destination), '/')
  then
    error('cannot restore: original path unknown (orphan trash entry, missing meta)')
  end

  Fs.mkdir_p(vim.fs.dirname(destination))
  if Fs.exists(destination) then destination = Fs.unique_dest(destination) end
  Fs.rename(entry.trash_path, destination)
  pcall(Fs.delete, entry.meta_path)
  return destination
end

---@param entry VVExplorerTrashEntry
function Store:delete_entry(entry)
  Fs.delete(entry.trash_path)
  pcall(Fs.delete, entry.meta_path)
end

function Store:empty()
  for _, entry in ipairs(self:list()) do
    pcall(Fs.delete, entry.trash_path)
    pcall(Fs.delete, entry.meta_path)
  end
end

--- 走 vv-utils.fs 的分片扫描而不是外部 `du`：BSD / macOS 的 du 没有 `-b` 命令
---@param callback fun(bytes:integer)
---@return VVFsDirScanHandle
function Store:scan_size(callback)
  return Fs.scan_dir(self.trash_dir, {
    on_done = function(result) callback(result.bytes) end,
  })
end

return Store

-- 回收站存储与可恢复的文件系统操作
--
-- 目录的大小不在移入时同步统计（递归 stat 与 inode 数成正比，大目录会冻结界面）：
-- 先 rename 并写不含 size_bytes 的 meta，再用 DirScan 分片扫描回收站里的副本，
-- 完成后仅在条目仍在、meta 仍属于本次移入时补写；恢复 / 删除 / 清空时取消扫描
-- 扫描中途退出 Neovim 的条目没有大小，由 ensure_sizes（面板打开时调用）补跑；
-- 补写成功后通知 on_size 订阅者，面板据此原地更新大小列

local Fs = require('vv-utils.fs')
local DirScan = require('vv-utils.fs.dir_scan')

local uv = vim.uv or vim.loop

---@class VVExplorerTrashEntry
---@field trash_name string
---@field trash_path string
---@field meta_path string
---@field original_path string
---@field trashed_at integer
---@field size_bytes integer? nil 表示目录大小仍在统计，或统计未完成就退出了
---@field basename string

---@class VVExplorerTrashStore
---@field private config VVExplorerTrashConfig
---@field private trash_dir string
---@field private size_scans table<string, VVFsDirScanHandle> trash_path → 未完成的目录大小扫描
---@field private size_listeners table<table, fun(trash_path: string, bytes: integer)>
local Store = {}
Store.__index = Store

local function xdg_data()
  return vim.env.XDG_DATA_HOME or (vim.env.HOME .. '/.local/share')
end

---@param opts VVExplorerTrashConfig
---@param trash_dir? string
---@return VVExplorerTrashStore
function Store.new(opts, trash_dir)
  local self = setmetatable({
    config = opts,
    trash_dir = trash_dir or (xdg_data() .. '/vv-explorer/trash'),
    size_scans = {},
    size_listeners = {},
  }, Store)

  if opts.enabled then Fs.mkdir_p(self.trash_dir) end
  return self
end

function Store:enabled()
  return self.config.enabled
end

---@param trash_path string
---@private
function Store:cancel_size_scan(trash_path)
  local scan = self.size_scans[trash_path]
  if not scan then return end
  self.size_scans[trash_path] = nil
  scan.cancel()
end

--- 只在 payload 仍在、meta 仍是本次移入写下的那份时补写大小：
--- 条目可能已被恢复 / 删除，同名路径也可能已被后来的移入复用
---@param destination string
---@param metadata {original_path:string, trashed_at:integer}
---@param bytes integer
---@return boolean written
---@private
function Store:write_size(destination, metadata, bytes)
  if not uv.fs_lstat(destination) then return false end

  local meta_path = destination .. '.meta.json'
  local read_ok, raw = pcall(Fs.read_all, meta_path)
  if not read_ok or not raw or raw == '' then return false end
  local decode_ok, current = pcall(vim.json.decode, raw)
  if not decode_ok or type(current) ~= 'table' then return false end
  if current.original_path ~= metadata.original_path or current.trashed_at ~= metadata.trashed_at then return false end

  current.size_bytes = bytes
  return (pcall(Fs.write_all, meta_path, vim.json.encode(current)))
end

--- 订阅「某条目的目录大小已补写」事件
---@param fn fun(trash_path: string, bytes: integer)
---@return fun() unsubscribe 幂等
function Store:on_size(fn)
  local key = {}
  self.size_listeners[key] = fn
  return function() self.size_listeners[key] = nil end
end

---@param trash_path string
---@param bytes integer
---@private
function Store:emit_size(trash_path, bytes)
  -- 回调里可能退订，先取快照
  for _, fn in ipairs(vim.tbl_values(self.size_listeners)) do pcall(fn, trash_path, bytes) end
end

---@param destination string
---@param metadata {original_path:string, trashed_at:integer}
---@private
function Store:scan_entry_size(destination, metadata)
  self:cancel_size_scan(destination)

  local scan
  -- on_done 一定在 scan 返回后才触发（DirScan 首片走 timer），此时 scan 已赋值
  scan = DirScan.scan(destination, {
    -- 单个条目要的是准确大小，不按默认 entry 上限截断；分片执行，总量只影响补写的早晚
    max_entries = math.huge,
    on_done = function(result)
      if self.size_scans[destination] == scan then self.size_scans[destination] = nil end
      if result.exists and self:write_size(destination, metadata, result.bytes) then
        self:emit_size(destination, result.bytes)
      end
    end,
  })
  self.size_scans[destination] = scan
end

--- 给大小未知的目录条目补跑扫描（例如上次扫描中途退出了 Neovim）
--- 已在扫描、meta 缺失（孤儿条目）或 payload 不是目录的条目跳过
---@param entries? VVExplorerTrashEntry[] 已读取的列表，省略时重新 list()
function Store:ensure_sizes(entries)
  for _, entry in ipairs(entries or self:list()) do
    if entry.size_bytes == nil
      and entry.original_path ~= '(unknown)'
      and not self.size_scans[entry.trash_path]
    then
      local stat = uv.fs_lstat(entry.trash_path)
      if stat and stat.type == 'directory' then
        self:scan_entry_size(entry.trash_path, {
          original_path = entry.original_path,
          trashed_at = entry.trashed_at,
        })
      end
    end
  end
end

function Store:enforce_max_items()
  if not self.config.max_items then return end
  local entries = self:list()
  if #entries <= self.config.max_items then return end
  for index = self.config.max_items + 1, #entries do
    self:cancel_size_scan(entries[index].trash_path)
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

    -- lstat：移入的是链接本身，不跟随到目标去统计
    local stat = uv.fs_lstat(path)
    local is_dir = stat and stat.type == 'directory'
    local ok, error_message = pcall(Fs.rename, path, destination)
    if not ok then
      failed[#failed + 1] = tostring(error_message)
    else
      local metadata = {
        original_path = path,
        trashed_at = os.time(),
        size_bytes = (stat and not is_dir) and stat.size or nil,
      }
      local meta_ok = pcall(Fs.write_all, destination .. '.meta.json', vim.json.encode(metadata))
      if meta_ok and is_dir then self:scan_entry_size(destination, metadata) end
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
      size_bytes = metadata.size_bytes,
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
  self:cancel_size_scan(entry.trash_path)
  pcall(Fs.delete, entry.meta_path)
  return destination
end

---@param entry VVExplorerTrashEntry
function Store:delete_entry(entry)
  self:cancel_size_scan(entry.trash_path)
  Fs.delete(entry.trash_path)
  pcall(Fs.delete, entry.meta_path)
end

function Store:empty()
  for _, entry in ipairs(self:list()) do
    self:cancel_size_scan(entry.trash_path)
    pcall(Fs.delete, entry.trash_path)
    pcall(Fs.delete, entry.meta_path)
  end
end

--- 走 vv-utils.fs 的分片扫描而不是外部 `du`：BSD / macOS 的 du 没有 `-b` 命令
---@param callback fun(bytes:integer)
---@return VVFsDirScanHandle
function Store:scan_size(callback)
  return DirScan.scan(self.trash_dir, {
    on_done = function(result) callback(result.bytes) end,
  })
end

return Store

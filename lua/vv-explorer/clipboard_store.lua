-- 跨 Neovim 实例的文件剪贴板存储：验证并原子替换完整记录

local State = require('vv-utils.state')

local M = {}
local handle = State.register('vv-explorer', 'clipboard')
local uv = vim.uv or vim.loop
local owned_record
local owner_id = ('%s:%s'):format(uv.os_getpid(), uv.hrtime())

---@class VVExplorerClipboardRecord
---@field version 1
---@field id string
---@field mode 'copy'|'cut'
---@field paths string[]
---@field created_at integer
---@field owner_id? string

local function normalize_paths(paths)
  local result = {}
  local seen = {}

  for _, path in ipairs(paths or {}) do
    if type(path) == 'string' and path ~= '' then
      local normalized = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
      if normalized ~= '/' and not (vim.fn.has('win32') == 1 and normalized:match('^%a:[/]$')) then
        normalized = normalized:gsub('/+$', '')
      end
      if normalized ~= '' and not seen[normalized] then
        seen[normalized] = true
        result[#result + 1] = normalized
      end
    end
  end

  table.sort(result)
  return result
end

---@param mode 'copy'|'cut'
---@param paths string[]
---@return VVExplorerClipboardRecord
local function new_record(mode, paths, record_owner_id)
  return {
    version = 1,
    id = ('%s:%s'):format(uv.os_getpid(), uv.hrtime()),
    owner_id = record_owner_id or owner_id,
    mode = mode,
    paths = paths,
    created_at = os.time(),
  }
end

---@param value any
---@return VVExplorerClipboardRecord?
---@return string?
local function validate(value)
  if value == nil then return nil end
  if type(value) ~= 'table'
      or value.version ~= 1
      or type(value.id) ~= 'string'
      or (value.mode ~= 'copy' and value.mode ~= 'cut')
      or type(value.paths) ~= 'table'
      or type(value.created_at) ~= 'number'
      or (value.owner_id ~= nil and type(value.owner_id) ~= 'string')
  then
    return nil, 'invalid shared clipboard record'
  end

  local paths = normalize_paths(value.paths)
  if #paths == 0 or not vim.deep_equal(paths, value.paths) then
    return nil, 'invalid shared clipboard paths'
  end

  return {
    version = 1,
    id = value.id,
    owner_id = value.owner_id,
    mode = value.mode,
    paths = paths,
    created_at = math.floor(value.created_at),
  }
end

---@return VVExplorerClipboardRecord?
---@return string?
function M.read()
  return validate(handle:get('record'))
end

---订阅共享记录变化；返回的释放函数幂等
---@param callback fun(record: VVExplorerClipboardRecord?, error_message: string?)
---@return fun() unsubscribe
function M.subscribe(callback)
  return handle:subscribe('record', function(value)
    local record, error_message = validate(value)
    callback(record, error_message)
  end)
end

---@param mode 'copy'|'cut'
---@param paths string[]
---@return VVExplorerClipboardRecord?
---@return string?
function M.write(mode, paths)
  local normalized = normalize_paths(paths)
  if #normalized == 0 then return nil, 'cannot save an empty shared clipboard' end

  local record = new_record(mode, normalized)
  if not handle:set('record', record) then return nil, 'failed to save shared clipboard' end
  owned_record = record
  return record
end

---@param expected VVExplorerClipboardRecord
---@return boolean
---@return VVExplorerClipboardRecord? current
---@return string?
function M.clear(expected)
  local updated, current, error_message = handle:compare_and_set('record', expected, nil)
  if error_message then return false, nil, error_message end
  if updated and owned_record and vim.deep_equal(owned_record, expected) then owned_record = nil end
  local validated, validation_error = validate(current)
  return updated, validated, validation_error
end

---仅在共享记录仍是本次操作读取的版本时替换，避免清除另一个实例的新复制
---@param expected VVExplorerClipboardRecord
---@param mode 'copy'|'cut'
---@param paths string[]
---@param opts? { owner_id?: string, claim_ownership?: boolean }
---@return boolean updated
---@return VVExplorerClipboardRecord? current
---@return string? error_message
function M.replace_if_current(expected, mode, paths, opts)
  opts = opts or {}
  local normalized = normalize_paths(paths)
  local replacement = #normalized > 0 and new_record(mode, normalized, opts.owner_id) or nil
  local updated, current, error_message = handle:compare_and_set('record', expected, replacement)
  if error_message then return false, nil, error_message end
  if updated and opts.claim_ownership ~= false then owned_record = replacement end
  local validated, validation_error = validate(current)
  return updated, validated, validation_error
end

---记录是否由当前 Neovim 实例写入；只暴露判断，不暴露 owner_id 表示
---@param record VVExplorerClipboardRecord
---@return boolean
function M.is_owned(record)
  return record.owner_id ~= nil and record.owner_id == owner_id
end

---清理由当前 Neovim 实例创建的记录；不会删除其他实例后来写入的记录
---@return boolean released
---@return string? error_message
function M.release_owned()
  if not owned_record then return true end
  -- consumer 更新剩余路径会更换 record ID；退出时只追踪本 owner，
  -- CAS 失败后重读，绝不删除另一个 owner 新建的剪贴板
  for _ = 1, 8 do
    local expected, read_error = M.read()
    if read_error then return false, read_error end
    if not expected or expected.owner_id ~= owned_record.owner_id then
      owned_record = nil
      return true
    end
    local updated, _, error_message = handle:compare_and_set('record', expected, nil)

    if error_message then return false, error_message end
    if updated then
      owned_record = nil
      return true
    end
  end
  return false, 'shared clipboard kept changing during owner cleanup'
end

local lifecycle_group = vim.api.nvim_create_augroup('vv-explorer.clipboard', { clear = true })
vim.api.nvim_create_autocmd('VimLeavePre', {
  group = lifecycle_group,
  callback = function()
    local released, error_message = M.release_owned()
    if not released then
      vim.notify('vv-explorer: ' .. tostring(error_message), vim.log.levels.WARN)
    end
  end,
})

return M

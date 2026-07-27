-- 可恢复删除 facade

local Panel = require('vv-explorer.trash.panel')
local Store = require('vv-explorer.trash.store')

local M = {}

local active_store = nil ---@type VVExplorerTrashStore?

local function get_store()
  assert(active_store, 'vv-explorer trash is not configured; call setup() first')
  return active_store
end

---@param opts VVExplorerTrashConfig
function M.setup(opts)
  active_store = Store.new(opts)
  Panel.setup()
end

function M.enabled()
  return active_store and active_store:enabled()
end

---@param paths string[]
---@return {trashed:string[], failed:string[]}
function M.trash(paths)
  return get_store():trash(paths)
end

---@return VVExplorerTrashEntry[]
function M.list()
  return get_store():list()
end

---@param entry VVExplorerTrashEntry
---@return string
function M.restore(entry)
  return get_store():restore(entry)
end

---@param entry VVExplorerTrashEntry
function M.delete_entry(entry)
  get_store():delete_entry(entry)
end

function M.empty()
  get_store():empty()
end

---@param callback fun(bytes:integer)
function M.scan_size(callback)
  if active_store then active_store:scan_size(callback) end
end

---@param state table?
function M.open_panel(state)
  Panel.open(get_store(), state)
end

return M

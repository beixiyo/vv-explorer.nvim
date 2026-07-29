-- Explorer 路径可见性策略
--
-- Tree 与异步 filter index 共用 hidden/custom 语义；索引出口同时从文件路径
-- 重建父目录，避免补全和过滤把目录误当成文件或完全遗漏

local M = {}

---@param globs string[]?
---@return VVExplorerPredicate?
function M.compile_custom(globs)
  if not globs or #globs == 0 then return nil end

  local patterns = {}
  for _, glob in ipairs(globs) do
    local ok, pattern = pcall(vim.glob.to_lpeg, glob)
    if ok and pattern then patterns[#patterns + 1] = pattern end
  end
  if #patterns == 0 then return nil end

  return function(name)
    for _, pattern in ipairs(patterns) do
      if pattern:match(name) then return true end
    end
    return false
  end
end

---@param path string
---@return string
local function normalized(path)
  local result = vim.fs.normalize(path):gsub('\\', '/')
  if result == '/' or result:match('^%a:/$') then return result end
  result = result:gsub('/+$', '')
  return result
end

---@param path string
---@param cwd string
---@return string?
local function relative_to(path, cwd)
  if path == cwd then return '' end
  local prefix = cwd:sub(-1) == '/' and cwd or (cwd .. '/')
  if path:sub(1, #prefix) ~= prefix then return nil end
  return path:sub(#prefix + 1)
end

---@param tracked table<string, boolean>
---@param path string
---@param cwd string
local function mark_tracked_ancestors(tracked, path, cwd)
  local current = path
  while current ~= cwd and #current > #cwd do
    tracked[current] = true
    local parent = vim.fs.dirname(current)
    if parent == current then break end
    current = normalized(parent)
  end
end

---@param relative string
---@param cwd string
---@param opts VVExplorerFilterPolicyOpts
---@param tracked table<string, boolean>
---@param custom VVExplorerPredicate?
---@return boolean
local function is_visible(relative, cwd, opts, tracked, custom)
  local current = cwd
  for name in relative:gmatch('[^/]+') do
    current = normalized(vim.fs.joinpath(current, name))
    if custom and custom(name) then return false end
    if not opts.hidden and name:sub(1, 1) == '.' and not tracked[current] then return false end
  end
  return true
end

---统一应用 Tree 的 hidden/custom 策略，并从文件结果重建父目录
---@param cwd string
---@param entries VVExplorerFilterIndexEntry[]
---@param opts VVExplorerFilterPolicyOpts
---@return string[] paths, table<string, boolean> is_dir_map
function M.apply(cwd, entries, opts)
  cwd = normalized(cwd)

  local tracked = {}
  for _, entry in ipairs(entries) do
    if entry.tracked then mark_tracked_ancestors(tracked, normalized(entry.path), cwd) end
  end

  local custom = M.compile_custom(opts.custom)
  local included = {}
  local is_dir_map = {}

  for _, entry in ipairs(entries) do
    local path = normalized(entry.path)
    local relative = relative_to(path, cwd)
    if relative and relative ~= '' and is_visible(relative, cwd, opts, tracked, custom) then
      included[path] = true
      if entry.directory then is_dir_map[path] = true end

      local parent = normalized(vim.fs.dirname(path))
      while parent ~= cwd and #parent > #cwd do
        included[parent] = true
        is_dir_map[parent] = true
        local next_parent = normalized(vim.fs.dirname(parent))
        if next_parent == parent then break end
        parent = next_parent
      end
    end
  end

  local paths = vim.tbl_keys(included)
  table.sort(paths)
  return paths, is_dir_map
end

---@class VVExplorerFilterIndexEntry
---@field path string
---@field tracked boolean
---@field directory? boolean

---@class VVExplorerFilterPolicyOpts
---@field hidden boolean
---@field custom string[]

return M

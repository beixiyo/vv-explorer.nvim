-- 文件传输的路径身份、临时路径和 buffer 路径辅助

local Fs = require('vv-utils.fs')

local uv = vim.uv or vim.loop

local function normalize(path)
  local normalized = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  if normalized == '/' then return normalized end
  if vim.fn.has('win32') == 1 and normalized:match('^%a:[/]$') then return normalized end
  return normalized:gsub('/+$', '')
end

local function under(path, parent)
  if path == parent then return true end
  if parent == '/' then return path:sub(1, 1) == '/' end
  if vim.fn.has('win32') == 1 and parent:match('^%a:[/]$') then
    return path:sub(1, #parent) == parent
  end
  return path:sub(1, #parent + 1) == parent .. '/'
end

-- Resolve symlinked parent components for filesystem operations while keeping
-- the final component lexical.  The latter is important: copying or replacing
-- a source/destination symlink must operate on the link itself, not on its
-- target.
local function operation_path(path)
  path = normalize(path)
  local parent = normalize(Fs.realpath(vim.fs.dirname(path)))
  return vim.fs.joinpath(parent, vim.fs.basename(path))
end

local function modified_buffer_under(destination)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= '' and under(operation_path(name), destination) then return name end
    end
  end
end

local function checktime_under(destination)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and not vim.bo[buf].modified then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= '' and under(operation_path(name), destination) then
        pcall(vim.api.nvim_buf_call, buf, function() vim.cmd('silent checktime') end)
      end
    end
  end
end

-- 移动目标路径上残留的过期 buffer（未修改、磁盘文件已不存在，例如 Git 丢弃改动删掉了文件但 buffer 还在）
-- 必须在发 willRenameFiles 与落盘之前关掉：它仍挂着 LSP client，服务端会把这个路径当成客户端已打开的文档；
-- 它还占着这个 buffer 名，之后 sync_buffers 把源 buffer 改名到这里会失败，源 buffer 停在已不存在的旧路径。
-- 已修改的 buffer 不动，由 install_move 的 modified_buffer_under 拒绝移动。buffer 名可能是逻辑路径，
-- 也可能是解析过父级软链接的路径，两种都处理
local function close_stale_buffers(path)
  Fs.close_stale_buffers(normalize(path))
  local ok, resolved = pcall(operation_path, path)
  if ok and resolved ~= normalize(path) then Fs.close_stale_buffers(resolved) end
end

local function check_operation_path(logical_destination, destination)
  local ok, current = pcall(operation_path, logical_destination)
  if not ok then return false, tostring(current) end
  if current ~= destination then
    return false, 'destination parent changed during paste: ' .. logical_destination
  end
  return true
end

local function unique_unreserved(destination, reserved, is_directory)
  if not Fs.exists(destination) and not reserved[destination] then return destination end

  local directory = vim.fs.dirname(destination)
  local basename = vim.fs.basename(destination)
  local stem, extension
  if is_directory then
    stem, extension = basename, ''
  else
    stem, extension = basename:match('^(.+)(%.[^.]+)$')
    if not stem then stem, extension = basename, '' end
  end

  local index = 1
  while true do
    local suffix = index == 1 and ' (copy)' or (' (copy %d)'):format(index)
    local candidate = vim.fs.joinpath(directory, stem .. suffix .. extension)
    if not Fs.exists(candidate) and not reserved[candidate] then return candidate end
    index = index + 1
  end
end

return {
  normalize = normalize,
  under = under,
  operation_path = operation_path,
  modified_buffer_under = modified_buffer_under,
  checktime_under = checktime_under,
  close_stale_buffers = close_stale_buffers,
  check_operation_path = check_operation_path,
  unique_unreserved = unique_unreserved,
  identity = function(path) return normalize(Fs.realpath(path)) end,
  is_symlink = function(path)
    local stat = uv.fs_lstat(path)
    return stat and stat.type == 'link'
  end,
}

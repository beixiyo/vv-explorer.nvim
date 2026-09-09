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
  check_operation_path = check_operation_path,
  unique_unreserved = unique_unreserved,
  identity = function(path) return normalize(Fs.realpath(path)) end,
  is_symlink = function(path)
    local stat = uv.fs_lstat(path)
    return stat and stat.type == 'link'
  end,
}

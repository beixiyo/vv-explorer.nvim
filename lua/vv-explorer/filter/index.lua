-- 异步构建全树路径索引
--
-- Git 与 fd 只负责枚举原始条目；hidden/custom 策略和父目录重建统一在
-- filter.policy 出口完成，供过滤与补全共享同一份索引

local Policy = require('vv-explorer.filter.policy')

local M = {}

---@param line string
---@param scope_prefix string
---@return string
local function strip_scope(line, scope_prefix)
  if scope_prefix == '' then return line end
  if line == scope_prefix then return '' end
  if line:sub(1, #scope_prefix + 1) == scope_prefix .. '/' then
    return line:sub(#scope_prefix + 2)
  end
  return line
end

---@param output_root string
---@param stdout string?
---@param tracked boolean
---@param scope_prefix string
---@return VVExplorerFilterIndexEntry[]
local function parse_git_paths(output_root, stdout, tracked, scope_prefix)
  local entries = {}
  if not stdout then return entries end

  for line in (stdout .. '\0'):gmatch('([^%z]+)%z') do
    local directory = line:sub(-1) == '/'
    if directory then line = line:sub(1, -2) end
    line = strip_scope(line, scope_prefix)
    if line ~= '' then
      entries[#entries + 1] = {
        path = vim.fs.joinpath(output_root, line),
        tracked = tracked,
        directory = directory,
      }
    end
  end
  return entries
end

---@param command string[]
---@param callback fun(result: vim.SystemCompleted)
local function run(command, callback)
  vim.system(command, { text = false }, vim.schedule_wrap(callback))
end

---@param command_root string
---@param output_root string
---@param relative_cwd string
---@param callback fun(entries: VVExplorerFilterIndexEntry[])
local function git_worktree_entries(command_root, output_root, relative_cwd, callback)
  local entries = {}
  local pending = 2

  local function collect(result, tracked)
    if result.code == 0 then
      vim.list_extend(entries, parse_git_paths(output_root, result.stdout, tracked, relative_cwd))
    end
    pending = pending - 1
    if pending == 0 then callback(entries) end
  end

  local tracked = { 'git', '-C', command_root, 'ls-files', '-z', '--cached', '--full-name' }
  local untracked = {
    'git', '-C', command_root, 'ls-files', '-z', '--others', '--exclude-standard', '--full-name',
  }
  if relative_cwd ~= '' then
    vim.list_extend(tracked, { '--', relative_cwd })
    vim.list_extend(untracked, { '--', relative_cwd })
  end

  run(tracked, function(result) collect(result, true) end)
  run(untracked, function(result) collect(result, false) end)
end

---@param command_root string
---@param output_root string
---@param relative_cwd string
---@param callback fun(entries: VVExplorerFilterIndexEntry[], nested_repos: string[])
local function git_ignored_entries(command_root, output_root, relative_cwd, callback)
  local command = {
    'git', '-C', command_root, 'ls-files', '-z',
    '--others', '--ignored', '--exclude-standard', '--directory', '--full-name',
  }
  if relative_cwd ~= '' then vim.list_extend(command, { '--', relative_cwd }) end

  run(command, function(result)
    local entries = {}
    local nested_repos = {}
    if result.code == 0 and result.stdout then
      for line in (result.stdout .. '\0'):gmatch('([^%z]+)%z') do
        local directory = line:sub(-1) == '/'
        if directory then line = line:sub(1, -2) end
        line = strip_scope(line, relative_cwd)
        if line ~= '' then
          local absolute = vim.fs.joinpath(output_root, line)
          entries[#entries + 1] = {
            path = absolute,
            tracked = false,
            directory = directory,
          }
          if directory and vim.uv.fs_stat(vim.fs.joinpath(absolute, '.git')) then
            nested_repos[#nested_repos + 1] = absolute
          end
        end
      end
    end
    callback(entries, nested_repos)
  end)
end

---@param cwd string
---@param opts VVExplorerFilterIndexOpts
---@param entries VVExplorerFilterIndexEntry[]
---@param on_done fun(paths:string[], is_dir_map:table<string, boolean>)
local function finish(cwd, opts, entries, on_done)
  local paths, is_dir_map = Policy.apply(cwd, entries, {
    hidden = opts.hidden,
    custom = opts.custom,
  })
  on_done(paths, is_dir_map)
end

---@param cwd string
---@param git_root string
---@param opts VVExplorerFilterIndexOpts
---@param on_done fun(paths:string[], is_dir_map:table<string, boolean>)
local function build_git(cwd, git_root, opts, on_done)
  local real_cwd = vim.uv.fs_realpath(cwd) or cwd
  local relative_cwd = git_root ~= real_cwd and real_cwd:sub(#git_root + 2) or ''
  local output_root = cwd

  git_worktree_entries(git_root, output_root, relative_cwd, function(entries)
    if not opts.show_ignored then
      finish(cwd, opts, entries, on_done)
      return
    end

    git_ignored_entries(git_root, output_root, relative_cwd, function(ignored, nested_repos)
      vim.list_extend(entries, ignored)
      if #nested_repos == 0 then
        finish(cwd, opts, entries, on_done)
        return
      end

      local pending = #nested_repos
      for _, repo_dir in ipairs(nested_repos) do
        git_worktree_entries(repo_dir, repo_dir, '', function(nested)
          vim.list_extend(entries, nested)
          pending = pending - 1
          if pending == 0 then finish(cwd, opts, entries, on_done) end
        end)
      end
    end)
  end)
end

---@param cwd string
---@param opts {hidden?:boolean, show_ignored?:boolean, custom?:string[]}
---@param on_done fun(paths:string[], is_dir_map:table<string, boolean>)
---@return boolean ok
function M.build(cwd, opts, on_done)
  opts = opts or {}
  ---@type VVExplorerFilterIndexOpts
  local resolved_opts = {
    hidden = opts.hidden == true,
    show_ignored = opts.show_ignored == true,
    custom = opts.custom or {},
  }
  local git_root = require('vv-utils.git').root(cwd) or ''

  -- git ls-files 遵循 gitignore 规则；tracked/untracked 分开读取，使 hidden
  -- 策略仍可放行被跟踪的 dotfile 及其父目录
  if git_root ~= '' then
    build_git(cwd, git_root, resolved_opts, on_done)
    return true
  end

  if vim.fn.executable('fd') ~= 1 then
    vim.notify(
      "vv-explorer: filter requires 'fd' (not found in $PATH).\n" ..
      "Install: https://github.com/sharkdp/fd#installation\n" ..
      "  macOS:  brew install fd\n" ..
      "  Linux:  apt install fd-find  |  pacman -S fd\n" ..
      "  cargo:  cargo install fd-find",
      vim.log.levels.WARN,
      { title = 'vv-explorer' }
    )
    return false
  end

  local command = { 'fd', '--type', 'f', '--type', 'd' }
  if resolved_opts.hidden then command[#command + 1] = '--hidden' end
  if resolved_opts.show_ignored then command[#command + 1] = '--no-ignore' end
  command[#command + 1] = '--exclude'
  command[#command + 1] = '.git'
  for _, pattern in ipairs(resolved_opts.custom) do
    command[#command + 1] = '--exclude'
    command[#command + 1] = pattern
  end
  command[#command + 1] = '.'

  vim.system(command, { text = true, cwd = cwd }, vim.schedule_wrap(function(result)
    local entries = {}
    if result.code == 0 and result.stdout then
      for line in result.stdout:gmatch('[^\n]+') do
        local directory = line:sub(-1) == '/'
        if directory then line = line:sub(1, -2) end
        entries[#entries + 1] = {
          path = vim.fs.joinpath(cwd, line),
          tracked = false,
          directory = directory,
        }
      end
    end
    finish(cwd, resolved_opts, entries, on_done)
  end))
  return true
end

---@class VVExplorerFilterIndexOpts
---@field hidden boolean
---@field show_ignored boolean
---@field custom string[]

return M

-- 异步构建全树路径索引
--
-- Git 与 fd 只负责枚举原始条目；hidden/custom 策略和父目录重建统一在
-- filter.policy 出口完成，供过滤与补全共享同一份索引

local Policy = require('vv-explorer.filter.policy')

local M = {}

local function cancel_bag()
  local cancelled = false
  local producers = {}

  local function add(producer)
    if not producer then return end
    if cancelled then
      pcall(producer.kill, producer, 'sigterm')
    else
      producers[producer] = true
    end
  end

  local function done(producer)
    producers[producer] = nil
  end

  local function cancel()
    if cancelled then return end
    cancelled = true
    for producer in pairs(producers) do pcall(producer.kill, producer, 'sigterm') end
    producers = {}
  end

  return {
    add = add,
    done = done,
    cancel = cancel,
    is_cancelled = function() return cancelled end,
  }
end

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
---@param system_opts table
---@param bag table
---@param on_error fun(error:any)
---@param callback fun(result: vim.SystemCompleted)
---@return boolean started
local function run(command, system_opts, bag, on_error, callback)
  if bag.is_cancelled() then return false end

  local producer
  local completed = false
  local ok, result = pcall(vim.system, command, system_opts, function(result)
    completed = true
    if producer then bag.done(producer) end
    vim.schedule(function()
      if bag.is_cancelled() then return end
      callback(result)
    end)
  end)

  if not ok then
    on_error(result)
    return false
  end

  producer = result
  if not completed then bag.add(producer) end
  return true
end

---@param command_root string
---@param output_root string
---@param relative_cwd string
---@param bag table
---@param on_error fun(error:any)
---@param callback fun(entries: VVExplorerFilterIndexEntry[])
---@return boolean started
local function git_worktree_entries(command_root, output_root, relative_cwd, bag, on_error, callback)
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

  if not run(tracked, { text = false }, bag, on_error, function(result)
    collect(result, true)
  end) then return false end

  return run(untracked, { text = false }, bag, on_error, function(result)
    collect(result, false)
  end)
end

---@param command_root string
---@param output_root string
---@param relative_cwd string
---@param bag table
---@param on_error fun(error:any)
---@param callback fun(entries: VVExplorerFilterIndexEntry[], nested_repos: string[])
---@return boolean started
local function git_ignored_entries(command_root, output_root, relative_cwd, bag, on_error, callback)
  local command = {
    'git', '-C', command_root, 'ls-files', '-z',
    '--others', '--ignored', '--exclude-standard', '--directory', '--full-name',
  }
  if relative_cwd ~= '' then vim.list_extend(command, { '--', relative_cwd }) end

  return run(command, { text = false }, bag, on_error, function(result)
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
---@param bag table
---@param on_error fun(error:any)
---@param on_done fun(paths:string[], is_dir_map:table<string, boolean>)
---@return boolean started
local function build_git(cwd, git_root, opts, bag, on_error, on_done)
  local real_cwd = vim.uv.fs_realpath(cwd) or cwd
  local relative_cwd = git_root ~= real_cwd and real_cwd:sub(#git_root + 2) or ''
  local output_root = cwd

  return git_worktree_entries(git_root, output_root, relative_cwd, bag, on_error, function(entries)
    if not opts.show_ignored then
      finish(cwd, opts, entries, on_done)
      return
    end

    git_ignored_entries(git_root, output_root, relative_cwd, bag, on_error, function(ignored, nested_repos)
      vim.list_extend(entries, ignored)
      if #nested_repos == 0 then
        finish(cwd, opts, entries, on_done)
        return
      end

      local pending = #nested_repos
      for _, repo_dir in ipairs(nested_repos) do
        if not git_worktree_entries(repo_dir, repo_dir, '', bag, on_error, function(nested)
          vim.list_extend(entries, nested)
          pending = pending - 1
          if pending == 0 then finish(cwd, opts, entries, on_done) end
        end) then return end
      end
    end)
  end)
end

---@param cwd string
---@param opts {hidden?:boolean, show_ignored?:boolean, custom?:string[], on_error?:fun(error:string)}
---@param on_done fun(paths:string[], is_dir_map:table<string, boolean>)
---@return boolean ok
---@return fun() cancel
function M.build(cwd, opts, on_done)
  opts = opts or {}
  ---@type VVExplorerFilterIndexOpts
  local resolved_opts = {
    hidden = opts.hidden == true,
    show_ignored = opts.show_ignored == true,
    custom = opts.custom or {},
  }
  local git_root = require('vv-utils.git').root(cwd) or ''
  local bag = cancel_bag()
  local failed = false
  local returned = false

  local function fail_pipeline(err)
    if failed or bag.is_cancelled() then return end
    failed = true
    bag.cancel()

    local message = tostring(err)
    pcall(vim.notify, 'vv-explorer: filter index failed\n' .. message, vim.log.levels.ERROR, {
      title = 'vv-explorer',
    })
    -- 同步失败由 build() 的 ok=false 交给调用方处理；返回后的动态阶段
    -- 必须主动结束调用方持有的 request，避免永久停在 building
    if returned and opts.on_error then opts.on_error(message) end
  end

  local function start_pipeline(callback)
    local ok, err = xpcall(callback, debug.traceback)
    if not ok then fail_pipeline(err) end
    return ok and not failed
  end

  -- git ls-files 遵循 gitignore 规则；tracked/untracked 分开读取，使 hidden
  -- 策略仍可放行被跟踪的 dotfile 及其父目录
  if git_root ~= '' then
    local ok = start_pipeline(function()
      build_git(cwd, git_root, resolved_opts, bag, fail_pipeline, on_done)
    end)
    returned = true
    return ok, bag.cancel
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
    return false, bag.cancel
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

  local ok = start_pipeline(function()
    run(command, { text = true, cwd = cwd }, bag, fail_pipeline, function(result)
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
    end)
  end)
  returned = true
  return ok, bag.cancel
end

---@class VVExplorerFilterIndexOpts
---@field hidden boolean
---@field show_ignored boolean
---@field custom string[]

return M

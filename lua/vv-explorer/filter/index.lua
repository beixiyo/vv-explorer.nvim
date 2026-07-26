-- Asynchronous full-tree path indexing

local M = {}

---@param cwd string
---@param opts {hidden?:boolean, show_ignored?:boolean, custom?:string[]}
---@param on_done fun(paths:string[], is_dir_map:table<string, boolean>)
---@return boolean ok
function M.build(cwd, opts, on_done)
  local hidden = opts and opts.hidden
  local show_ignored = opts and opts.show_ignored
  local custom = opts and opts.custom or {}

  local git_root = require('vv-utils.git').root(cwd) or ''
  local in_git = git_root ~= ''

  -- git ls-files is gitignore-aware and handles nested repositories consistently.
  if in_git and not show_ignored then
    local relative_cwd = git_root ~= cwd and cwd:sub(#git_root + 2) or ''
    local command = {
      'git', '-C', git_root, 'ls-files', '-z',
      '--cached', '--others', '--exclude-standard', '--full-name',
    }
    for _, pattern in ipairs(custom) do
      command[#command + 1] = '--exclude=' .. pattern
    end
    if relative_cwd ~= '' then
      command[#command + 1] = '--'
      command[#command + 1] = relative_cwd
    end

    vim.system(command, { text = false }, vim.schedule_wrap(function(result)
      local paths = {}
      if result.code == 0 and result.stdout then
        for line in (result.stdout .. '\0'):gmatch('([^%z]+)%z') do
          paths[#paths + 1] = git_root .. '/' .. line
        end
      end
      on_done(paths, {})
    end))
    return true
  end

  -- When ignored paths are visible, include ignored files plus files from ignored nested repos,
  -- without recursively scanning every ignored system directory.
  if in_git then
    local relative_cwd = git_root ~= cwd and cwd:sub(#git_root + 2) or ''
    local tracked_command = {
      'git', '-C', git_root, 'ls-files', '-z',
      '--cached', '--others', '--exclude-standard', '--full-name',
    }
    for _, pattern in ipairs(custom) do
      tracked_command[#tracked_command + 1] = '--exclude=' .. pattern
    end
    if relative_cwd ~= '' then
      tracked_command[#tracked_command + 1] = '--'
      tracked_command[#tracked_command + 1] = relative_cwd
    end

    vim.system(tracked_command, { text = false }, vim.schedule_wrap(function(tracked_result)
      local tracked_paths = {}
      if tracked_result.code == 0 and tracked_result.stdout then
        for line in (tracked_result.stdout .. '\0'):gmatch('([^%z]+)%z') do
          tracked_paths[#tracked_paths + 1] = git_root .. '/' .. line
        end
      end

      local ignored_command = {
        'git', '-C', git_root, 'ls-files', '-z',
        '--others', '--ignored', '--exclude-standard', '--directory', '--full-name',
      }
      if relative_cwd ~= '' then
        ignored_command[#ignored_command + 1] = '--'
        ignored_command[#ignored_command + 1] = relative_cwd
      end

      vim.system(ignored_command, { text = false }, vim.schedule_wrap(function(ignored_result)
        local nested_repos = {}
        local individually_ignored = {}
        if ignored_result.code == 0 and ignored_result.stdout then
          for line in (ignored_result.stdout .. '\0'):gmatch('([^%z]+)%z') do
            if line:sub(-1) == '/' then
              local directory = line:sub(1, -2)
              local absolute_directory = git_root .. '/' .. directory
              if vim.uv.fs_stat(absolute_directory .. '/.git') then
                nested_repos[#nested_repos + 1] = absolute_directory
              end
            else
              individually_ignored[#individually_ignored + 1] = git_root .. '/' .. line
            end
          end
        end

        local paths = {}
        for _, path in ipairs(tracked_paths) do paths[#paths + 1] = path end
        for _, path in ipairs(individually_ignored) do paths[#paths + 1] = path end

        if #nested_repos == 0 then
          on_done(paths, {})
          return
        end

        local pending = #nested_repos
        for _, repo_dir in ipairs(nested_repos) do
          vim.system(
            { 'git', '-C', repo_dir, 'ls-files', '-z', '--cached', '--others', '--exclude-standard' },
            { text = false },
            vim.schedule_wrap(function(nested_result)
              if nested_result.code == 0 and nested_result.stdout then
                for line in (nested_result.stdout .. '\0'):gmatch('([^%z]+)%z') do
                  paths[#paths + 1] = repo_dir .. '/' .. line
                end
              end
              pending = pending - 1
              if pending == 0 then on_done(paths, {}) end
            end)
          )
        end
      end))
    end))
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
  if hidden then command[#command + 1] = '--hidden' end
  if show_ignored then command[#command + 1] = '--no-ignore' end
  command[#command + 1] = '--exclude'
  command[#command + 1] = '.git'
  for _, pattern in ipairs(custom) do
    command[#command + 1] = '--exclude'
    command[#command + 1] = pattern
  end
  command[#command + 1] = '.'

  vim.system(command, { text = true, cwd = cwd }, vim.schedule_wrap(function(result)
    local paths = {}
    local is_dir_map = {}
    if result.code == 0 and result.stdout then
      for line in result.stdout:gmatch('[^\n]+') do
        local is_directory = line:sub(-1) == '/'
        if is_directory then line = line:sub(1, -2) end
        local absolute = cwd .. '/' .. line
        paths[#paths + 1] = absolute
        if is_directory then is_dir_map[absolute] = true end
      end
    end
    on_done(paths, is_dir_map)
  end))
  return true
end

return M

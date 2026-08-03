-- 过滤索引真实生产异步生命周期
-- 运行：nvim --headless -u NONE -l tests/test_filter_scope.lua
---@diagnostic disable: duplicate-set-field, missing-fields

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vendors .. '/vv-icons.nvim')
vim.opt.runtimepath:prepend(root)

local original_system = vim.system
local original_executable = vim.fn.executable
local original_schedule_wrap = vim.schedule_wrap
local original_schedule = vim.schedule
local Git = require('vv-utils.git')
local original_git_root = Git.root

local function fake_system(opts)
  local calls = {}
  vim.system = function(command, system_opts, callback)
    local call = { command = command, opts = system_opts, callback = callback, kills = 0 }
    calls[#calls + 1] = call
    local handle = {}
    function handle:kill(signal)
      assert(signal == 'sigterm')
      call.kills = call.kills + 1
    end
    if opts and opts.synchronous then callback(opts.result or { code = 0, stdout = '' }) end
    return handle
  end
  return calls
end

local function restore()
  vim.system = original_system
  vim.fn.executable = original_executable
  vim.schedule_wrap = original_schedule_wrap
  vim.schedule = original_schedule
  Git.root = original_git_root
end

local ok, err = xpcall(function()
  vim.schedule_wrap = function(callback) return callback end
  vim.schedule = function(callback) callback() end
  vim.fn.executable = function(command)
    if command == 'fd' then return 1 end
    return original_executable(command)
  end

  do
    Git.root = function() return '' end
    local calls = fake_system()
    local delivered = 0
    local built, cancel = require('vv-explorer.filter.index').build('/a', {}, function()
      delivered = delivered + 1
    end)
    assert(built and type(cancel) == 'function')
    local queued
    vim.schedule = function(callback) queued = callback end
    calls[1].callback({ code = 0, stdout = 'old.txt\n' })
    cancel()
    cancel()
    assert(calls[1].kills == 0, 'a producer completed before cancellation must not be killed')
    assert(queued, 'the producer callback must actually enter the Lua schedule queue')
    queued()
    assert(delivered == 0, 'cancel must suppress an already queued producer callback')
    vim.schedule = function(callback) callback() end
  end

  do
    Git.root = function() return '/repo' end
    local calls = fake_system()
    local delivered = 0
    local _, cancel = require('vv-explorer.filter.index').build('/repo', {
      show_ignored = true,
    }, function() delivered = delivered + 1 end)

    assert(#calls == 2, 'git worktree phase must start tracked and untracked scans')
    calls[1].callback({ code = 0, stdout = 'tracked\0' })
    calls[2].callback({ code = 0, stdout = '' })
    assert(#calls == 3, 'ignored scan must start only after worktree phase completes')

    local original_stat = vim.uv.fs_stat
    vim.uv.fs_stat = function(path)
      if path == '/repo/nested/.git' then return { type = 'directory' } end
      return original_stat(path)
    end
    calls[3].callback({ code = 0, stdout = 'nested/\0' })
    vim.uv.fs_stat = original_stat
    assert(#calls == 5, 'nested repository scans must be dynamically registered')

    cancel()
    assert(calls[4].kills == 1 and calls[5].kills == 1,
      'cancel must kill both nested-repository producers')
    calls[4].callback({ code = 0, stdout = 'late\0' })
    calls[5].callback({ code = 0, stdout = '' })
    assert(delivered == 0, 'cancelled nested callbacks must not finish the pipeline')
  end

  do
    Git.root = function() return '/repo' end
    local spawn_count = 0
    local first = { kills = 0 }
    function first:kill(signal)
      assert(signal == 'sigterm')
      self.kills = self.kills + 1
    end
    vim.system = function()
      spawn_count = spawn_count + 1
      if spawn_count == 2 then error('injected second filter spawn failure') end
      return first
    end
    local notifications = 0
    local original_notify = vim.notify
    vim.notify = function(message, level)
      assert(message:find('injected second filter spawn failure', 1, true))
      assert(level == vim.log.levels.ERROR)
      notifications = notifications + 1
    end

    local call_ok, built, cancel = pcall(require('vv-explorer.filter.index').build, '/repo', {}, function()
      error('failed pipeline must not publish')
    end)
    vim.notify = original_notify
    assert(call_ok and built == false and type(cancel) == 'function',
      'filter build must contain producer construction failures')
    assert(first.kills == 1, 'second filter spawn failure rolls back the first producer')
    assert(notifications == 1, 'filter construction failure is reported once')
  end

  do
    Git.root = function() return '' end
    local calls = fake_system({ synchronous = true, result = { code = 0, stdout = 'sync.txt\n' } })
    local delivered = 0
    local _, cancel = require('vv-explorer.filter.index').build('/sync', {}, function()
      delivered = delivered + 1
    end)
    assert(delivered == 1, 'synchronous producer completion must publish once')
    cancel()
    assert(calls[1].kills == 0, 'late cancel must not kill an already completed producer')
  end

  do
    Git.root = function() return '' end
    local calls = fake_system()
    local fixture = vim.fn.tempname()
    vim.fn.mkdir(fixture, 'p')
    vim.fn.writefile({ 'return true' }, fixture .. '/file.lua')

    local explorer = require('vv-explorer')
    explorer.setup({
      cwd = fixture,
      persist_open = false,
      preview = false,
      watch = false,
      follow_file = false,
      git = false,
      diagnostics = false,
      trash = false,
      global_mappings = false,
    })
    explorer.open({ cwd = fixture, focus = true })

    local explorer_buf
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == 'vv-explorer' then explorer_buf = buf; break end
    end
    assert(explorer_buf, 'real explorer panel buffer must open')
    local start_filter = vim.fn.maparg('/', 'n', false, true).callback
    assert(type(start_filter) == 'function', 'real / mapping must expose the filter action')
    start_filter()
    assert(#calls == 1, 'real / mapping must start the fd index producer')

    vim.api.nvim_buf_delete(explorer_buf, { force = true })
    assert(calls[1].kills == 1, 'BufWipeout owner teardown must physically kill fd')
    local callback_ok = pcall(calls[1].callback, { code = 0, stdout = 'late.lua\n' })
    assert(callback_ok, 'late fd callback after panel wipe must be harmless')
    assert(#calls == 1, 'late callback after panel wipe must not derive more producers')
    vim.fn.delete(fixture, 'rf')
  end

  do
    Git.root = function() return '' end
    local calls = fake_system()

    package.loaded['vv-explorer.render'] = { render = function() end }
    package.loaded['vv-explorer.preview'] = { preview_file = function() end }
    package.loaded['vv-explorer.prompt'] = {
      open = function()
        return { close = function() end, set_busy = function() end }
      end,
    }
    package.loaded['vv-explorer.tree'] = { expand_to = function() end }
    package.loaded['vv-explorer.actions.filter'] = nil

    local M = {}
    local H = require('vv-explorer.actions.helpers')
    require('vv-explorer.actions.filter').attach(M, H)

    Git.root = function() return '/broken' end
    local failure_spawn = 0
    local active_handle = { kills = 0 }
    function active_handle:kill() self.kills = self.kills + 1 end
    vim.system = function()
      failure_spawn = failure_spawn + 1
      if failure_spawn == 2 then error('injected action filter spawn failure') end
      return active_handle
    end
    local original_notify = vim.notify
    vim.notify = function() end
    local failure_state = {
      root = { path = '/broken' },
      opts = { hidden = false, git = {}, filter = {} },
    }
    M.start_filter(failure_state)
    assert(active_handle.kills == 1, 'action-level construction failure releases the started producer')
    assert(failure_state.filter.index_building == false and failure_state.filter.index_root == nil,
      'action-level construction failure leaves no pending filter owner')

    Git.root = function() return '/dynamic' end
    local dynamic_calls = {}
    local dynamic_spawns = 0
    local dynamic_errors = 0
    vim.notify = function(message, level)
      if message:find('injected dynamic nested spawn failure', 1, true) then
        assert(level == vim.log.levels.ERROR)
        dynamic_errors = dynamic_errors + 1
      end
    end
    vim.system = function(command, system_opts, callback)
      dynamic_spawns = dynamic_spawns + 1
      if dynamic_spawns == 5 then error('injected dynamic nested spawn failure') end

      local call = { command = command, opts = system_opts, callback = callback, kills = 0 }
      dynamic_calls[#dynamic_calls + 1] = call
      local handle = {}
      function handle:kill(signal)
        assert(signal == 'sigterm')
        call.kills = call.kills + 1
      end
      return handle
    end

    local dynamic_state = {
      root = { path = '/dynamic' },
      opts = { hidden = false, git = { show_ignored = true }, filter = {} },
    }
    M.start_filter(dynamic_state)
    assert(#dynamic_calls == 2, 'dynamic pipeline must start tracked and untracked producers')
    dynamic_calls[1].callback({ code = 0, stdout = '' })
    dynamic_calls[2].callback({ code = 0, stdout = '' })
    assert(#dynamic_calls == 3, 'ignored producer must start after the worktree phase')

    local original_stat = vim.uv.fs_stat
    vim.uv.fs_stat = function(path)
      if path == '/dynamic/nested/.git' then return { type = 'directory' } end
      return original_stat(path)
    end
    local callback_ok = pcall(dynamic_calls[3].callback, { code = 0, stdout = 'nested/\0' })
    vim.uv.fs_stat = original_stat

    assert(callback_ok, 'dynamic nested spawn failure must not escape its scheduled callback')
    assert(dynamic_spawns == 5 and dynamic_calls[4].kills == 1,
      'dynamic nested spawn failure must cancel the producer started immediately before it')
    assert(dynamic_state.filter.index == nil and dynamic_state.filter.index_building == false,
      'dynamic nested spawn failure must not publish a partial index or remain building')
    assert(dynamic_state.filter.index_root == nil and dynamic_state.filter.active == false,
      'dynamic nested spawn failure must terminalize and clear the action owner')
    dynamic_calls[4].callback({ code = 0, stdout = 'late\0' })
    assert(dynamic_errors == 1 and dynamic_state.filter.index == nil,
      'dynamic failure must report once and suppress late producer delivery')

    Git.root = function() return '' end
    local recovery_calls = fake_system()
    M.start_filter(dynamic_state)
    assert(#recovery_calls == 1, 'the action request lane must remain reusable after dynamic failure')
    recovery_calls[1].callback({ code = 0, stdout = 'recovered.txt\n' })
    assert(vim.deep_equal(dynamic_state.filter.index, { '/dynamic/recovered.txt' }),
      'a successor build must publish after dynamic failure cleanup')

    vim.notify = original_notify

    Git.root = function() return '' end
    calls = fake_system()
    local state = {
      root = { path = '/old' },
      opts = { hidden = false, git = {}, filter = {} },
    }

    M.start_filter(state)
    local old_filter = state.filter
    state.root.path = '/new'
    M.start_filter(state)
    assert(#calls == 2 and calls[1].kills == 1,
      'root change must physically cancel the old build before starting the new one')

    calls[2].callback({ code = 0, stdout = 'new.txt\n' })
    assert(vim.deep_equal(old_filter.index, { '/new/new.txt' }), 'new build must publish')
    calls[1].callback({ code = 0, stdout = 'old.txt\n' })
    assert(vim.deep_equal(old_filter.index, { '/new/new.txt' }),
      'slow A must not overwrite fast B after root change')

    H.invalidate_filter_index(state)
    assert(old_filter.index == nil and old_filter.index_building == false,
      'explicit invalidation must clear the built index')

    M.start_filter(state)
    assert(#calls == 3)
    M.clear_filter(state)
    assert(calls[3].kills == 1 and old_filter.index_building == false,
      'closing an active filter must cancel its in-flight build')
    calls[3].callback({ code = 0, stdout = 'queued.txt\n' })
    assert(old_filter.index == nil, 'queued callback after clear must stay suppressed')

    M.start_filter(state)
    assert(#calls == 4, 'the owner scope must remain reusable after clear')
    calls[4].callback({ code = 0, stdout = 'latest.txt\n' })
    assert(vim.deep_equal(old_filter.index, { '/new/latest.txt' }),
      'old cleanup must not invalidate a successor request')

    local sync_calls = fake_system({ synchronous = true, result = {
      code = 0,
      stdout = 'sync-action.txt\n',
    } })
    local sync_state = {
      root = { path = '/sync-action' },
      opts = { hidden = false, git = {}, filter = {} },
    }
    M.start_filter(sync_state)
    assert(#sync_calls == 1)
    assert(vim.deep_equal(sync_state.filter.index, { '/sync-action/sync-action.txt' }))
    assert(sync_state.filter.index_building == false,
      'synchronous completion must finish the request before the late cancel handle is attached')
    assert(sync_calls[1].kills == 0,
      'attaching the cancel handle after synchronous finish must not kill the completed producer')
  end
end, debug.traceback)

restore()
assert(ok, err)
print('vv-explorer filter request scope: PASS')

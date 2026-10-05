local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["过滤索引请求取消旧任务，过期结果与关闭后回调不得回写"] = function()
  child.lua_func(function()
    -- 过滤索引真实生产异步生命周期
    ---@diagnostic disable: duplicate-set-field, missing-fields

    local root = vim.env.VV_TEST_REPO

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
        assert(calls[1].kills == 0, '取消前已完成的生产者不得被终止')
        assert(queued, '生产者回调必须真正进入 Lua schedule 队列')
        queued()
        assert(delivered == 0, '取消必须抑制已排队的生产者回调')
        vim.schedule = function(callback) callback() end
      end

      do
        Git.root = function() return '/repo' end
        local calls = fake_system()
        local delivered = 0
        local _, cancel = require('vv-explorer.filter.index').build('/repo', {
          show_ignored = true,
        }, function() delivered = delivered + 1 end)

        assert(#calls == 2, 'Git 工作树阶段必须启动 tracked 和 untracked 扫描')
        calls[1].callback({ code = 0, stdout = 'tracked\0' })
        calls[2].callback({ code = 0, stdout = '' })
        assert(#calls == 3, 'ignored 扫描必须仅在工作树阶段完成后启动')

        local original_stat = vim.uv.fs_stat
        vim.uv.fs_stat = function(path)
          if path == '/repo/nested/.git' then return { type = 'directory' } end
          return original_stat(path)
        end
        calls[3].callback({ code = 0, stdout = 'nested/\0' })
        vim.uv.fs_stat = original_stat
        assert(#calls == 5, '嵌套仓库扫描必须动态注册')

        cancel()
        assert(calls[4].kills == 1 and calls[5].kills == 1,
          '取消必须终止两个嵌套仓库生产者')
        calls[4].callback({ code = 0, stdout = 'late\0' })
        calls[5].callback({ code = 0, stdout = '' })
        assert(delivered == 0, '取消后的嵌套回调不得完成流水线')
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
          '过滤构建必须收容生产者创建失败')
        assert(first.kills == 1, '第二个过滤生产者启动失败必须回滚第一个')
        assert(notifications == 1, '过滤构建失败必须只报告一次')
      end

      do
        Git.root = function() return '' end
        local calls = fake_system({ synchronous = true, result = { code = 0, stdout = 'sync.txt\n' } })
        local delivered = 0
        local _, cancel = require('vv-explorer.filter.index').build('/sync', {}, function()
          delivered = delivered + 1
        end)
        assert(delivered == 1, '同步生产者完成必须发布一次')
        cancel()
        assert(calls[1].kills == 0, '迟到取消不得终止已完成生产者')
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
        assert(explorer_buf, '必须打开真实 explorer 面板 buffer')
        local start_filter = vim.fn.maparg('/', 'n', false, true).callback
        assert(type(start_filter) == 'function', '真实 / 映射必须提供过滤动作')
        start_filter()
        assert(#calls == 1, '真实 / 映射必须启动 fd 索引生产者')

        vim.api.nvim_buf_delete(explorer_buf, { force = true })
        assert(calls[1].kills == 1, 'BufWipeout 释放所有者必须物理终止 fd')
        local callback_ok = pcall(calls[1].callback, { code = 0, stdout = 'late.lua\n' })
        assert(callback_ok, '面板 wipe 后迟到 fd 回调必须无害')
        assert(#calls == 1, '面板 wipe 后迟到回调不得派生更多生产者')
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
        assert(active_handle.kills == 1, '动作层构建失败必须释放已启动生产者')
        assert(failure_state.filter.index_building == false and failure_state.filter.index_root == nil,
          '动作层构建失败不得留下 pending 过滤所有者')

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
        assert(#dynamic_calls == 2, '动态流水线必须启动 tracked 与 untracked 生产者')
        dynamic_calls[1].callback({ code = 0, stdout = '' })
        dynamic_calls[2].callback({ code = 0, stdout = '' })
        assert(#dynamic_calls == 3, 'ignored 生产者必须在工作树阶段后启动')

        local original_stat = vim.uv.fs_stat
        vim.uv.fs_stat = function(path)
          if path == '/dynamic/nested/.git' then return { type = 'directory' } end
          return original_stat(path)
        end
        local callback_ok = pcall(dynamic_calls[3].callback, { code = 0, stdout = 'nested/\0' })
        vim.uv.fs_stat = original_stat

        assert(callback_ok, '嵌套动态启动失败不得逃出 scheduled 回调')
        assert(dynamic_spawns == 5 and dynamic_calls[4].kills == 1,
          '嵌套动态启动失败必须取消此前刚启动的生产者')
        assert(dynamic_state.filter.index == nil and dynamic_state.filter.index_building == false,
          '嵌套动态启动失败不得发布部分索引或停留在构建态')
        assert(dynamic_state.filter.index_root == nil and dynamic_state.filter.active == false,
          '嵌套动态启动失败必须终结并清空动作所有者')
        dynamic_calls[4].callback({ code = 0, stdout = 'late\0' })
        assert(dynamic_errors == 1 and dynamic_state.filter.index == nil,
          '动态失败必须只报告一次并抑制迟到生产者结果')

        Git.root = function() return '' end
        local recovery_calls = fake_system()
        M.start_filter(dynamic_state)
        assert(#recovery_calls == 1, '动态失败后动作请求通道必须仍可复用')
        recovery_calls[1].callback({ code = 0, stdout = 'recovered.txt\n' })
        assert(vim.deep_equal(dynamic_state.filter.index, { '/dynamic/recovered.txt' }),
          '动态失败清理后新请求必须能发布结果')

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
          '根目录切换必须先物理取消旧构建再启动新构建')

        calls[2].callback({ code = 0, stdout = 'new.txt\n' })
        assert(vim.deep_equal(old_filter.index, { '/new/new.txt' }), '新构建必须发布结果')
        calls[1].callback({ code = 0, stdout = 'old.txt\n' })
        assert(vim.deep_equal(old_filter.index, { '/new/new.txt' }),
          '根目录切换后慢 A 不得覆盖快 B')

        H.invalidate_filter_index(state)
        assert(old_filter.index == nil and old_filter.index_building == false,
          '显式失效必须清空已构建索引')

        M.start_filter(state)
        assert(#calls == 3)
        M.clear_filter(state)
        assert(calls[3].kills == 1 and old_filter.index_building == false,
          '关闭活动过滤必须取消在途索引构建')
        calls[3].callback({ code = 0, stdout = 'queued.txt\n' })
        assert(old_filter.index == nil, 'clear 后排队回调必须保持抑制')

        M.start_filter(state)
        assert(#calls == 4, 'clear 后所有者作用域必须仍可复用')
        calls[4].callback({ code = 0, stdout = 'latest.txt\n' })
        assert(vim.deep_equal(old_filter.index, { '/new/latest.txt' }),
          '旧清理不得使后继请求失效')

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
          '同步完成必须在迟到取消句柄接入前终结请求')
        assert(sync_calls[1].kills == 0,
          '同步完成后接入取消句柄不得终止已完成生产者')
      end
    end, debug.traceback)

    restore()
    assert(ok, err)
  end)
end

return T

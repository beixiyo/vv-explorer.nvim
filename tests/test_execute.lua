local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["执行计划向 Lua 与终端传递 cwd，启动失败明确报告"] = function()
  child.lua_func(function()
    -- Explorer 执行计划的 cwd 传递回归测试

    for _, name in ipairs({
      'vv-explorer.tree',
      'vv-explorer.render',
      'vv-explorer.preview.main_win',
      'vv-explorer.preview',
      'vv-explorer.trash',
      'vv-utils.editor',
      'vv-utils.fs',
      'vv-utils.scroll',
    }) do
      package.preload[name] = function() return {} end
    end

    package.preload['vv-utils.exec'] = function()
      return {
        resolve = function()
          return {
            cmd = { 'cargo', 'run' },
            runner = 'cargo',
            cwd = vim.g.vv_explorer_execute_cwd,
          }
        end,
      }
    end

    package.preload['vv-explorer.execute_confirm'] = function()
      return {
        open = function(_, _, _, on_confirm)
          on_confirm()
        end,
      }
    end

    local Navigation = require('vv-explorer.actions.navigation')
    local Actions = {}
    Navigation.attach(Actions, {
      node_under_cursor = function(state) return state.node end,
    })

    local cwd = vim.fn.tempname()
    assert(vim.fn.mkdir(cwd, 'p') == 1, '必须创建测试 cwd')
    vim.g.vv_explorer_execute_cwd = cwd
    local received
    Actions.execute({
      node = { path = cwd .. '/src/main.rs', is_dir = false },
      opts = {
        execute = {
          run = function(cmd, ctx)
            received = { cmd = cmd, ctx = ctx }
          end,
        },
      },
    })

    assert(received, '自定义执行器必须收到解析后的计划')
    assert(vim.deep_equal(received.cmd, { 'cargo', 'run' }), 'Explorer 必须保留命令 argv')
    assert(received.ctx.cwd == cwd, 'Explorer 必须优先使用项目 cwd 而非源文件目录')
    assert(received.ctx.runner == 'cargo', 'Explorer 必须保留执行器 metadata')

    local notifications = {}
    local notify = vim.notify
    vim.notify = function(message)
      notifications[#notifications + 1] = message
    end

    vim.g.vv_explorer_execute_cwd = cwd .. '/removed-before-confirm'
    local failed_runner_called = false
    Actions.execute({
      node = { path = cwd .. '/src/main.rs', is_dir = false },
      opts = {
        execute = {
          confirm = false,
          run = function()
            failed_runner_called = true
          end,
        },
      },
    })
    assert(not failed_runner_called, 'cwd 不可用时不得启动执行器')
    assert(#notifications == 1 and notifications[1]:find('working directory does not exist', 1, true),
      'cwd 不可用必须报告且不抛错')

    vim.g.vv_explorer_execute_cwd = cwd
    local original_jobstart = vim.fn.jobstart
    vim.fn.jobstart = function() return -1 end
    Actions.execute({
      node = { path = cwd .. '/src/main.rs', is_dir = false },
      opts = { execute = { confirm = false } },
    })
    vim.fn.jobstart = original_jobstart
    assert(#notifications == 2 and notifications[2]:find('could not start runner', 1, true),
      'jobstart 失败必须报告且不抛错')

    vim.notify = notify
    vim.g.vv_explorer_execute_cwd = nil
    vim.fn.delete(cwd, 'd')
  end)
end

return T

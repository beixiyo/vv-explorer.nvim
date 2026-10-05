local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["连续执行、root 代际与源窗口关闭取消旧确认"] = function()
  child.lua_func(function()
    -- 执行确认生命周期回归：连续 execute、面板关闭与 root 代际校验

    local root = vim.env.VV_TEST_REPO

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

    local confirmations = {}
    package.preload['vv-utils.exec'] = function()
      return {
        resolve = function(path)
          return {
            cmd = { 'runner', path },
            runner = 'runner',
            cwd = vim.g.vv_explorer_execute_lifecycle_cwd,
            target = 'file',
          }
        end,
      }
    end
    package.preload['vv-explorer.execute_confirm'] = function()
      return {
        open = function(path, cwd, command, on_confirm, opts)
          local confirmation = {
            path = path,
            cwd = cwd,
            command = command,
            opts = opts,
            on_confirm = on_confirm,
            close_count = 0,
          }
          confirmations[#confirmations + 1] = confirmation
          return {
            close = function()
              confirmation.close_count = confirmation.close_count + 1
            end,
          }
        end,
      }
    end

    local Navigation = require('vv-explorer.actions.navigation')
    local Actions = {}
    Navigation.attach(Actions, {
      node_under_cursor = function(state) return state.node end,
    })

    local cwd = vim.fn.tempname()
    assert(vim.fn.mkdir(cwd, 'p') == 1, '执行 cwd 必须成功创建')
    vim.g.vv_explorer_execute_lifecycle_cwd = cwd

    local source_buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, source_buffer)
    local state
    state = {
      buf = source_buffer,
      win = vim.api.nvim_get_current_win(),
      root = { path = cwd },
      node = { path = cwd .. '/first.lua', is_dir = false },
      opts = {
        execute = {
          run = function(_, ctx)
            state.runs = (state.runs or 0) + 1
            state.last_ctx = ctx
          end,
        },
      },
    }

    -- 连续 execute 使用同一个确认槽位，旧确认的回调必须成为 no-op
    Actions.execute(state)
    local first = confirmations[#confirmations]
    state.node = { path = cwd .. '/second.lua', is_dir = false }
    Actions.execute(state)
    local second = confirmations[#confirmations]
    assert(first ~= second, '每次执行必须创建独立确认请求')
    assert(first.close_count == 1, '最新执行必须关闭旧确认框')
    first.on_confirm()
    assert((state.runs or 0) == 0, '被取代的执行回调不得运行')
    second.on_confirm()
    local function assert_equal(actual, expected, message)
      if actual ~= expected then error(('%s：期望 %s，实际 %s'):format(message, expected, actual)) end
    end
    assert_equal(state.runs, 1, '最新执行必须恰好运行一次')
    assert(state.last_ctx.path == cwd .. '/second.lua', '最新执行必须保留源上下文')

    -- root A→B→A 仍然是不同代际，旧执行确认不得落地
    state.node = { path = cwd .. '/third.lua', is_dir = false }
    Actions.execute(state)
    local root_stale = confirmations[#confirmations]
    state.root = { path = cwd .. '/b' }
    state.root = { path = cwd }
    root_stale.on_confirm()
    assert(state.runs == 1, 'A→B→A 必须使旧执行确认失效')

    -- 源窗口关闭时 watcher 取消确认，即使持有的 callback 被误触发也不执行
    local base_window = vim.api.nvim_get_current_win()
    vim.cmd('vsplit')
    local source_window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(source_window, source_buffer)
    state.win = source_window
    state.node = { path = cwd .. '/fourth.lua', is_dir = false }
    Actions.execute(state)
    local window_stale = confirmations[#confirmations]
    vim.api.nvim_set_current_win(base_window)
    vim.api.nvim_win_close(source_window, true)
    window_stale.on_confirm()
    assert(state.runs == 1, '源窗口关闭必须取消执行确认')
    assert(window_stale.close_count == 1, '源窗口取消必须恰好关闭执行确认一次')

    vim.api.nvim_win_set_buf(base_window, source_buffer)
    vim.fn.delete(cwd, 'rf')
  end)
end

return T

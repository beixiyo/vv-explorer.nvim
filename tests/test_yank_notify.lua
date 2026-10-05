local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["路径复制默认静默、配置开启成功提示并拒绝非法配置"] = function()
  child.lua_func(function()
    -- Y 复制路径的提示契约：默认成功静默，yank_notify = true 恢复成功提示，非法配置在 setup 边界报错

    -- 假剪贴板 provider：走真实 setreg('+') 链路，同时记录写入内容
    local clipboard = {}
    vim.g.clipboard = {
      name = 'test',
      copy = {
        ['+'] = function(lines) clipboard[#clipboard + 1] = table.concat(lines, '\n') end,
        ['*'] = function() end,
      },
      paste = {
        ['+'] = function() return {} end,
        ['*'] = function() return {} end,
      },
    }

    local notified = {}
    vim.notify = function(msg, level) notified[#notified + 1] = { msg = msg, level = level } end

    local Config = require('vv-explorer.config')

    local H = {
      ensure_state_fields = function(state) state.selection = state.selection or {} end,
      selected_paths = function(state) return state.selected_paths or {} end,
      node_under_cursor = function(state) return state.cursor_node end,
    }
    local Actions = {}
    require('vv-explorer.actions.navigation').attach(Actions, H)

    local function yank(opts, state)
      clipboard, notified = {}, {}
      state.opts = Config.resolve(opts)
      Actions.yank_abs_path(state)
    end

    do
      yank(nil, { cursor_node = { path = '/tmp/project/a.lua' } })
      assert(clipboard[1] == '/tmp/project/a.lua', '路径未写入剪贴板：' .. vim.inspect(clipboard))
      assert(#notified == 0, '默认复制必须静默，实际：' .. vim.inspect(notified))
    end

    do
      yank({}, { selected_paths = { '/tmp/a', '/tmp/b' } })
      assert(clipboard[1] == '/tmp/a\n/tmp/b', '选中路径未写入：' .. vim.inspect(clipboard))
      assert(#notified == 0, '默认多选复制必须静默，实际：' .. vim.inspect(notified))
    end

    do
      yank({ yank_notify = true }, { cursor_node = { path = '/tmp/project/a.lua' } })
      assert(clipboard[1] == '/tmp/project/a.lua', '路径未写入剪贴板')
      assert(#notified == 1 and notified[1].msg == 'Copied: /tmp/project/a.lua',
        'yank_notify 必须报告成功，实际：' .. vim.inspect(notified))

      yank({ yank_notify = true }, { selected_paths = { '/tmp/a', '/tmp/b' } })
      assert(#notified == 1 and notified[1].msg == 'Copied: /tmp/a\n/tmp/b',
        'yank_notify 必须报告多选成功，实际：' .. vim.inspect(notified))
    end

    do
      local ok, err = pcall(Config.resolve, { yank_notify = 'all' })
      assert(not ok and tostring(err):find('yank_notify must be a boolean', 1, true),
        '非法 yank_notify 必须被拒绝，实际：' .. tostring(err))
    end
  end)
end

return T

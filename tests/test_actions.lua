local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["展开、聚焦、创建与改名经过 actions 接线并按顺序同步 buffer"] = function()
  child.lua_func(function()
    -- actions facade 的行为回归测试

    local root = vim.env.VV_TEST_REPO

    local calls = {
      copy = {},
      expand = {},
      focus = {},
      rename = {},
      sync = {},
      order = {},
      refresh = 0,
      render = 0,
    }
    local shared_record
    local state_subscriber
    local unsubscribe_count = 0

    local Helpers = {}

    function Helpers.node_under_cursor(state) return state.cursor_node end
    function Helpers.row_under_cursor(state) return state.row end
    function Helpers.row_at_line(state) return state.row end
    function Helpers.selected_paths(state) return state.selected_paths or {} end
    function Helpers.ensure_state_fields(state) state.selection = state.selection or {} end
    function Helpers.invalidate_filter_index() end
    function Helpers.focus_path(_, path) calls.focus[#calls.focus + 1] = path end
    function Helpers.node_at_line() end
    function Helpers.find_row() end
    function Helpers.expand_to_file() end

    package.preload['vv-explorer.actions.helpers'] = function() return Helpers end
    package.preload['vv-explorer.actions.navigation'] = function()
      return {
        attach = function(Actions)
          function Actions.open() end
        end,
      }
    end
    package.preload['vv-explorer.actions.filter'] = function()
      return { attach = function() end }
    end
    package.preload['vv-explorer.tree'] = function()
      return {
        refresh = function() calls.refresh = calls.refresh + 1 end,
        expand_to = function(_, path) calls.expand[#calls.expand + 1] = path end,
      }
    end
    package.preload['vv-explorer.render'] = function()
      return { render = function() calls.render = calls.render + 1 end }
    end
    package.preload['vv-explorer.preview'] = function()
      return { clear_if_deleted = function() end }
    end
    package.preload['vv-explorer.trash'] = function()
      return {
        enabled = function() return false end,
        trash = function() return { trashed = {}, failed = {} } end,
      }
    end
    package.preload['vv-explorer.lsp'] = function()
      return {
        will_rename_clients = function() return {} end,
        did_rename = function() end,
      }
    end
    package.preload['vv-utils.loading'] = function()
      return { mark = function() return { stop = function() end } end }
    end
    package.preload['vv-utils.state'] = function()
      return {
        register = function()
          return {
            get = function() return vim.deepcopy(shared_record) end,
            set = function(_, _, value) shared_record = vim.deepcopy(value) return true end,
            remove = function() shared_record = nil return true end,
            compare_and_set = function(_, _, expected, value)
              if not vim.deep_equal(shared_record, expected) then return false, vim.deepcopy(shared_record) end
              shared_record = vim.deepcopy(value)
              return true, vim.deepcopy(shared_record)
            end,
            subscribe = function(_, _, callback)
              state_subscriber = callback
              local active = true
              return function()
                if not active then return end
                active = false
                unsubscribe_count = unsubscribe_count + 1
                state_subscriber = nil
              end
            end,
          }
        end,
      }
    end
    package.preload['vv-utils.modal'] = function()
      return { open = function() error('modal should not open in this test') end }
    end
    local RealFs = require('vv-utils.fs')
    package.loaded['vv-utils.fs'] = {
      unique_dest = RealFs.unique_dest,
      copy = function(source, dest)
        calls.copy[#calls.copy + 1] = { source = source, dest = dest }
        return RealFs.copy(source, dest)
      end,
      rename = function(source, dest)
        calls.order[#calls.order + 1] = 'rename'
        calls.rename[#calls.rename + 1] = { source = source, dest = dest }
        return RealFs.rename(source, dest)
      end,
      sync_buffers = function(source, dest)
        calls.sync[#calls.sync + 1] = { source = source, dest = dest }
      end,
      close_stale_buffers = function(path)
        local closed = RealFs.close_stale_buffers(path)
        if #closed > 0 then calls.order[#calls.order + 1] = 'close_stale' end
        return closed
      end,
      mkdir_p = RealFs.mkdir_p,
      create_file = RealFs.create_file,
      delete = RealFs.delete,
      realpath = RealFs.realpath,
      exists = RealFs.exists,
    }

    vim.notify = function() end

    local Actions = require('vv-explorer.actions')

    local function assert_equal(actual, expected, message)
      if actual ~= expected then
        error(('%s：期望 %s，实际 %s'):format(message, vim.inspect(expected), vim.inspect(actual)))
      end
    end

    local root_node = { path = '/project', name = 'project', is_dir = true }
    local first = { path = '/project/a', name = 'a', is_dir = true, parent = root_node }
    local second = { path = '/project/a/b', name = 'b', is_dir = true, parent = first }
    local tip = { path = '/project/a/b/c', name = 'c', is_dir = true, parent = second }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'a/b/c' })

    local state = {
      root = root_node,
      cursor_node = tip,
      row = { group_chain = { 'a', 'b', 'c' } },
      buf = buf,
      win = vim.api.nvim_get_current_win(),
      name_cols = { [1] = 0 },
      selection = {},
      opts = { clipboard = { conflict = 'increment' } },
    }

    Actions.copy_mark(state)
    assert_equal(state.clipboard.paths[1], tip.path, '折叠链默认选中最深节点')

    Actions.subscribe_clipboard(state)
    local renders_before_remote_clear = calls.render
    shared_record = nil
    state_subscriber(nil)
    assert_equal(state.clipboard, nil, '其他实例清除共享记录后应移除当前标记')
    assert_equal(calls.render, renders_before_remote_clear + 1, '其他实例清除共享记录后应重新渲染')
    Actions.unsubscribe_clipboard(state)
    Actions.unsubscribe_clipboard(state)
    assert_equal(unsubscribe_count, 1, '剪贴板订阅释放必须幂等')

    state.clipboard = nil
    Actions.chain_select_shallower(state)
    local chain_marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace('vv-explorer.chain_sel'), 0, -1, { details = true })
    assert_equal(#chain_marks, 1, '折叠链选段应画出一个高亮')
    assert_equal(chain_marks[1][4].hl_group, 'VVExplorerChainSelected', '折叠链选段使用独立的当前项高亮组')
    assert_equal(chain_marks[1][4].end_col, #'a/b', '折叠链向浅一层后高亮覆盖到所选层级')
    Actions.copy_mark(state)
    assert_equal(state.clipboard.paths[1], second.path, '折叠链向浅一层后操作对应真实节点')

    state.clipboard = { mode = 'copy', paths = { first.path } }
    shared_record = { version = 1, id = 'self', mode = 'copy', paths = { first.path }, created_at = 1 }
    Actions.paste(state)
    assert_equal(#calls.copy, 0, '不能把目录复制到自身子树')
    assert_equal(state.clipboard.paths[1], first.path, '全部粘贴失败时保留剪贴板')

    state.cursor_node = root_node
    state.row = {}
    -- macOS 的 tempname 位于 /var（指向 /private/var 的符号链接），先解析真实路径，避免与被测代码的 realpath 结果不一致
    local temporary = vim.fn.tempname()
    assert(vim.fn.mkdir(temporary, 'p') == 1)
    temporary = assert(vim.uv.fs_realpath(temporary))
    assert(vim.fn.mkdir(temporary .. '/project', 'p') == 1)
    vim.fn.writefile({ 'source' }, temporary .. '/source.txt')
    vim.fn.writefile({ 'existing' }, temporary .. '/project/source.txt')
    state.root = { path = temporary .. '/project', name = 'project', is_dir = true }
    state.cursor_node = state.root
    shared_record = {
      version = 1,
      id = 'copy',
      mode = 'copy',
      paths = { temporary .. '/source.txt' },
      created_at = 1,
    }
    Actions.paste(state)
    assert_equal(#calls.copy, 1, '合法粘贴执行一次复制')
    assert(calls.copy[1].dest:match('/project/%.source %(copy%).txt%.vv%-explorer%-stage%-'),
      '合法粘贴应先复制到目标旁的隐藏 staging 路径')
    assert_equal(calls.rename[#calls.rename].dest, temporary .. '/project/source (copy).txt',
      '合法粘贴应原子发布到唯一目标路径')
    assert_equal(state.clipboard, nil, '复制粘贴成功后清除共享剪贴板')
    assert_equal(calls.focus[#calls.focus], temporary .. '/project/source (copy).txt', '粘贴成功后聚焦目标')

    vim.fn.writefile({ 'move' }, temporary .. '/move.txt')
    shared_record = {
      version = 1,
      id = 'cut',
      mode = 'cut',
      paths = { temporary .. '/move.txt' },
      created_at = 1,
    }
    Actions.paste(state)
    assert_equal(calls.rename[#calls.rename].source, temporary .. '/move.txt', '剪切粘贴移动原始来源')
    assert_equal(calls.rename[#calls.rename].dest, temporary .. '/project/move.txt', '剪切粘贴发布到目标路径')
    assert_equal(#calls.sync, 1, '剪切粘贴同步已加载 buffer 路径')

    vim.fn.writefile({ 'drop' }, temporary .. '/drop.txt')
    vim.fn.writefile({ 'existing drop' }, temporary .. '/project/drop.txt')
    Actions.drop_into(state, { state.root.path, temporary .. '/drop.txt' }, state.root.path)
    assert_equal(#calls.copy, 2, '拖放跳过目标目录自身并继续复制其他文件')
    assert_equal(calls.rename[#calls.rename].dest, temporary .. '/project/drop (copy).txt', '拖放同样发布到唯一目标路径')

    -- r 重命名：目标路径上残留的过期 buffer（未修改、文件已删除）必须在改名前关掉，否则它占着 buffer 名，
    -- 源 buffer 无法改名过去；也会被 LSP 当成已打开的文档
    vim.fn.writefile({ 'ren' }, temporary .. '/project/ren.txt')
    vim.fn.writefile({ 'ghost' }, temporary .. '/project/ren2.txt')
    local stale = vim.fn.bufadd(temporary .. '/project/ren2.txt')
    vim.fn.bufload(stale)
    assert(os.remove(temporary .. '/project/ren2.txt'))
    state.cursor_node = { path = temporary .. '/project/ren.txt', name = 'ren.txt', is_dir = false, parent = state.root }
    local original_input = vim.ui.input
    vim.ui.input = function(_, on_confirm) on_confirm('ren2.txt') end
    calls.order = {}
    Actions.rename(state)
    vim.ui.input = original_input
    assert(not vim.api.nvim_buf_is_valid(stale), 'r 重命名前应关掉目标路径上的过期 buffer')
    assert_equal(table.concat(calls.order, ','), 'close_stale,rename', '过期 buffer 必须在磁盘改名之前关掉')
    assert_equal(calls.rename[#calls.rename].dest, temporary .. '/project/ren2.txt', 'r 重命名应发布到目标路径')

    vim.fn.delete(temporary, 'rf')
  end)
end

return T

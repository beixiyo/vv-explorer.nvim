-- 树导航：open/close_node/toggle_hidden/cd/yank/split/scroll + 选区 + escape

local Tree = require('vv-explorer.tree')
local Render = require('vv-explorer.render')
local Preview = require('vv-explorer.preview')
local Trash = require('vv-explorer.trash')
local Editor = require('vv-utils.editor')
local Fs = require('vv-utils.fs')
local Scroll = require('vv-utils.scroll')

local L = {}

---@param M table
---@param H table
function L.attach(M, H)
  local function open_dir_from_filter_view(state, node)
    M.clear_filter(state)
    Tree.expand_to(state.root, node.path)
    local dir_node = Tree.find(state.root, node.path)
    if dir_node and dir_node.is_dir then dir_node.open = true end
    Render.render(state)
    H.focus_path(state, node.path)
  end

  -- 切根统一收尾（cd_to / cd_up 共用），三件事缺一不可：
  --   1. git 索引是 scope=true（只扫 root 当前范围），换根后旧索引不再适用，必须重跑
  --   2. sync_cwd_on_cd → 把 cwd 同步到新根：telescope / grep / :terminal / 关着面板时的
  --      vv-git 都读 getcwd()，靠它跟随。默认 'tab'（tcd，只影响 explorer 所在 tab）
  --   3. 广播 User VVExplorerRootChanged：cwd 改不动「已经开着」的面板（它们持有自己的
  --      root 字段），故再发一次事件让 vv-git 这类消费者即时切仓库重载
  ---@param state table
  local function after_root_change(state)
    if state.git and state.git.refresh then state.git.refresh() end

    local root = state.root.path
    local scope = state.opts.sync_cwd_on_cd
    if scope ~= false then
      local chdir = (scope == 'global') and vim.cmd.cd or vim.cmd.tcd
      pcall(chdir, vim.fn.fnameescape(root))
    end

    vim.api.nvim_exec_autocmds('User', {
      pattern = 'VVExplorerRootChanged',
      data = { root = root },
    })
  end

  local function toggle_dir(state, node)
    node.open = not node.open
    if node.open then Tree.ensure_scanned(node) end
    Render.render(state)
  end

  local function open_file(state, node)
    if H.is_binary(node.path, state.opts) then
      require('vv-utils.sys').open_default(node.path)
      return
    end
    local main = Preview.find_main_win(state.win)
    if not main then
      Preview.discard(state)
      H.open_in_explorer_split(state, 'rightbelow vsplit', node.path)
      return
    end
    vim.api.nvim_set_current_win(main)
    local prev_buf = Preview.prepare_main_win(main)
    local cur = vim.api.nvim_buf_get_name(0)
    -- 经符号链接打开的文件 buffer 名是 realpath 解析形，而 fnamemodify(':p') 不解析
    -- 链接，直接字符串比对会误判「未打开」并重跑 :edit（脏 buffer 触发 E37）
    -- 两侧统一到 realpath 空间，与本仓库其余 symlink 等价判断（Fs.realpath）一致
    if Fs.realpath(cur) ~= Fs.realpath(node.path) then
      vim.cmd('edit ' .. vim.fn.fnameescape(node.path))
      require('vv-utils.bufdelete').wipe_if_throwaway(prev_buf)
    end
    -- 切到目标文件「之后」结算预览：升级真正打开的 buffer、丢弃指向其他文件的陈旧预览，
    -- 不会把已从分组删除（<leader>bd）的 buffer 顺手 promote 复原
    Preview.commit(state, main)
  end

  function M.open(state)
    local node = H.node_under_cursor(state)
    if not node then return end
    if state.filter and state.filter.active and node.is_dir then
      return open_dir_from_filter_view(state, node)
    end
    if node.is_dir then return toggle_dir(state, node) end
    open_file(state, node)
  end

  function M.close_node(state)
    local node = H.node_under_cursor(state)
    if not node then return end
    if node.is_dir and node.open then
      node.open = false
      Render.render(state)
      return
    end
    if node.parent and node.parent ~= state.root then
      node.parent.open = false
      Render.render(state)
      H.focus_path(state, node.parent.path)
    end
  end

  function M.toggle_hidden(state)
    state.opts.hidden = not state.opts.hidden
    H.invalidate_filter_index(state)
    Render.render(state)
    vim.notify('vv-explorer: hidden = ' .. tostring(state.opts.hidden))
  end

  function M.refresh(state)
    Tree.refresh(state.root)
    H.invalidate_filter_index(state)
    if state.git and state.git.refresh then state.git.refresh() end
    Render.render(state)
  end

  function M.yank_abs_path(state)
    H.ensure_state_fields(state)
    local paths = H.selected_paths(state)
    if #paths > 0 then
      Editor.copy(table.concat(paths, '\n'), { title = 'vv-explorer' })
      return
    end
    local node = H.node_under_cursor(state)
    if not node then return end
    Editor.copy_path({ path = node.path, title = 'vv-explorer' })
  end

  local function open_in(state, cmd)
    local node = H.node_under_cursor(state)
    if not node or node.is_dir then return end
    if H.is_binary(node.path, state.opts) then
      require('vv-utils.sys').open_default(node.path)
      return
    end
    -- 在分屏（新窗口）打开 → 丢弃 main 里的悬停预览，不顺手 promote 旧预览
    Preview.discard(state)
    local main = Preview.find_main_win(state.win)
    if main and vim.api.nvim_win_is_valid(main) then
      vim.api.nvim_set_current_win(main)
      Preview.prepare_main_win(main)
      vim.cmd(cmd .. ' ' .. vim.fn.fnameescape(node.path))
    else
      H.open_in_explorer_split(state, cmd, node.path)
    end
  end

  function M.open_split(state) open_in(state, 'split') end
  function M.open_vsplit(state) open_in(state, 'vsplit') end

  function M.system_open(state)
    local node = H.node_under_cursor(state)
    if not node then return end
    require('vv-utils.sys').open_default(node.path)
  end

  -- 按文件类型执行光标文件：vv-utils.exec 决定命令 → 确认 → 跑（默认分屏终端，可配 run 覆盖）
  function M.execute(state)
    local cfg = state.opts.execute or {}
    if cfg.enabled == false then return end

    local node = H.node_under_cursor(state)
    if not node or node.is_dir then return end

    local plan, err = require('vv-utils.exec').resolve(node.path, cfg.opts)
    if not plan then
      vim.notify('vv-explorer: ' .. (err or ('cannot run ' .. node.path)), vim.log.levels.WARN)
      return
    end

    if cfg.confirm ~= false then
      local prompt = 'vv-explorer execute?\n  ' .. table.concat(plan.cmd, ' ')
      if vim.fn.confirm(prompt, '&Yes\n&No', 2) ~= 1 then return end
    end

    local ctx = { path = node.path, cwd = vim.fs.dirname(node.path), runner = plan.runner }
    if type(cfg.run) == 'function' then
      cfg.run(plan.cmd, ctx)
      return
    end

    -- 原生分屏终端（零插件依赖）
    vim.cmd('botright 15new')
    vim.fn.jobstart(plan.cmd, { term = true, cwd = ctx.cwd })
    vim.cmd('startinsert')
  end

  function M.toggle_gitignored(state)
    state.opts.git = state.opts.git or {}
    state.opts.git.show_ignored = not state.opts.git.show_ignored
    H.invalidate_filter_index(state)
    Render.render(state)
    vim.notify('vv-explorer: show_ignored = ' .. tostring(state.opts.git.show_ignored))
  end

  function M.help(state) require('vv-explorer.help').open(state) end

  function M.cd_to(state)
    local node = H.node_under_cursor(state)
    if not node or not node.is_dir then return end
    state.root = Tree.new_root(node.path)
    -- 切根即时失效旧索引（与 after_fs_change 约定一致）；ensure_filter_index 的
    -- root-stamp 校验是兜底，两者并存确保任何改根路径都不会复用旧 root 的索引
    H.invalidate_filter_index(state)
    after_root_change(state)
    Render.render(state)
  end

  function M.cd_up(state)
    local parent = vim.fs.dirname(state.root.path)
    if parent == state.root.path then return end
    state.root = Tree.new_root(parent)
    M.clear_filter(state)
    H.invalidate_filter_index(state)
    after_root_change(state)
    Render.render(state)
  end

  -- ── 选区 ──

  function M.toggle_select(state)
    H.ensure_state_fields(state)
    local node = H.node_under_cursor(state)
    if not node or node == state.root then return end
    if state.selection[node.path] then
      state.selection[node.path] = nil
    else
      state.selection[node.path] = true
    end
    Render.render(state)
    if state.opts.select_move_down ~= false then
      local last = vim.api.nvim_buf_line_count(state.buf)
      local lnum = vim.api.nvim_win_get_cursor(state.win)[1]
      if lnum < last then
        vim.api.nvim_win_set_cursor(state.win, { lnum + 1, 0 })
      end
    end
  end

  function M.clear_selection(state)
    H.ensure_state_fields(state)
    if not next(state.selection) then return end
    state.selection = {}
    Render.render(state)
  end

  function M.escape(state)
    if state.filter and state.filter.active then
      M.clear_filter(state)
      return
    end
    local has_clipboard = state.clipboard and #state.clipboard.paths > 0
    local has_selection = state.selection and next(state.selection)
    if has_clipboard or has_selection then
      state.clipboard = nil
      state.selection = {}
      Render.render(state)
      return
    end
    vim.cmd('VVExplorerClose')
  end

  -- ── 滚动委派 ──

  local SCROLL_LINES = 5

  local function scroll_preview(state, direction)
    if not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
    local target = Preview.find_main_win(state.win)
    if not target or not vim.api.nvim_win_is_valid(target) then return end
    Scroll.window(target, direction * SCROLL_LINES)
  end

  function M.scroll_preview_down(state) scroll_preview(state, 1) end
  function M.scroll_preview_up(state) scroll_preview(state, -1) end

  function M.trash_panel(state) Trash.open_panel(state) end
end

return L

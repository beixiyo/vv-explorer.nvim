-- 树导航：open/close_node/toggle_hidden/cd/yank/split/scroll + 选区 + escape

local Tree = require('vv-explorer.tree')
local Render = require('vv-explorer.render')
local Preview = require('vv-explorer.preview')
local Trash = require('vv-explorer.trash')
local Editor = require('vv-utils.editor')

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
    Preview.promote(state)
    local main = Preview.find_main_win(state.win)
    if not main then
      H.open_in_explorer_split(state, 'rightbelow vsplit', node.path)
      return
    end
    vim.api.nvim_set_current_win(main)
    local prev_buf = vim.api.nvim_get_current_buf()
    local cur = vim.api.nvim_buf_get_name(0)
    if cur ~= vim.fn.fnamemodify(node.path, ':p') then
      vim.cmd('edit ' .. vim.fn.fnameescape(node.path))
      require('vv-utils.bufdelete').wipe_if_throwaway(prev_buf)
    end
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
    Preview.promote(state)
    local main = Preview.find_main_win(state.win)
    if main and vim.api.nvim_win_is_valid(main) then
      vim.api.nvim_set_current_win(main)
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
    -- root-stamp 校验是兜底，两者并存确保任何改根路径都不会复用旧 root 的索引。
    H.invalidate_filter_index(state)
    Render.render(state)
  end

  function M.cd_up(state)
    local parent = vim.fs.dirname(state.root.path)
    if parent == state.root.path then return end
    state.root = Tree.new_root(parent)
    M.clear_filter(state)
    H.invalidate_filter_index(state)
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
  local CE_KEY = vim.api.nvim_replace_termcodes('<C-e>', true, false, true)
  local CY_KEY = vim.api.nvim_replace_termcodes('<C-y>', true, false, true)

  local function scroll_preview(state, keys)
    if not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
    local target = Preview.find_main_win(state.win)
    if not target or not vim.api.nvim_win_is_valid(target) then return end
    local prev = vim.api.nvim_get_current_win()
    local cmd = 'normal! ' .. SCROLL_LINES .. keys
    if prev == target then
      pcall(vim.cmd, cmd)
      return
    end
    pcall(vim.api.nvim_set_current_win, target)
    pcall(vim.cmd, cmd)
    if vim.api.nvim_win_is_valid(prev) then
      pcall(vim.api.nvim_set_current_win, prev)
    end
  end

  function M.scroll_preview_down(state) scroll_preview(state, CE_KEY) end
  function M.scroll_preview_up(state) scroll_preview(state, CY_KEY) end

  function M.trash_panel(state) Trash.open_panel(state) end
end

return L

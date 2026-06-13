-- 过滤操作：start_filter / clear_filter + 内部 prompt 回调与索引管理

local Render = require('vv-explorer.render')
local Preview = require('vv-explorer.preview')
local Filter = require('vv-explorer.filter')
local Prompt = require('vv-explorer.prompt')
local Tree = require('vv-explorer.tree')

local L = {}

---@param M table
---@param H table
function L.attach(M, H)
  local function refilter(state)
    local f = state.filter
    if (f.query or '') == '' then
      f.matched = H.EMPTY_MATCHED
      f.match_count = nil
    elseif not f.index then
      f.matched = H.EMPTY_MATCHED
    else
      if not f.index_rels then
        f.index_rels = Filter.build_rels(f.index, state.root.path)
      end
      f.matched = Filter.match(f.index, f.index_rels, state.root.path, f.query, f.mode, state.opts.filter and state.opts.filter.max_results)
    end
    f.searching = false
    -- 仅在「过滤结果刚变化」时让 render_filter 自动滚到最佳匹配；导航/增量重渲不触发
    f._want_scroll = true
    Render.render(state)
    if f.on_redraw then pcall(f.on_redraw) end
  end

  ---@param state table
  ---@return integer[]
  local function matched_lnums(state)
    local f = state.filter
    if not f then return {} end
    local lnums = {}
    for _, abs in ipairs(f.matched.abs) do
      local l = state.path_to_row and state.path_to_row[abs]
      if l then lnums[#lnums + 1] = l end
    end
    table.sort(lnums)
    return lnums
  end

  ---@param state table
  ---@param dir integer  +1 / -1
  local function filter_navigate(state, dir)
    if not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
    local lnums = matched_lnums(state)
    if #lnums == 0 then return end

    local cur = vim.api.nvim_win_get_cursor(state.win)[1]
    local target
    if dir > 0 then
      for _, l in ipairs(lnums) do
        if l > cur then target = l; break end
      end
      target = target or lnums[1]
    else
      for i = #lnums, 1, -1 do
        if lnums[i] < cur then target = lnums[i]; break end
      end
      target = target or lnums[#lnums]
    end

    pcall(vim.api.nvim_win_set_cursor, state.win, { target, 0 })

    local node = H.node_under_cursor(state)
    if node and not node.is_dir then
      pcall(Preview.preview_file, state, node.path)
    end
  end

  ---@param state table
  ---@param kind 'split'|'vsplit'
  local function filter_open_in(state, kind)
    if not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
    vim.api.nvim_set_current_win(state.win)

    local node = H.node_under_cursor(state)
    if not node or node.is_dir then
      M.clear_filter(state)
      return
    end
    local target_path = node.path

    M.clear_filter(state)
    Tree.expand_to(state.root, target_path)
    Render.render(state)
    H.focus_path(state, target_path)

    if kind == 'split' then
      M.open_split(state)
    elseif kind == 'vsplit' then
      M.open_vsplit(state)
    end
  end

  ---@param state table
  ---@return VVExplorerPromptOpts
  local function make_prompt_callbacks(state)
    local f = state.filter
    return {
      initial = f.query,
      on_change = function(q)
        f.query = q
        refilter(state)
      end,
      on_submit = function(q)
        f.query = q
        refilter(state)
        if state.win and vim.api.nvim_win_is_valid(state.win) then
          vim.api.nvim_set_current_win(state.win)
          local first = f.matched.abs[1]
          if first then H.focus_path(state, first) end
        end
      end,
      on_cancel = function()
        M.clear_filter(state)
        if state.win and vim.api.nvim_win_is_valid(state.win) then
          vim.api.nvim_set_current_win(state.win)
        end
      end,
      on_cycle_mode = function()
        f.mode = Filter.next_mode(f.mode)
        refilter(state)
        return f.mode
      end,
      get_mode = function() return f.mode end,
      on_navigate = function(dir) filter_navigate(state, dir) end,
      on_open_in = function(kind) filter_open_in(state, kind) end,
    }
  end

  ---@param state table
  ---@return boolean ok
  local function ensure_filter_index(state)
    local f = state.filter
    -- 根失效（root-stamp）：索引/rels 是为某个具体 root 建的全树绝对路径，切根后
    -- （cd_to/cd_up 或任何未来改 state.root 的路径）旧索引不再适用。这里统一在
    -- 真正复用旧索引「之前」校验，发现 root 漂移就先失效再重建，使所有改根入口自动正确
    if (f.index or f.index_building) and f.index_root ~= state.root.path then
      H.invalidate_filter_index(state)
    end

    if f.index or f.index_building then return true end

    f.index_building = true
    f.index_root = state.root.path
    -- 用 generation token 标记本次构建：build_index 是异步的（vim.system/git ls-files），
    -- 慢构建可能在切根后才回调，把旧 root 的绝对路径写进新 root 的 f.index 并触发错误
    -- refilter。任何 invalidate_filter_index 都会 bump f.index_gen，使在途旧构建被丢弃
    f.index_gen = (f.index_gen or 0) + 1

    local my_gen = f.index_gen
    local ok = Filter.build_index(state.root.path, {
      hidden = state.opts.hidden,
      show_ignored = state.opts.git and state.opts.git.show_ignored,
      custom = state.opts.filter and state.opts.filter.custom,
    }, function(paths, is_dir_map)
      -- 更新的构建/根已取代本次回调 → 丢弃陈旧结果，绝不污染当前 root 的索引
      if not state.filter or state.filter ~= f or f.index_gen ~= my_gen then return end
      if f.index_root ~= state.root.path then return end

      f.index = paths
      f.is_dir_map = is_dir_map
      f.index_rels = nil
      f.index_building = false

      if f.active then refilter(state) end
    end)
    if not ok then
      f.index_building = false
      f.index_root = nil
      M.clear_filter(state)

      return false
    end
    return true
  end

  function M.start_filter(state)
    state.filter = state.filter or {
      active = false,
      mode = 'fuzzy',
      query = '',
      index = nil,
      index_building = false,
      matched = H.EMPTY_MATCHED,
    }
    state.filter.mode = state.filter.mode or 'fuzzy'
    state.filter.active = true

    if not ensure_filter_index(state) then return end

    refilter(state)
    Prompt.open(state, make_prompt_callbacks(state))
  end

  function M.clear_filter(state)
    if not state.filter or not state.filter.active then return end

    state.filter.active = false
    state.filter.query = ''
    state.filter.matched = H.EMPTY_MATCHED

    Render.render(state)
  end
end

return L

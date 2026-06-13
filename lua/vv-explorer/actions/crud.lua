-- CRUD 操作：create / delete / rename + 剪贴板（cut / copy / paste）

local Tree = require('vv-explorer.tree')
local Render = require('vv-explorer.render')
local Preview = require('vv-explorer.preview')
local Fs = require('vv-utils.fs')
local Trash = require('vv-explorer.trash')
local Lsp = require('vv-explorer.lsp')
local Loading = require('vv-utils.loading')

-- 折叠空目录链「选段」高亮命名空间（C-h/C-l 选层时高亮选中前缀段）
local CHAIN_NS = vim.api.nvim_create_namespace('vv-explorer.chain_sel')

-- 从 tip 节点沿 .parent 上溯到折叠链第 idx 段对应的真实树节点（make_node 已可靠挂 .parent）。
-- 供 create/delete/copy/cut/paste/rename 拿到「选中层级」的节点，而非永远最深的 tip
---@param tip table
---@param chain string[]
---@param idx integer
---@return table
local function chain_node_at(tip, chain, idx)
  local n = tip
  for _ = 1, (#chain - idx) do
    if not n.parent then break end
    n = n.parent
  end
  return n
end

local L = {}

---@param M table
---@param H table
function L.attach(M, H)
  ---@param state table
  ---@param node table?
  ---@return string path
  local function dir_context(state, node)
    if not node or node == state.root then return state.root.path end
    if node.is_dir then return node.path end
    return vim.fs.dirname(node.path)
  end

  ---@param state table
  ---@param cursor_node table?
  ---@return string[]
  local function targets(state, cursor_node)
    local sel = H.selected_paths(state)
    if #sel > 0 then return sel end
    if cursor_node and cursor_node ~= state.root then return { cursor_node.path } end
    return {}
  end

  -- 光标行的「有效操作目标节点」：
  --   * 折叠链行（group_chain>1）→ 按 C-h/C-l 选中的层级节点（未选=最深 tip，等同原行为）
  --   * 普通行 → 本行节点
  -- create/delete/copy/cut/paste/rename 统一走它，让选段高亮贯穿所有单目标操作；
  -- 导航（open/close）不走它，仍作用于显示行(tip)
  ---@param state table
  ---@return table?
  local function target_node(state)
    local node = H.node_under_cursor(state)
    if not node then return nil end
    local row = H.row_under_cursor(state)
    if not row or not row.group_chain or #row.group_chain <= 1 then return node end
    local sel = state._chain_sel
    local lnum = vim.api.nvim_win_get_cursor(state.win)[1]
    local idx = (sel and sel.lnum == lnum) and sel.idx or #row.group_chain
    return chain_node_at(node, row.group_chain, idx)
  end

  ---@param state table
  local function after_fs_change(state)
    Tree.refresh(state.root)
    state.selection = {}
    state._chain_sel = nil
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
      vim.api.nvim_buf_clear_namespace(state.buf, CHAIN_NS, 0, -1)
    end
    H.invalidate_filter_index(state)
    if state.git and state.git.refresh then state.git.refresh() end
    Render.render(state)
  end

  -- 清理已删文件/目录对应的 buffer。
  --
  -- 关键：两侧路径必须走「同一规范化口径」。`nvim_buf_get_name` 对经过符号链接打开的
  -- 文件返回的是「已解析的真实路径」，而 `node.path`（删除目标）是符号链接形式，二者
  -- 字符串不相等。统一用 `Fs.realpath` 把两侧都解析到真实路径再比，避免 symlink 漏命中。
  --
  -- `keys` 由调用方在「删除发生之前」用 Fs.realpath 解析好（删后 symlink/文件已不在，
  -- 无法再解析），每个 key 已去除尾斜杠，指向真实路径。
  ---@param state table
  ---@param keys string[]  已解析为真实路径、去尾斜杠的删除目标
  local function cleanup_deleted_bufs(state, keys)
    local set = {}
    for _, k in ipairs(keys) do set[k] = true end
    Preview.clear_if_deleted(state, set)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        local raw = vim.api.nvim_buf_get_name(buf)
        if raw == '' then goto skip end
        -- buffer name 已是解析形，但仍 normalize 兜底（去重复斜杠等）
        local name = vim.fs.normalize(raw):gsub('/+$', '')
        local hit = set[name]
        if not hit then
          for abs in pairs(set) do
            if name:sub(1, #abs + 1) == abs .. '/' then hit = true; break end
          end
        end
        if hit then
          for _, win in ipairs(vim.fn.win_findbuf(buf)) do
            if win ~= state.win and vim.api.nvim_win_is_valid(win) then
              vim.api.nvim_win_call(win, function() vim.cmd('enew') end)
            end
          end
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
        ::skip::
      end
    end
  end

  -- ── CRUD ──

  function M.create(state)
    H.ensure_state_fields(state)
    local node = H.node_under_cursor(state)
    local base = dir_context(state, node)
    local default = ''

    -- 折叠空目录链（如 test/n1/n2 合并成一行）：把创建基准下移到链顶的父目录，链作为可编辑
    -- 默认值预填。预填长度跟随 C-h/C-l 选中层级（选 n1 → 预填 test/n1/，无需再退格）；
    -- 未选则预填整条链（用户可自行退格选层）
    local row = H.row_under_cursor(state)
    if node and node.is_dir and row and row.group_chain and #row.group_chain > 1 then
      local chain = row.group_chain
      local parent = node.path
      for _ = 1, #chain do parent = vim.fs.dirname(parent) end
      base = parent

      local sel = state._chain_sel
      local lnum = vim.api.nvim_win_get_cursor(state.win)[1]
      local idx = (sel and sel.lnum == lnum) and sel.idx or #chain
      local segs = {}
      for i = 1, idx do segs[i] = chain[i] end
      default = table.concat(segs, '/') .. '/'
    end

    local rel_prompt = vim.fn.fnamemodify(base, ':.')
    if rel_prompt == '' then rel_prompt = '.' end

    vim.ui.input({ prompt = 'New (' .. rel_prompt .. '/): ', default = default, completion = 'file' }, function(name)
      if not name or name == '' then return end
      local is_dir = name:sub(-1) == '/'
      local rel = name:gsub('/$', '')
      local target = vim.fs.normalize(base .. '/' .. rel)

      local ok, err = pcall(function()
        if is_dir then Fs.mkdir_p(target) else Fs.create_file(target) end
      end)
      if not ok then
        vim.notify('vv-explorer: ' .. tostring(err), vim.log.levels.ERROR)
        return
      end

      after_fs_change(state)
      Tree.expand_to(state.root, target)
      Render.render(state)
      H.focus_path(state, target)
      if not is_dir then M.open(state) end
      vim.notify('Created: ' .. vim.fn.fnamemodify(target, ':.'))
    end)
  end

  -- 折叠链选段：C-h/C-l 调整选中层级，高亮选中前缀段，d 时据此精确删除
  ---@param state table
  ---@param delta integer  +1 往深、-1 往浅
  local function chain_select(state, delta)
    if not vim.api.nvim_win_is_valid(state.win) then return end
    local lnum = vim.api.nvim_win_get_cursor(state.win)[1]
    local row = H.row_at_line(state, lnum)
    if not row or not row.group_chain or #row.group_chain <= 1 then return end

    local n = #row.group_chain
    local sel = state._chain_sel
    if not sel or sel.lnum ~= lnum then sel = { lnum = lnum, idx = n } end
    sel.idx = math.min(n, math.max(1, sel.idx + delta))
    state._chain_sel = sel

    -- 高亮选中前缀段：name 起始列 → 第 idx 段结束的字节偏移
    vim.api.nvim_buf_clear_namespace(state.buf, CHAIN_NS, 0, -1)
    local name_col = (state.name_cols and state.name_cols[lnum]) or 0
    local off = 0
    for i = 1, sel.idx do
      off = off + #row.group_chain[i]
      if i < sel.idx then off = off + 1 end
    end
    pcall(vim.api.nvim_buf_set_extmark, state.buf, CHAIN_NS, lnum - 1, name_col, {
      end_col = name_col + off,
      hl_group = 'VVExplorerMatch',
      priority = 200,
    })
  end

  function M.chain_select_deeper(state) chain_select(state, 1) end
  function M.chain_select_shallower(state) chain_select(state, -1) end

  ---@param state table
  function M.chain_sel_clear(state)
    if not state._chain_sel then return end
    state._chain_sel = nil
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
      vim.api.nvim_buf_clear_namespace(state.buf, CHAIN_NS, 0, -1)
    end
  end

  function M.delete(state)
    H.ensure_state_fields(state)
    -- target_node 已处理折叠链选段（无多选时取选中层级）；多选仍由 targets 优先
    local paths = targets(state, target_node(state))
    if #paths == 0 then return end

    local use_trash = Trash.enabled()
    local verb = use_trash and 'Trash' or 'Delete'
    local msg
    if #paths == 1 then
      msg = verb .. ' ' .. vim.fn.fnamemodify(paths[1], ':.') .. ' ?'
    else
      msg = ('%s %d items ?'):format(verb, #paths)
    end
    local choice = vim.fn.confirm(msg, '&Yes\n&No', 2)
    if choice ~= 1 then return end

    -- 删除发生前先把每个目标解析为真实路径（去尾斜杠）：删后 symlink/文件已不在，
    -- 无法再解析。buffer name 是解析形，两侧统一到真实路径才能正确匹配清理。
    local resolved = {}
    for _, p in ipairs(paths) do
      resolved[p] = Fs.realpath(p):gsub('/+$', '')
    end

    local deleted, failed
    if use_trash then
      local result = Trash.trash(paths)
      deleted = result.trashed
      failed = result.failed
    else
      deleted, failed = {}, {}
      for _, p in ipairs(paths) do
        local ok, err = pcall(Fs.delete, p)
        if not ok then
          failed[#failed + 1] = tostring(err)
        else
          deleted[#deleted + 1] = p
        end
      end
    end

    if #failed > 0 then
      vim.notify('vv-explorer: ' .. verb:lower() .. ' errors:\n' .. table.concat(failed, '\n'), vim.log.levels.ERROR)
    else
      local past = use_trash and 'Trashed' or 'Deleted'
      vim.notify(('%s %d item(s)'):format(past, #deleted))
    end
    if #deleted > 0 then
      local keys = {}
      for _, p in ipairs(deleted) do keys[#keys + 1] = resolved[p] end
      cleanup_deleted_bufs(state, keys)
    end
    after_fs_change(state)
  end

  function M.rename(state)
    H.ensure_state_fields(state)
    -- 折叠链行：重命名选中层级节点（未选=最深 tip），node.name/parent 取自真实节点
    local node = target_node(state)
    if not node or node == state.root then return end
    local old = node.path

    vim.ui.input({ prompt = 'Rename: ', default = node.name }, function(new_name)
      if not new_name or new_name == '' or new_name == node.name then return end
      local new_path = vim.fs.normalize(vim.fs.dirname(old) .. '/' .. new_name)
      local timeout_ms = (state.opts and state.opts.lsp_rename_timeout_ms) or 5000

      local function finish_rename()
        local ok, err = pcall(Fs.rename, old, new_path)
        if not ok then
          vim.notify('vv-explorer: ' .. tostring(err), vim.log.levels.ERROR)
          return
        end
        Fs.sync_buffers(old, new_path)
        Lsp.did_rename(old, new_path)
        after_fs_change(state)
        Tree.expand_to(state.root, new_path)
        Render.render(state)
        H.focus_path(state, new_path)
      end

      -- 无支持客户端则直接重命名，不触发 loading / re-render
      if #Lsp.will_rename_clients() == 0 then
        finish_rename()
        return
      end

      -- 标记正在重命名的路径，让 render 跳过该行的 git/diag 图标
      state._lsp_renaming_path = old
      Render.render(state)
      local stop_loading = Loading.start({
        buf     = state.buf,
        get_row = function() return state.path_to_row and state.path_to_row[old] end,
      })

      Lsp.will_rename_async(old, new_path, timeout_ms, function(timed_out)
        stop_loading()
        state._lsp_renaming_path = nil
        if timed_out then
          vim.notify(
            ('vv-explorer: LSP willRenameFiles timed out after %dms, proceeding anyway'):format(timeout_ms),
            vim.log.levels.WARN
          )
        end
        finish_rename()
      end)
    end)
  end

  -- ── 剪贴板 ──

  local function clipboard_mark(state, mode)
    H.ensure_state_fields(state)
    -- 折叠链行：复制/剪切选中层级节点（未选=最深 tip）
    local node = target_node(state)
    local sel = H.selected_paths(state)

    if #sel > 0 then
      state.clipboard = { mode = mode, paths = sel }
      state.selection = {}
    else
      if not node or node == state.root then return end
      local path = node.path
      local cb = state.clipboard
      if cb and cb.mode == mode then
        local idx
        for i, p in ipairs(cb.paths) do
          if p == path then idx = i; break end
        end
        if idx then
          table.remove(cb.paths, idx)
          if #cb.paths == 0 then state.clipboard = nil end
        else
          cb.paths[#cb.paths + 1] = path
        end
      else
        state.clipboard = { mode = mode, paths = { path } }
      end
    end

    Render.render(state)
    local label = mode == 'cut' and 'Cut' or 'Copy'
    local n = state.clipboard and #state.clipboard.paths or 0
    if n > 0 then
      vim.notify(('%s %d item(s)'):format(label, n))
    end
  end

  function M.cut_mark(state) clipboard_mark(state, 'cut') end
  function M.copy_mark(state) clipboard_mark(state, 'copy') end

  function M.paste(state)
    H.ensure_state_fields(state)
    if not state.clipboard or #state.clipboard.paths == 0 then
      vim.notify('vv-explorer: clipboard empty', vim.log.levels.WARN)
      return
    end
    -- 折叠链行：粘贴进选中层级目录（未选=最深 tip）
    local dest_dir = dir_context(state, target_node(state))
    local mode = state.clipboard.mode
    local last_dst

    local failed = {}
    for _, src in ipairs(state.clipboard.paths) do
      if dest_dir == src or dest_dir:sub(1, #src + 1) == src .. '/' then
        failed[#failed + 1] = 'skip: ' .. src .. ' → inside itself'
        goto continue
      end
      local dst = Fs.unique_dest(dest_dir .. '/' .. vim.fs.basename(src))
      local ok, err = pcall(function()
        if mode == 'cut' then
          Fs.rename(src, dst)
          Fs.sync_buffers(src, dst)
        else
          Fs.copy(src, dst)
        end
      end)
      if not ok then
        failed[#failed + 1] = tostring(err)
      else
        last_dst = dst
      end
      ::continue::
    end

    if #failed > 0 then
      vim.notify('vv-explorer: paste errors:\n' .. table.concat(failed, '\n'), vim.log.levels.ERROR)
    end
    -- 仅在确有条目粘贴成功时清剪贴板：若全部被自包含跳过或全部出错（last_dst 为 nil），
    -- 保留 cut/copy 选区，避免用户白丢标记的源（cut 时尤其无法从 explorer 恢复）
    if last_dst then state.clipboard = nil end
    after_fs_change(state)
    if last_dst then
      Tree.expand_to(state.root, last_dst)
      Render.render(state)
      H.focus_path(state, last_dst)
    end
  end

  -- 把 paths 复制进 dest_dir。安全保证：同名一律走 Fs.unique_dest 自增改名，
  -- 绝不删除/覆盖已存在文件或目录（曾因「覆盖=递归删目录」删光真实项目含 .git）。
  ---@param state table
  ---@param paths string[]
  ---@param dest_dir string
  function M.drop_into(state, paths, dest_dir)
    H.ensure_state_fields(state)
    local last_dst
    local done = 0
    local failed = {}

    for _, src in ipairs(paths) do
      -- 落点目录就是 src 自身或落在 src 子树内 → 跳过，避免把目录拷进自己
      if dest_dir == src or dest_dir:sub(1, #src + 1) == src .. '/' then
        failed[#failed + 1] = 'skip: ' .. src .. ' → inside itself'
      else
        local dst = Fs.unique_dest(dest_dir .. '/' .. vim.fs.basename(src))
        local ok, err = pcall(Fs.copy, src, dst)
        if not ok then
          failed[#failed + 1] = tostring(err)
        else
          last_dst = dst
          done = done + 1
        end
      end
    end

    if #failed > 0 then
      vim.notify('vv-explorer: drop errors:\n' .. table.concat(failed, '\n'), vim.log.levels.ERROR)
    elseif done > 0 then
      vim.notify(('Dropped %d item(s) → %s'):format(done, vim.fn.fnamemodify(dest_dir, ':.')))
    end

    after_fs_change(state)
    if last_dst then
      Tree.expand_to(state.root, last_dst)
      Render.render(state)
      H.focus_path(state, last_dst)
    end
  end

  -- 无坐标的拖拽回退（bracketed paste，如 tmux）：复制到光标所在目录
  ---@param state table
  ---@param paths string[]
  function M.drop_paste(state, paths)
    local node = H.node_under_cursor(state)
    M.drop_into(state, paths, dir_context(state, node))
  end
end

return L

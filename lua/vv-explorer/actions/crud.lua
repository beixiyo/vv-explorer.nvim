-- CRUD 操作：create / delete / rename + 剪贴板（cut / copy / paste）

local Tree = require('vv-explorer.tree')
local Render = require('vv-explorer.render')
local Preview = require('vv-explorer.preview')
local Fs = require('vv-utils.fs')
local Trash = require('vv-explorer.trash')

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

  ---@param state table
  local function after_fs_change(state)
    Tree.refresh(state.root)
    state.selection = {}
    if state.filter then
      state.filter.index = nil
      state.filter.index_rels = nil
    end
    if state.git and state.git.refresh then state.git.refresh() end
    Render.render(state)
  end

  ---@param state table
  ---@param paths string[]
  local function cleanup_deleted_bufs(state, paths)
    local set = {}
    for _, p in ipairs(paths) do
      local abs = vim.fn.fnamemodify(p, ':p'):gsub('/+$', '')
      set[abs] = true
    end
    Preview.clear_if_deleted(state, set)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        if name == '' then goto skip end
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
    local rel_prompt = vim.fn.fnamemodify(base, ':.')
    if rel_prompt == '' then rel_prompt = '.' end

    vim.ui.input({ prompt = 'New (' .. rel_prompt .. '/): ', default = '', completion = 'file' }, function(name)
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

  function M.delete(state)
    H.ensure_state_fields(state)
    local node = H.node_under_cursor(state)
    local paths = targets(state, node)
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
    if #deleted > 0 then cleanup_deleted_bufs(state, deleted) end
    after_fs_change(state)
  end

  function M.rename(state)
    H.ensure_state_fields(state)
    local node = H.node_under_cursor(state)
    if not node or node == state.root then return end
    local old = node.path

    vim.ui.input({ prompt = 'Rename: ', default = node.name }, function(new_name)
      if not new_name or new_name == '' or new_name == node.name then return end
      local new_path = vim.fs.normalize(vim.fs.dirname(old) .. '/' .. new_name)

      local ok, err = pcall(Fs.rename, old, new_path)
      if not ok then
        vim.notify('vv-explorer: ' .. tostring(err), vim.log.levels.ERROR)
        return
      end
      Fs.sync_buffers(old, new_path)
      after_fs_change(state)
      Tree.expand_to(state.root, new_path)
      Render.render(state)
      H.focus_path(state, new_path)
    end)
  end

  -- ── 剪贴板 ──

  local function clipboard_mark(state, mode)
    H.ensure_state_fields(state)
    local node = H.node_under_cursor(state)
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
    local node = H.node_under_cursor(state)
    local dest_dir = dir_context(state, node)
    local mode = state.clipboard.mode
    local last_dst

    local failed = {}
    for _, src in ipairs(state.clipboard.paths) do
      if mode == 'cut' and (dest_dir == src or dest_dir:sub(1, #src + 1) == src .. '/') then
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
    state.clipboard = nil
    after_fs_change(state)
    if last_dst then
      Tree.expand_to(state.root, last_dst)
      Render.render(state)
      H.focus_path(state, last_dst)
    end
  end

  function M.drop_paste(state, paths)
    H.ensure_state_fields(state)
    local node = H.node_under_cursor(state)
    local dest_dir = dir_context(state, node)
    local last_dst

    local failed = {}
    for _, src in ipairs(paths) do
      local dst = Fs.unique_dest(dest_dir .. '/' .. vim.fs.basename(src))
      local ok, err = pcall(Fs.copy, src, dst)
      if not ok then
        failed[#failed + 1] = tostring(err)
      else
        last_dst = dst
      end
    end

    if #failed > 0 then
      vim.notify('vv-explorer: drop errors:\n' .. table.concat(failed, '\n'), vim.log.levels.ERROR)
    else
      vim.notify(('Dropped %d item(s) → %s'):format(#paths, vim.fn.fnamemodify(dest_dir, ':.')))
    end
    after_fs_change(state)
    if last_dst then
      Tree.expand_to(state.root, last_dst)
      Render.render(state)
      H.focus_path(state, last_dst)
    end
  end
end

return L

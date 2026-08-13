-- 文件系统 mutation：创建、删除与 LSP 感知的重命名

local Tree = require('vv-explorer.tree')
local Render = require('vv-explorer.render')
local Preview = require('vv-explorer.preview')
local Fs = require('vv-utils.fs')
local Trash = require('vv-explorer.trash')
local Lsp = require('vv-explorer.lsp')
local Loading = require('vv-utils.loading')
local Text = require('vv-explorer.text')
local ConfirmLifecycle = require('vv-explorer.confirm_lifecycle')

local M = {}

local uv = vim.uv or vim.loop

local function stat_snapshot(path)
  local ok, stat = pcall(uv.fs_lstat, path)
  if not ok or not stat then return nil end

  local mtime = stat.mtime or {}
  return {
    dev = stat.dev,
    ino = stat.ino,
    type = stat.type,
    mode = stat.mode,
    size = stat.size,
    mtime_sec = mtime.sec,
    mtime_nsec = mtime.nsec,
  }
end

local function same_stat(first, second)
  if not first or not second then return first == second end

  return first.dev == second.dev
    and first.ino == second.ino
    and first.type == second.type
    and first.mode == second.mode
    and first.size == second.size
    and first.mtime_sec == second.mtime_sec
    and first.mtime_nsec == second.mtime_nsec
end

local function path_snapshot(path)
  local absolute = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  return {
    path = absolute,
    stat = stat_snapshot(absolute),
  }
end

local function target_is_unchanged(snapshot)
  return snapshot.stat ~= nil and same_stat(snapshot.stat, stat_snapshot(snapshot.path))
end

---@param Actions table
---@param H table
---@param context table
function M.attach(Actions, H, context)
  ---@param state table
  ---@param cursor_node table?
  ---@return string[]
  local function targets(state, cursor_node)
    local selected = H.selected_paths(state)
    if #selected > 0 then return selected end
    if cursor_node and cursor_node ~= state.root then return { cursor_node.path } end
    return {}
  end

  ---@param state table
  ---@param keys string[]
  local function cleanup_deleted_bufs(state, keys)
    local deleted_paths = {}
    for _, path in ipairs(keys) do deleted_paths[path] = true end

    Preview.clear_if_deleted(state, deleted_paths)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        local raw = vim.api.nvim_buf_get_name(buf)
        if raw == '' then goto continue end

        local name = vim.fs.normalize(raw):gsub('/+$', '')
        local deleted = deleted_paths[name]
        if not deleted then
          for path in pairs(deleted_paths) do
            if name:sub(1, #path + 1) == path .. '/' then
              deleted = true
              break
            end
          end
        end

        if deleted then
          for _, win in ipairs(vim.fn.win_findbuf(buf)) do
            if win ~= state.win and vim.api.nvim_win_is_valid(win) then
              vim.api.nvim_win_call(win, function() vim.cmd('enew') end)
            end
          end
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end

        ::continue::
      end
    end
  end

  function Actions.create(state)
    H.ensure_state_fields(state)
    local node = H.node_under_cursor(state)
    local base = context.dir_context(state, node)
    local default = ''

    local row = H.row_under_cursor(state)
    if node and node.is_dir and row and row.group_chain and #row.group_chain > 1 then
      local chain = row.group_chain
      local parent = node.path
      for _ = 1, #chain do parent = vim.fs.dirname(parent) end
      base = parent

      local selection = state._chain_sel
      local line = vim.api.nvim_win_get_cursor(state.win)[1]
      local index = selection and selection.lnum == line and selection.idx or #chain
      local segments = {}
      for i = 1, index do segments[i] = chain[i] end
      default = table.concat(segments, '/') .. '/'
    end

    local relative = vim.fn.fnamemodify(base, ':.')
    if relative == '' then relative = '.' end

    vim.ui.input({
      prompt = 'New (' .. relative .. '/): ',
      default = default,
      completion = 'file',
    }, function(name)
      if not name or name == '' then return end

      local is_dir = name:sub(-1) == '/'
      local target = vim.fs.normalize(base .. '/' .. name:gsub('/$', ''))
      local ok, err = pcall(function()
        if is_dir then
          Fs.mkdir_p(target)
        else
          Fs.create_file(target)
        end
      end)
      if not ok then
        vim.notify('vv-explorer: ' .. tostring(err), vim.log.levels.ERROR)
        return
      end

      context.after_fs_change(state)
      Tree.expand_to(state.root, target)
      Render.render(state)
      H.focus_path(state, target)
      if not is_dir then Actions.open(state) end
      vim.notify('Created: ' .. vim.fn.fnamemodify(target, ':.'))
    end)
  end

  function Actions.delete(state)
    H.ensure_state_fields(state)
    ConfirmLifecycle.cancel(state)
    local paths = targets(state, context.target_node(state))
    if #paths == 0 then return end

    local use_trash = Trash.enabled()
    local verb = use_trash and 'Trash' or 'Delete'
    local snapshots = {}
    for _, path in ipairs(paths) do
      local snapshot = path_snapshot(path)
      if not snapshot.stat then
        vim.notify('vv-explorer: delete cancelled: target is no longer available: ' .. path, vim.log.levels.WARN)
        return
      end
      snapshots[#snapshots + 1] = snapshot
    end

    local function perform_delete()
      for _, snapshot in ipairs(snapshots) do
        if not target_is_unchanged(snapshot) then
          vim.notify('vv-explorer: delete cancelled: target changed while confirmation was open', vim.log.levels.WARN)
          return
        end
      end

      local resolved = {}
      for _, snapshot in ipairs(snapshots) do
        resolved[snapshot.path] = Fs.realpath(snapshot.path):gsub('/+$', '')
      end

      local deleted
      local failed
      if use_trash then
        local delete_paths = vim.tbl_map(function(snapshot) return snapshot.path end, snapshots)
        local result = Trash.trash(delete_paths)
        deleted = result.trashed
        failed = result.failed
      else
        deleted = {}
        failed = {}
        for _, snapshot in ipairs(snapshots) do
          local ok, err = pcall(Fs.delete, snapshot.path)
          if ok then
            deleted[#deleted + 1] = snapshot.path
          else
            failed[#failed + 1] = tostring(err)
          end
        end
      end

      if #failed > 0 then
        vim.notify('vv-explorer: ' .. verb:lower() .. ' errors:\n' .. table.concat(failed, '\n'), vim.log.levels.ERROR)
      else
        local past = use_trash and 'Trashed' or 'Deleted'
        vim.notify(('%s %s'):format(past, Text.items(#deleted)))
      end

      if #deleted > 0 then
        local keys = {}
        for _, path in ipairs(deleted) do keys[#keys + 1] = resolved[path] end
        cleanup_deleted_bufs(state, keys)
      end
      context.after_fs_change(state)
    end

    local value = #paths == 1 and vim.fn.fnamemodify(paths[1], ':.') or Text.items(#paths)
    ConfirmLifecycle.open(state, {
      title = verb .. (#paths == 1 and ' item?' or ' items?'),
      details = { { label = #paths == 1 and 'Path' or 'Items', value = value } },
      severity = use_trash and 'warn' or 'danger',
      confirm_label = verb,
      confirm_hl = use_trash and 'DiagnosticWarn' or 'DiagnosticError',
      on_confirm = perform_delete,
      on_stale = function()
        vim.notify('vv-explorer: delete cancelled: explorer context is no longer current', vim.log.levels.WARN)
      end,
    })
  end

  function Actions.rename(state)
    H.ensure_state_fields(state)
    local node = context.target_node(state)
    if not node or node == state.root then return end

    local old_path = node.path
    vim.ui.input({ prompt = 'Rename: ', default = node.name }, function(new_name)
      if not new_name or new_name == '' or new_name == node.name then return end

      local new_path = vim.fs.normalize(vim.fs.dirname(old_path) .. '/' .. new_name)
      local timeout_ms = state.opts and state.opts.lsp_rename_timeout_ms or 5000

      local function finish()
        local ok, err = pcall(Fs.rename, old_path, new_path)
        if not ok then
          vim.notify('vv-explorer: ' .. tostring(err), vim.log.levels.ERROR)
          return
        end

        Fs.sync_buffers(old_path, new_path)
        Lsp.did_rename(old_path, new_path)
        context.after_fs_change(state)
        Tree.expand_to(state.root, new_path)
        Render.render(state)
        H.focus_path(state, new_path)
      end

      if #Lsp.will_rename_clients() == 0 then
        finish()
        return
      end

      state._lsp_renaming_path = old_path
      Render.render(state)
      local stop_loading = Loading.start({
        buf = state.buf,
        get_row = function() return state.path_to_row and state.path_to_row[old_path] end,
      })

      Lsp.will_rename_async(old_path, new_path, timeout_ms, function(timed_out)
        stop_loading()
        state._lsp_renaming_path = nil
        if timed_out then
          vim.notify(
            ('vv-explorer: LSP willRenameFiles timed out after %dms, proceeding anyway'):format(timeout_ms),
            vim.log.levels.WARN
          )
        end
        finish()
      end)
    end)
  end
end

return M

-- 文件系统 mutation：创建、删除与 LSP 感知的重命名

local Tree = require('vv-explorer.tree')
local Render = require('vv-explorer.render')
local Preview = require('vv-explorer.preview')
local Fs = require('vv-utils.fs')
local Trash = require('vv-explorer.trash')
local Lsp = require('vv-explorer.lsp')
local Loading = require('vv-utils.loading')
local Text = require('vv-explorer.text')

local M = {}

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
    local paths = targets(state, context.target_node(state))
    if #paths == 0 then return end

    local use_trash = Trash.enabled()
    local verb = use_trash and 'Trash' or 'Delete'
    local message
    if #paths == 1 then
      message = verb .. ' ' .. vim.fn.fnamemodify(paths[1], ':.') .. ' ?'
    else
      message = ('%s %d items ?'):format(verb, #paths)
    end
    if vim.fn.confirm(message, '&Yes\n&No', 2) ~= 1 then return end

    local resolved = {}
    for _, path in ipairs(paths) do
      resolved[path] = Fs.realpath(path):gsub('/+$', '')
    end

    local deleted
    local failed
    if use_trash then
      local result = Trash.trash(paths)
      deleted = result.trashed
      failed = result.failed
    else
      deleted = {}
      failed = {}
      for _, path in ipairs(paths) do
        local ok, err = pcall(Fs.delete, path)
        if ok then
          deleted[#deleted + 1] = path
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

-- 共享剪贴板：跨实例 cut/copy 标记、冲突决策与 paste 生命周期

local ClipboardStore = require('vv-explorer.clipboard_store')
local DialogLifecycle = require('vv-explorer.dialog_lifecycle')
local PasteConflict = require('vv-explorer.paste_conflict')
local Render = require('vv-explorer.render')
local Text = require('vv-explorer.text')
local Transfer = require('vv-explorer.actions.transfer')
local Tree = require('vv-explorer.tree')

local M = {}

local function notify_store_error(error_message)
  vim.notify('vv-explorer: ' .. error_message, vim.log.levels.ERROR)
end

---@param state table
---@return VVExplorerClipboardRecord?
local function sync_state(state)
  local record, error_message = ClipboardStore.read()
  if error_message then
    state.clipboard = nil
    notify_store_error(error_message)
    return nil
  end
  state.clipboard = record
  return record
end

---@param Actions table
---@param H table
---@param context table
function M.attach(Actions, H, context)
  ---@param state table
  function Actions.sync_clipboard(state)
    return sync_state(state)
  end

  ---@param state table
  function Actions.subscribe_clipboard(state)
    if state._clipboard_unsubscribe then return end
    state._clipboard_unsubscribe = ClipboardStore.subscribe(function(record, error_message)
      if error_message then
        state.clipboard = nil
        notify_store_error(error_message)
      else
        state.clipboard = record
      end
      if state.buf and vim.api.nvim_buf_is_valid(state.buf) then Render.render(state) end
    end)
  end

  ---@param state table
  function Actions.unsubscribe_clipboard(state)
    if not state._clipboard_unsubscribe then return end
    local unsubscribe = state._clipboard_unsubscribe
    state._clipboard_unsubscribe = nil
    unsubscribe()
  end

  ---@param state table
  function Actions.clear_clipboard(state)
    local expected = sync_state(state)
    if not expected then return true end

    local cleared, _, error_message = ClipboardStore.clear(expected)
    if error_message then
      notify_store_error(error_message)
      return false
    end
    sync_state(state)
    if not cleared then
      vim.notify('vv-explorer: clipboard changed in another instance; it was not cleared', vim.log.levels.WARN)
    end
    Render.render(state)
    return cleared
  end

  ---@param state table
  ---@param mode 'cut'|'copy'
  local function mark(state, mode)
    H.ensure_state_fields(state)
    local node = context.target_node(state)
    local selected = H.selected_paths(state)
    local paths
    local expected

    if #selected > 0 then
      paths = selected
      state.selection = {}
    elseif node and node ~= state.root then
      local path = node.path
      local current = sync_state(state)
      if current and current.mode == mode then
        expected = current
        paths = vim.deepcopy(current.paths)
        local found = false
        for index, existing in ipairs(paths) do
          if existing == path then
            table.remove(paths, index)
            found = true
            break
          end
        end
        if not found then paths[#paths + 1] = path end
      else
        paths = { path }
      end
    else
      return
    end

    local record, error_message
    if expected then
      local updated
      updated, record, error_message = ClipboardStore.replace_if_current(expected, mode, paths)
      if not error_message and not updated then
        sync_state(state)
        vim.notify('vv-explorer: clipboard changed in another instance; the mark was not updated', vim.log.levels.WARN)
        Render.render(state)
        return
      end
    else
      record, error_message = ClipboardStore.write(mode, paths)
    end
    if error_message then
      notify_store_error(error_message)
      return
    end

    state.clipboard = record
    Render.render(state)
    local count = record and #record.paths or 0
    if count > 0 then
      vim.notify(('%s %s'):format(mode == 'cut' and 'Cut' or 'Copied', Text.items(count)))
    end
  end

  function Actions.cut_mark(state) mark(state, 'cut') end
  function Actions.copy_mark(state) mark(state, 'copy') end

  ---@param state table
  ---@param record VVExplorerClipboardRecord
  ---@param plan VVExplorerTransferPlan
  ---@param policy 'overwrite'|'increment'
  local function execute(state, record, plan, policy)
    local result = Transfer.execute(plan, policy)

    if #result.failed > 0 then
      vim.notify('vv-explorer: paste errors:\n' .. table.concat(result.failed, '\n'), vim.log.levels.ERROR)
    end
    if #result.warnings > 0 then
      vim.notify('vv-explorer: paste warnings:\n' .. table.concat(result.warnings, '\n'), vim.log.levels.WARN)
    end

    if #result.completed_sources > 0 then
      local completed = {}
      for _, source in ipairs(result.completed_sources) do completed[source] = true end
      local remaining = {}
      if record.mode == 'cut' then
        for _, source in ipairs(record.paths) do
          if not completed[source] then remaining[#remaining + 1] = source end
        end
      end
      local updated, _, update_error = ClipboardStore.replace_if_current(record, record.mode, remaining, {
        owner_id = record.owner_id,
        claim_ownership = false,
      })
      if update_error then notify_store_error(update_error) end
      if not update_error and not updated then
        vim.notify('vv-explorer: clipboard changed in another instance; completed paths were not removed',
          vim.log.levels.WARN)
      end
    end
    sync_state(state)

    if result.completed > 0 then context.after_fs_change(state) end
    if result.last_dest then
      Tree.expand_to(state.root, result.last_dest)
      Render.render(state)
      H.focus_path(state, result.last_dest)
    end
  end

  function Actions.paste(state)
    H.ensure_state_fields(state)
    local record = sync_state(state)
    if not record then
      vim.notify('vv-explorer: clipboard empty', vim.log.levels.WARN)
      return
    end

    local destination = context.dir_context(state, context.target_node(state))
    local plan = Transfer.plan(record.paths, destination, record.mode)
    if #plan.entries == 0 then
      if #plan.failed > 0 then
        vim.notify('vv-explorer: paste errors:\n' .. table.concat(plan.failed, '\n'), vim.log.levels.ERROR)
      end
      return
    end

    local conflict = state.opts.clipboard.conflict
    if plan.conflicts == 0 then return execute(state, record, plan, 'increment') end
    if conflict ~= 'prompt' then return execute(state, record, plan, conflict) end

    return DialogLifecycle.open(state, {
      is_current = function()
        local current = ClipboardStore.read()
        if not current or current.id ~= record.id then return false end
        local current_node = context.target_node(state)
        return context.dir_context(state, current_node) == destination
      end,
      on_action = function(action) execute(state, record, plan, action) end,
      on_stale = function()
        vim.notify('vv-explorer: paste cancelled: clipboard or explorer context changed', vim.log.levels.WARN)
      end,
      open = function(emit, cancel)
        return PasteConflict.open(plan, {
          on_select = emit,
          on_cancel = cancel,
        })
      end,
    })
  end
end

return M

-- Explorer 确认动作的 owner 生命周期：latest-wins、上下文校验与 watcher 清理

local M = {}

local function delete_watchers(record)
  for _, id in ipairs(record.watch_ids) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  record.watch_ids = {}
end

local function clear_state(state, record)
  delete_watchers(record)

  if state._confirm_record ~= record then return end
  state._confirm_record = nil
  state._confirm_handle = nil
  state._confirm_cancel = nil
end

local function source_is_live(state, record)
  if record.source_root and state.root ~= record.source_root then return false end
  if record.source_root_path and (not state.root or state.root.path ~= record.source_root_path) then return false end
  if record.root_generation ~= state._root_generation then return false end

  local source_win = record.source_win
  if source_win then
    if state.win ~= source_win or not vim.api.nvim_win_is_valid(source_win) then return false end

    local source_buf = record.source_buf
    if source_buf then
      if state.buf ~= source_buf or not vim.api.nvim_buf_is_valid(source_buf) then return false end
      local ok, current_buf = pcall(vim.api.nvim_win_get_buf, source_win)
      if not ok or current_buf ~= source_buf then return false end
    end
  end

  return true
end

local function context_is_live(state, record)
  if state._confirm_record ~= record or record.closed then return false end
  if not source_is_live(state, record) then return false end

  if record.is_current then
    local ok, current = pcall(record.is_current)
    if not ok or not current then return false end
  end

  return true
end

---取消当前 Explorer 确认。该操作可安全重复调用。
---@param state table
function M.cancel(state)
  if not state then return end

  if state._confirm_cancel then
    pcall(state._confirm_cancel)
  elseif state._confirm_handle then
    pcall(state._confirm_handle.close)
    state._confirm_handle = nil
  end
end

---打开一个由调用方提供 UI 的确认动作。
---
---`open` 会先取消同一 Explorer state 上的旧确认。`opener` 接收包装后的
---confirm opts，并且必须返回带 `close()` 的 handle；省略时使用 vv-utils.confirm。
---@param state table
---@param opts table
---@param opener? fun(opts:table):table?
---@return table? handle
function M.open(state, opts, opener)
  opts = opts or {}
  M.cancel(state)

  local record = {
    source_win = state.win,
    source_buf = state.buf,
    source_root = state.root,
    source_root_path = state.root and state.root.path,
    root_generation = state._root_generation,
    is_current = opts.is_current,
    watch_ids = {},
    closed = false,
  }
  local handle
  local lifecycle_handle

  local function finish(kind)
    if record.closed then return end

    local current = kind == 'confirm' and context_is_live(state, record)
    record.closed = true
    clear_state(state, record)

    if kind == 'confirm' and current and opts.on_confirm then
      opts.on_confirm()
    elseif kind == 'confirm' and not current and opts.on_stale then
      opts.on_stale()
    elseif kind == 'cancel' and opts.on_cancel then
      opts.on_cancel()
    end
  end

  local function cancel()
    if record.closed then return end
    record.closed = true
    clear_state(state, record)
    if handle then pcall(handle.close) end
  end

  lifecycle_handle = { close = cancel }

  state._confirm_record = record
  state._confirm_cancel = cancel
  state._confirm_handle = nil

  local confirm_opts = vim.tbl_extend('force', {}, opts, {
    on_confirm = function() finish('confirm') end,
    on_cancel = function() finish('cancel') end,
  })
  confirm_opts.is_current = nil
  confirm_opts.on_stale = nil

  local open = opener or function(values)
    return require('vv-utils.confirm').open(values)
  end
  local ok, result = pcall(open, confirm_opts)
  if ok then handle = result end
  if not handle then
    cancel()
    if not ok then error(result) end
    return
  end

  if record.closed or state._confirm_record ~= record then
    pcall(handle.close)
    return lifecycle_handle
  end

  record.handle = handle
  state._confirm_handle = lifecycle_handle

  local function cancel_if_pending()
    if state._confirm_record == record then cancel() end
  end

  local function cancel_if_source_invalid()
    if state._confirm_record ~= record then return end
    if not record.source_win or not vim.api.nvim_win_is_valid(record.source_win) then
      return cancel()
    end
    local ok, current_buf = pcall(vim.api.nvim_win_get_buf, record.source_win)
    if not ok or (record.source_buf and current_buf ~= record.source_buf) then
      cancel()
    end
  end

  if record.source_win and vim.api.nvim_win_is_valid(record.source_win) then
    record.watch_ids[#record.watch_ids + 1] = vim.api.nvim_create_autocmd('WinClosed', {
      pattern = tostring(record.source_win),
      once = true,
      callback = cancel_if_pending,
    })
    record.watch_ids[#record.watch_ids + 1] = vim.api.nvim_create_autocmd('BufWinLeave', {
      buffer = record.source_buf,
      callback = cancel_if_source_invalid,
    })
  end
  if record.source_buf and vim.api.nvim_buf_is_valid(record.source_buf) then
    record.watch_ids[#record.watch_ids + 1] = vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = record.source_buf,
      once = true,
      callback = cancel_if_pending,
    })
  end

  return lifecycle_handle
end

---供调用方在确认回调内进行额外的目标校验。
---@param state table
---@param record table
---@return boolean
function M.is_current(state, record)
  return context_is_live(state, record)
end

return M

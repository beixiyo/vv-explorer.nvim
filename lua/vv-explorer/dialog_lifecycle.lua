-- Explorer 对话框适配：业务上下文校验交给调用方，latest-wins 与资源清理由 vv-utils.async 持有

local Async = require('vv-utils.async')

local M = {}

local function ensure_scope(state)
  if not state._dialog_scope or state._dialog_scope:is_disposed() then
    state._dialog_scope = Async.scope({ cancel_previous = true })
  end
  return state._dialog_scope
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

local function custom_context_is_live(record)
  if not record.is_current then return true end
  local ok, current = pcall(record.is_current)
  return ok and current == true
end

---关闭当前 Explorer 对话框，不触发业务回调；可安全重复调用
---@param state table
function M.cancel(state)
  if not state then return end
  if state._dialog_scope then state._dialog_scope:cancel() end
end

---打开任意动作对话框；open 只接收 emit/cancel，不取得业务 state
---@param state table
---@param opts {open:fun(emit:fun(action:string), cancel:fun()):table?, on_action?:fun(action:string), on_cancel?:fun(), on_stale?:fun(action:string), is_current?:fun():boolean}
---@return table? handle
function M.open(state, opts)
  local scope = ensure_scope(state)
  local handle
  local underlying_closed = false
  local request
  local record = {
    source_win = state.win,
    source_buf = state.buf,
    source_root = state.root,
    source_root_path = state.root and state.root.path,
    root_generation = state._root_generation,
    is_current = opts.is_current,
    watch_ids = {},
  }

  local function close_underlying()
    if not handle or underlying_closed then return end
    underlying_closed = true
    pcall(handle.close)
  end

  request = scope:begin({
    key = 'dialog',
    mode = 'latest',
    cancel_previous = true,
    cancel = close_underlying,
    dispose = function()
      for _, id in ipairs(record.watch_ids) do pcall(vim.api.nvim_del_autocmd, id) end
      record.watch_ids = {}
      if state._dialog_request == request then
        state._dialog_request = nil
        state._dialog_record = nil
        state._dialog_handle = nil
        state._dialog_cancel = nil
      end
    end,
  })

  local lifecycle_handle = { close = function() request:cancel() end }
  state._dialog_request = request
  state._dialog_record = record
  state._dialog_handle = lifecycle_handle
  state._dialog_cancel = lifecycle_handle.close

  local function finish_action(action)
    local context_is_live = source_is_live(state, record) and custom_context_is_live(record)
    if not request:finish() then return end
    if context_is_live and opts.on_action then
      opts.on_action(action)
    elseif not context_is_live and opts.on_stale then
      opts.on_stale(action)
    end
  end

  local function finish_cancel()
    if request:finish() and opts.on_cancel then opts.on_cancel() end
  end

  local ok, result = pcall(opts.open, finish_action, finish_cancel)
  if not ok or not result then
    request:cancel()
    if not ok then error(result) end
    return
  end
  handle = result
  if not request:is_current() then
    close_underlying()
    return lifecycle_handle
  end

  local function cancel_if_pending()
    if request:is_current() then request:cancel() end
  end

  local function cancel_if_source_invalid()
    if not request:is_current() then return end
    if not record.source_win or not vim.api.nvim_win_is_valid(record.source_win) then return request:cancel() end
    local current_ok, current_buf = pcall(vim.api.nvim_win_get_buf, record.source_win)
    if not current_ok or (record.source_buf and current_buf ~= record.source_buf) then request:cancel() end
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

---二元确认框适配；删除和执行继续只声明业务内容
---@param state table
---@param opts table
---@param opener? fun(opts:table):table?
---@return table? handle
function M.confirm(state, opts, opener)
  return M.open(state, {
    is_current = opts.is_current,
    on_stale = function() if opts.on_stale then opts.on_stale() end end,
    on_cancel = opts.on_cancel,
    on_action = function() if opts.on_confirm then opts.on_confirm() end end,
    open = function(emit, cancel)
      local values = vim.tbl_extend('force', {}, opts, {
        on_confirm = function() emit('confirm') end,
        on_cancel = cancel,
      })
      values.is_current = nil
      values.on_stale = nil
      local open = opener or function(current) return require('vv-utils.confirm').open(current) end
      return open(values)
    end,
  })
end

return M

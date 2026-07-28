-- explorer 面板生命周期与运行时状态的持有者

local Actions = require('vv-explorer.actions')
local Config = require('vv-explorer.config')
local Diagnostics = require('vv-explorer.diagnostics')
local Git = require('vv-explorer.git')
local Mappings = require('vv-explorer.panel.mappings')
local Preview = require('vv-explorer.preview')
local Render = require('vv-explorer.render')
local Trash = require('vv-explorer.trash')
local Tree = require('vv-explorer.tree')
local UIWindow = require('vv-utils.ui_window')
local Watch = require('vv-explorer.watch')
local Window = require('vv-explorer.window')

local M = {}

local config = Config.resolve()
local state = nil ---@type table?
local panel_state = nil ---@type VVStateHandle?
local save_width_debounced = nil ---@type fun()?
local cancel_width_save = nil ---@type fun()?
local cancel_follow = nil ---@type fun()?
local is_exiting = false
local suspend_generation = 0
local dnd_attached = false

local function save_open_intent(open)
  if config.persist_open and panel_state then
    panel_state:set('open', open)
  end
end

local function save_width()
  if not panel_state or not state or not Config.is_valid_width(state._tracked_width) then return end
  panel_state:set('width', state._tracked_width)
end

local function is_sole_window()
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return false end
  local tab = vim.api.nvim_win_get_tabpage(state.win)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if win ~= state.win and vim.api.nvim_win_get_config(win).relative == '' then
      return false
    end
  end
  return true
end

local function remember_width()
  if not state then return end
  if state.win and vim.api.nvim_win_is_valid(state.win) and not is_sole_window() then
    state._tracked_width = vim.api.nvim_win_get_width(state.win)
  end
  if state.opts and Config.is_valid_width(state._tracked_width) then
    state.opts.width = state._tracked_width
  end
  save_width()
end

local function on_buf_wiped()
  if not state then return end
  pcall(Watch.detach, state)
  pcall(Preview.detach, state)
  pcall(Git.detach, state)
  pcall(Diagnostics.detach, state)
  state = nil
end

-- 只关闭窗口，持久化的树、过滤和监听状态仍挂在隐藏 buffer 上
---@param opts? {persist_open?:boolean}
local function close_window_only(opts)
  if not state then return end
  opts = opts or {}
  remember_width()
  if opts.persist_open ~= false and not is_exiting then
    suspend_generation = suspend_generation + 1
    save_open_intent(false)
  end

  local win = state.win
  state.win = nil
  state.prev_win = nil
  state.rows = nil
  state.path_to_row = nil
  state._pending_reveal = nil
  if win and vim.api.nvim_win_is_valid(win) then Window.close_win(win) end
end

local function ensure_unique_window()
  if not state or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end

  local tab
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    tab = vim.api.nvim_win_get_tabpage(state.win)
  else
    tab = vim.api.nvim_get_current_tabpage()
  end

  state.win = UIWindow.ensure_unique_buffer_window(tab, state.buf, state.win)
end

---@param opts {focus?:boolean}
---@param previous_win integer
local function restore_previous_focus(opts, previous_win)
  if opts.focus == false and vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
  end
end

---@param win integer
local function attach_window_close(win)
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = function()
      if state and state.win == win then close_window_only() end
    end,
  })
end

local function attach_window_lifecycle()
  local win_group = vim.api.nvim_create_augroup('vv-explorer.win', { clear = true })

  vim.api.nvim_create_autocmd('WinResized', {
    group = win_group,
    callback = function()
      if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
      ensure_unique_window()
      if is_sole_window() then return end
      state._tracked_width = vim.api.nvim_win_get_width(state.win)
      if save_width_debounced then save_width_debounced() end
    end,
  })

  -- 如果伴随的编辑窗口关闭后只剩 explorer，则重新创建普通编辑窗口
  vim.api.nvim_create_autocmd('WinClosed', {
    group = win_group,
    callback = function(ev)
      if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
      if tonumber(ev.match) == state.win then return end

      vim.schedule(function()
        if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
        if not is_sole_window() then return end

        local saved_width = state._tracked_width
        vim.api.nvim_set_current_win(state.win)
        local position = state.opts and state.opts.position or 'left'
        vim.cmd(position == 'right' and 'topleft vnew' or 'botright vnew')
        vim.bo.buflisted = false
        vim.bo.bufhidden = 'wipe'
        vim.api.nvim_win_set_width(state.win, saved_width)
      end)
    end,
  })
end

---@param file string
local function reveal_no_focus(file)
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end

  state._pending_reveal = file
  local normalized = vim.fs.normalize(file)
  local existing = state.path_to_row and state.path_to_row[normalized]
  if existing then
    state._pending_reveal = nil
    local current = vim.api.nvim_win_get_cursor(state.win)[1]
    if current ~= existing then
      vim.api.nvim_win_set_cursor(state.win, { existing, 0 })
    end
    return
  end

  if not Actions.expand_to_file(state, file) then
    state._pending_reveal = nil
    return
  end

  Render.render(state)
  Render.try_reveal_cursor(state)
end

local function attach_setup_lifecycle()
  local setup_group = vim.api.nvim_create_augroup('vv-explorer.panel', { clear = true })

  if cancel_follow then
    cancel_follow()
    cancel_follow = nil
  end

  if config.follow_file then
    local reveal = reveal_no_focus
    if config.follow_file_debounce_ms > 0 then
      reveal, cancel_follow = require('vv-utils.timer').debounce(reveal_no_focus, config.follow_file_debounce_ms)
    end

    vim.api.nvim_create_autocmd('BufEnter', {
      group = setup_group,
      callback = function(ev)
        if not M.is_open() then return end
        if state and ev.buf == state.buf then return end
        local win = vim.api.nvim_get_current_win()
        if vim.api.nvim_win_get_config(win).relative ~= '' then return end
        if vim.bo[ev.buf].buftype ~= '' then return end
        local file = vim.api.nvim_buf_get_name(ev.buf)
        if file == '' then return end
        if vim.fn.filereadable(file) == 0 and vim.fn.isdirectory(file) == 0 then return end
        reveal(file)
      end,
    })
  end

  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = setup_group,
    callback = function()
      is_exiting = true
      remember_width()
      if cancel_width_save then cancel_width_save() end
      if cancel_follow then cancel_follow() end
    end,
  })
end

---@param resolved_config VVExplorerResolvedConfig
function M.setup(resolved_config)
  config = resolved_config
  panel_state = config.state or require('vv-utils.state').register('vv-explorer', 'panel')
  config.state = panel_state
  is_exiting = false

  local persisted_width = panel_state:get('width')
  if Config.is_valid_width(persisted_width) then config.width = persisted_width end

  if cancel_width_save then cancel_width_save() end
  save_width_debounced, cancel_width_save = require('vv-utils.timer').debounce(save_width, 120)

  Trash.setup(config.trash)
  attach_setup_lifecycle()

  if not dnd_attached then
    require('vv-explorer.dnd').attach(function() return state end)
    dnd_attached = true
  end

  if config.persist_open and panel_state:get('open', false) == true then
    vim.schedule(function()
      if not M.is_open() and panel_state and panel_state:get('open', false) == true then
        M.open({ focus = false })
      end
    end)
  end
end

function M.is_open()
  if not state or not state.win or not state.buf then return false end
  if not vim.api.nvim_win_is_valid(state.win) then return false end
  if not vim.api.nvim_buf_is_valid(state.buf) then return false end
  return vim.api.nvim_win_get_buf(state.win) == state.buf
end

---@param opts {cwd?:string, focus?:boolean}?
function M.open(opts)
  opts = opts or {}
  if M.is_open() then
    if opts.focus ~= false and state then vim.api.nvim_set_current_win(state.win) end
    save_open_intent(true)
    return
  end
  suspend_generation = suspend_generation + 1

  if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    local win, previous_win = Window.open_split(state.buf, state.opts or config)
    state.win = win
    state.prev_win = previous_win
    ensure_unique_window()
    state._skip_preview = true
    Tree.refresh(state.root)
    if state.opts and state.opts.diagnostics and state.opts.diagnostics.enabled then
      Diagnostics.refresh(state)
    end
    Render.render(state)
    state._skip_preview = nil
    attach_window_close(win)
    save_open_intent(true)
    restore_previous_focus(opts, previous_win)
    return
  end

  local cwd = opts.cwd or config.cwd or vim.fn.getcwd()
  local buf = Window.create_buf()
  local win, previous_win = Window.open_split(buf, config)

  state = {
    buf = buf,
    win = win,
    prev_win = previous_win,
    root = Tree.new_root(cwd),
    opts = vim.tbl_deep_extend('force', {}, config),
    _tracked_width = config.width,
  }
  state.on_after_render = function(current)
    if current._rescan_watches then current._rescan_watches() end
  end

  attach_window_lifecycle()
  Mappings.apply(state, {
    mappings = config.mappings,
    actions = Actions,
    close = M.close,
  })
  Mappings.attach_cursor_snap(state, Actions)

  if config.preview then Preview.attach(state) end
  if config.watch then Watch.attach(state) end
  if config.git.enabled then Git.attach(state) end
  if config.diagnostics.enabled then Diagnostics.attach(state) end

  state._skip_preview = true
  Render.render(state)
  state._skip_preview = nil

  if config.trash.enabled and config.trash.scan_on_open then
    Trash.scan_size(function(bytes)
      local megabytes = bytes / (1024 * 1024)
      if megabytes > config.trash.warn_size_mb then
        vim.notify(
          string.format('vv-explorer: trash %.0f MB, consider :VVExplorerTrash to clean', megabytes),
          vim.log.levels.WARN
        )
      end
    end)
  end

  attach_window_close(win)
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = on_buf_wiped,
  })

  save_open_intent(true)
  restore_previous_focus(opts, previous_win)
end

function M.close()
  close_window_only()
end

---临时隐藏 explorer，但不改变持久化的打开意图
---返回的回调只恢复本次挂起，且最多安全调用一次
---@param opts VVExplorerSuspendOpts?
---@return fun()?
function M.suspend(opts)
  if not M.is_open() then return nil end
  opts = opts or {}

  suspend_generation = suspend_generation + 1
  local generation = suspend_generation
  local resumed = false
  local focus_on_resume = opts.focus == true
  close_window_only({ persist_open = false })

  return function()
    if resumed then return end
    resumed = true
    if generation ~= suspend_generation then return end
    if config.persist_open and panel_state and panel_state:get('open', false) ~= true then return end
    M.open({ focus = focus_on_resume })
  end
end

---@param opts {cwd?:string}?
function M.toggle(opts)
  if M.is_open() then M.close() else M.open(opts) end
end

---@param opts {file?:string}?
function M.reveal(opts)
  if M.is_open() then
    M.close()
    return
  end

  opts = opts or {}
  local file = opts.file or vim.api.nvim_buf_get_name(0)
  if file == '' or vim.fn.filereadable(file) == 0 and vim.fn.isdirectory(file) == 0 then
    M.open()
    if state and state.win and vim.api.nvim_win_is_valid(state.win) then
      pcall(vim.api.nvim_win_set_cursor, state.win, { 1, 0 })
    end
    M.focus()
    return
  end

  M.open()
  if not state then return end

  state._skip_preview = true
  state._pending_reveal = file
  local positioned = false
  if Actions.expand_to_file(state, file) then
    Render.render(state)
    positioned = Render.try_reveal_cursor(state)
  else
    state._pending_reveal = nil
  end
  if not positioned and state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_set_cursor, state.win, { 1, 0 })
  end
  state._skip_preview = nil
  M.focus()
end

function M.focus()
  if M.is_open() and state then vim.api.nvim_set_current_win(state.win) end
end

function M.get_node_path()
  if not state then return nil end
  local node = Actions.node_under_cursor(state)
  return node and node.path or nil
end

---@return string[]
function M.get_target_paths()
  if not state then return {} end

  local selected = Actions.selected_paths(state)
  if #selected > 0 then return selected end

  local path = M.get_node_path()
  return path and { path } or {}
end

function M.open_trash()
  Trash.open_panel(state)
end

function M.execute()
  if state then Actions.execute(state) end
end

---@class VVExplorerSuspendOpts
---@field focus? boolean 恢复面板时是否聚焦 explorer @default false

return M

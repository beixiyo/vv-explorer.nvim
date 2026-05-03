-- vv-explorer.nvim — VSCode 风文件树（自实现，无 nui/plenary 依赖）
--
-- 设计目标：
--   * 仅文件树（无 buffers/git_status 多 source）
--   * VSCode 风「单击预览」内置（详见 preview.lua）
--   * 空目录折叠（group_empty_dirs，单链 dir 合并显示）
--   * 图标走 mini.icons，可叠加用户 glob/Lua pattern 规则
--   * libuv fs_event 自动刷新
--
-- 依赖：仅 vim.uv / vim.api / vim.fs / vim.glob（Neovim 0.10+ 全部内置）
--
-- 公开 API：
--   require('vv-explorer').setup(opts)
--   require('vv-explorer').open({ cwd? })
--   require('vv-explorer').close()
--   require('vv-explorer').toggle({ cwd? })
--   require('vv-explorer').reveal({ file? })
--   require('vv-explorer').focus()
--
-- 用户命令（setup 时注册）：
--   :VVExplorerToggle / :VVExplorerOpen / :VVExplorerClose / :VVExplorerReveal / :VVExplorerFocus

local Tree = require('vv-explorer.tree')
local Render = require('vv-explorer.render')
local Window = require('vv-explorer.window')
local Preview = require('vv-explorer.preview')
local Watch = require('vv-explorer.watch')
local Icons = require('vv-explorer.icons')
local Actions = require('vv-explorer.actions')
local Git = require('vv-explorer.git')
local Diagnostics = require('vv-explorer.diagnostics')
local Trash = require('vv-explorer.trash')

local M = {}

---@class VVExplorerFilterConfig
---@field custom string[] 永久隐藏的 glob 列表（独立于 `.` toggle），如 {'node_modules', '.DS_Store'}

---@class VVExplorerGitConfig
---@field enabled boolean 启用 git 状态索引（走 `git status --porcelain --ignored`，非 git 仓库自动 no-op）
---@field show_ignored boolean 是否显示 .gitignore 命中的路径（`I` 键切换）

---@class VVExplorerDiagnosticsConfig
---@field enabled boolean 订阅 LSP 诊断并在行尾显示 E/W/I/H 符号

---@class VVExplorerGlobalMappings
---@field toggle string|false  打开/关闭文件树的全局键位（false 禁用）
---@field reveal string|false  展开到并高亮当前 buffer 对应文件的全局键位

---@class VVExplorerConfig
---@field position 'left'|'right'
---@field width integer
---@field hidden boolean 显示 dotfile（`.` 开头）
---@field group_empty_dirs boolean 单链 dir 合并显示
---@field preview boolean VSCode 风单击预览
---@field watch boolean libuv fs_event 自动刷新
---@field cwd string? 默认根目录（nil → vim.fn.getcwd()）
---@field icon_rules VVExplorerIconRule[]
---@field filter VVExplorerFilterConfig
---@field git VVExplorerGitConfig
---@field diagnostics VVExplorerDiagnosticsConfig
---@field global_mappings VVExplorerGlobalMappings|false  全局快捷键（整个 nvim 范围）；设 false 禁用所有
---@field mappings table<string, string|false|fun(state:table)>  树 buffer 内的 normal 模式键位表；value 可为内置 action 名、false 禁用、或自定义函数（接收 state）
local defaults = {
  position = 'left',
  width = 32,
  hidden = false,
  group_empty_dirs = true,
  preview = true,
  watch = true,
  cwd = nil,
  icon_rules = {},
  filter = { custom = {} },
  git = { enabled = true, show_ignored = false },
  diagnostics = { enabled = true },
  trash = {
    enabled = true,
    max_items = 5000,
    warn_size_mb = 500,
    scan_on_open = true,
  },
  global_mappings = {
    toggle = '<leader>e',
    reveal = '<leader>E',
  },
  mappings = {
    ['<C-e>'] = 'scroll_preview_down',
    ['<C-y>'] = 'scroll_preview_up',
    ['<CR>']  = 'open',
    ['l']     = 'open',
    ['o']     = 'open',
    ['<2-LeftMouse>'] = 'open',
    ['<RightMouse>']  = 'yank_abs_path', -- 右键复制绝对路径
    ['h']     = 'close_node',
    ['.']     = 'toggle_hidden',   -- yazi 风：dotfile 显隐
    ['I']     = 'toggle_gitignored', -- gitignored 显隐（Phase 2 生效）
    ['R']     = 'refresh',
    ['Y']     = 'yank_abs_path',   -- 绝对路径
    ['=']     = 'cd_to',
    ['-']     = 'cd_up',
    ['/']     = 'start_filter',
    ['<Esc>'] = 'escape', -- 优先级：filter > selection > 无操作
    ['q']     = '__quit',  -- filter 模式时清 filter，否则关树
    ['g?']    = 'help',
    -- 打开方式
    ['<C-x>'] = 'open_split',
    ['<C-v>'] = 'open_vsplit',
    ['<C-t>'] = 'open_tab',
    ['gx']    = 'system_open',
    -- CRUD
    ['a']     = 'create',      -- 新建，尾随 '/' 视为目录
    ['d']     = 'delete',      -- 删除（带确认，批量）
    ['r']     = 'rename',      -- 重命名（单个）
    -- 剪贴板（yazi / vim 风格）
    ['y']     = 'copy_mark',   -- yank：标记复制
    ['x']     = 'cut_mark',    -- 标记剪切
    ['p']     = 'paste',       -- 粘贴到光标目录
    -- 批量选择：Tab 自身即可切换，再按一次取消
    ['<Tab>'] = 'toggle_select',
    -- 回收站
    ['T']     = 'trash_panel',
  },
}

local config = defaults
local state = nil ---@type table?

local function setup_cursor_snap(s)
  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = s.buf,
    callback = function()
      if not s.name_cols or not s.win or not vim.api.nvim_win_is_valid(s.win) then return end
      local cursor = vim.api.nvim_win_get_cursor(s.win)
      local target_col = s.name_cols[cursor[1]]
      if target_col and cursor[2] ~= target_col then
        vim.api.nvim_win_set_cursor(s.win, { cursor[1], target_col })
      end
    end,
  })
end

local function register_highlights()
  -- 共享 git 状态色（VVGitAdded/Modified/...）统一由 vv-utils.git 注册
  require('vv-utils.git').register_hl()

  require('vv-utils.hl').register('vv-explorer.hl', {
    VVExplorerIndent     = { link = 'Comment' },
    VVExplorerDir        = { link = 'Directory' },
    VVExplorerFile       = { link = 'Normal' },
    VVExplorerRoot       = { link = 'Title' },
    VVExplorerSelected   = { link = 'Visual' }, -- 选区整行底色
    VVExplorerDim        = { link = 'Comment' }, -- dotfile + gitignored 暗色
    -- 诊断符号（Phase 2）—— hl 名已迁移至 VVDiag*（vv-utils.diagnostics）
    VVDiagError = { link = 'DiagnosticError' },
    VVDiagWarn  = { link = 'DiagnosticWarn' },
    VVDiagInfo  = { link = 'DiagnosticInfo' },
    VVDiagHint  = { link = 'DiagnosticHint' },
    -- 逐字匹配字符：底色同 bufferline 活动 tab (#193d4c)，bold 强调
    -- 只设 bg，fg 从下层 VVExplorerFile/Dir 透下来，不盖掉文件/目录原色
    VVExplorerMatch = { bg = '#193d4c', bold = true },
    -- filter prompt mode badge：每个 mode 一个色，bold 突出
    VVExplorerFilterModeFuzzy = { fg = '#7dcfff', bold = true }, -- 青蓝
    VVExplorerFilterModeGlob  = { fg = '#e0af68', bold = true }, -- 橙
    VVExplorerFilterModeRegex = { fg = '#ff6ac1', bold = true }, -- 粉（与 vv-replace 同色）
  })
end

-- j/k 到边界循环（首尾绕回），避免卡死
---@param s table
local function apply_wrap_movement(s)
  local function move(delta)
    local last = vim.api.nvim_buf_line_count(s.buf)
    if last <= 0 then return end
    local lnum = vim.api.nvim_win_get_cursor(s.win)[1]
    local target = ((lnum - 1 + delta) % last + last) % last + 1
    vim.api.nvim_win_set_cursor(s.win, { target, 0 })
  end

  vim.keymap.set('n', 'j', function() move(1) end,
    { buffer = s.buf, nowait = true, silent = true, desc = 'vv-explorer: next (wrap)' })
  vim.keymap.set('n', 'k', function() move(-1) end,
    { buffer = s.buf, nowait = true, silent = true, desc = 'vv-explorer: prev (wrap)' })
end

---@param s table
local function apply_keymaps(s)
  apply_wrap_movement(s)
  for lhs, action in pairs(config.mappings) do
    if action then
      local is_fn = type(action) == 'function'
      local desc = is_fn and 'vv-explorer: <fn>' or ('vv-explorer: ' .. action)
      vim.keymap.set('n', lhs, function()
        if is_fn then return action(s) end
        if action == '__close' then return M.close() end
        if action == '__quit' then
          if s.filter and s.filter.active then
            return Actions.clear_filter(s)
          end
          return M.close()
        end
        local fn = Actions[action]
        if fn then fn(s) end
      end, { buffer = s.buf, nowait = true, silent = true, desc = desc })
    end
  end
end

---@param opts VVExplorerConfig?
function M.setup(opts)
  config = vim.tbl_deep_extend('force', defaults, opts or {})

  -- trash: false → 关闭, true → 默认, table → 合并
  if config.trash == false then
    config.trash = { enabled = false }
  elseif config.trash == true then
    config.trash = vim.tbl_deep_extend('force', {}, defaults.trash)
  end
  Trash.setup(config.trash)

  Icons.compile(config.icon_rules)
  register_highlights()

  vim.api.nvim_create_user_command('VVExplorerToggle', function() M.toggle() end, {})
  vim.api.nvim_create_user_command('VVExplorerOpen', function() M.open() end, {})
  vim.api.nvim_create_user_command('VVExplorerClose', function() M.close() end, {})
  vim.api.nvim_create_user_command('VVExplorerReveal', function() M.reveal() end, {})
  vim.api.nvim_create_user_command('VVExplorerFocus', function() M.focus() end, {})
  vim.api.nvim_create_user_command('VVExplorerTrash', function()
    Trash.open_panel(state)
  end, { desc = 'vv-explorer: open trash panel' })

  -- 全局键位：用户想自己管就 setup({ global_mappings = false })
  if config.global_mappings then
    local gm = config.global_mappings
    if gm.toggle then
      vim.keymap.set('n', gm.toggle, '<cmd>VVExplorerToggle<cr>',
        { desc = 'vv-explorer: toggle', silent = true })
    end
    if gm.reveal then
      vim.keymap.set('n', gm.reveal, '<cmd>VVExplorerReveal<cr>',
        { desc = 'vv-explorer: reveal current file', silent = true })
    end
  end

end

-- state 的生命周期分两类字段：
--   ephemeral（每次 open 重建）：win, prev_win, rows, path_to_row
--   persistent（跨 close/open 保留）：buf, root, opts, filter, _watches, _timer, _rescan_watches
--
-- close 时只关 win + 清 ephemeral；buf/树数据/fs_event/filter 全部留给下次 open 复用。
-- 这靠 Window.create_buf 设的 bufhidden='hide' 保证窗口关了 buf 不被销毁。

function M.is_open()
  if not state or not state.win or not state.buf then return false end
  if not vim.api.nvim_win_is_valid(state.win) then return false end
  if not vim.api.nvim_buf_is_valid(state.buf) then return false end
  if vim.api.nvim_win_get_buf(state.win) ~= state.buf then return false end
  return true
end

-- buf 被真正销毁（用户 :bwipe 或 nvim 退出）→ 整个 state 报废
local function on_buf_wiped()
  if not state then return end
  pcall(Watch.detach, state)
  pcall(Preview.detach, state)
  pcall(Git.detach, state)
  pcall(Diagnostics.detach, state)
  state = nil
end

-- 只关窗口，保留 state 里所有 persistent 字段，fs_event 继续在后台跑
local function close_window_only()
  if not state then return end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    Window.close_win(state.win)
  end
  state.win = nil
  state.prev_win = nil
  state.rows = nil
  state.path_to_row = nil
end

---@param opts {cwd?:string}?
function M.open(opts)
  opts = opts or {}
  if M.is_open() then
    vim.api.nvim_set_current_win(state.win)
    return
  end

  -- 场景 A：state 有效但窗口关了 → 复用 buf + 树数据 + fs_event
  if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    local win, prev = Window.open_split(state.buf, state.opts or config)
    state.win = win
    state.prev_win = prev
    Tree.refresh(state.root) -- 隐藏期间 fs_event 一直在跑，多一次 refresh 也 cheap
    Render.render(state)
    vim.api.nvim_create_autocmd('WinClosed', {
      pattern = tostring(win),
      once = true,
      callback = close_window_only,
    })
    return
  end

  -- 场景 B：首次打开（或 buf 被销毁过）→ 完整创建
  local cwd = opts.cwd or config.cwd or vim.fn.getcwd()
  local buf = Window.create_buf()
  local win, prev = Window.open_split(buf, config)

  state = {
    buf = buf,
    win = win,
    prev_win = prev,
    root = Tree.new_root(cwd),
    opts = vim.tbl_deep_extend('force', {}, config),
  }
  state.on_after_render = function(s)
    if s._rescan_watches then s._rescan_watches() end
  end

  apply_keymaps(state)
  setup_cursor_snap(state)
  if config.preview then Preview.attach(state) end
  if config.watch then Watch.attach(state) end
  if config.git.enabled then Git.attach(state) end
  if config.diagnostics.enabled then Diagnostics.attach(state) end

  Render.render(state)

  if config.trash.enabled and config.trash.scan_on_open then
    Trash.scan_size(function(bytes)
      local mb = bytes / (1024 * 1024)
      if mb > config.trash.warn_size_mb then
        vim.notify(
          string.format('vv-explorer: trash %.0f MB, consider :VVExplorerTrash to clean', mb),
          vim.log.levels.WARN
        )
      end
    end)
  end

  -- 用户手动关窗（:q / <C-w>q）→ 走 close_window_only（保留 state）
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = close_window_only,
  })
  -- buf 真被销毁（:bwipe 或 nvim 退出）→ 清 state 彻底
  vim.api.nvim_create_autocmd({ 'BufWipeout' }, {
    buffer = buf,
    once = true,
    callback = on_buf_wiped,
  })
end

function M.close()
  close_window_only()
end

---@param opts {cwd?:string}?
function M.toggle(opts)
  if M.is_open() then M.close() else M.open(opts) end
end

---@param opts {file?:string}?
function M.reveal(opts)
  opts = opts or {}
  local file = opts.file or vim.api.nvim_buf_get_name(0)
  if file == '' or vim.fn.filereadable(file) == 0 and vim.fn.isdirectory(file) == 0 then
    if not M.is_open() then M.open() end
    M.focus()
    return
  end

  if not M.is_open() then M.open() end
  if not state then return end

  if Tree.expand_to(state.root, file) then
    Render.render(state)
    -- 找最深的可达行（reveal target 可能被分组合并到上层）
    local p = vim.fs.normalize(file)
    local lnum
    while p ~= '' do
      lnum = state.path_to_row[p]
      if lnum then break end
      local parent = vim.fs.dirname(p)
      if parent == p then break end
      p = parent
    end
    if lnum then
      vim.api.nvim_win_set_cursor(state.win, { lnum, 0 })
    end
  end
  M.focus()
end

function M.focus()
  if M.is_open() then vim.api.nvim_set_current_win(state.win) end
end

return M

-- vv-explorer configuration schema, defaults, and normalization

local M = {}

---@class VVExplorerFilterConfig
---@field custom string[] 永久隐藏的 glob 列表（独立于 `.` toggle），如 {'node_modules', '.DS_Store'} @default {}
---@field max_results integer 最大搜索结果数，避免渲染卡死 @default 1000
---@field debounce_threshold integer 文件数达到此阈值时开始动态防抖（默认 5000，以下 0ms） @default 5000
---@field debounce_max_ms integer 防抖延迟的最高封顶值（毫秒，默认 500） @default 500

---@class VVExplorerGitConfig
---@field enabled boolean 启用 git 状态索引（走 `git status --porcelain --ignored`，非 git 仓库自动 no-op） @default true
---@field show_ignored boolean 是否显示 .gitignore 命中的路径（`I` 键切换） @default false

---@class VVExplorerDiagnosticsConfig
---@field enabled boolean 订阅 LSP 诊断并在行尾显示 vv-icons 诊断图标和数量 @default true

---@class VVExplorerGlobalMappings
---@field toggle string|false 打开/关闭文件树的全局键位（false 禁用） @default '<leader>E'
---@field reveal string|false 展开到并高亮当前 buffer 对应文件的全局键位 @default '<leader>e'

---@class VVExplorerBinaryConfig
---@field intercept boolean 拦截二进制文件：不在 nvim 打开，改用系统默认程序 @default true
---@field extensions table<string, boolean> 视为二进制的扩展名集合（小写 key） @default { png = true, jpg = true, ... }

---@class VVExplorerExecuteConfig
---@field enabled boolean 启用 `X` 执行光标文件 @default true
---@field confirm boolean 执行前弹确认框（显示将运行的命令，安全） @default true
---@field run fun(cmd:string[], ctx:table)? 自定义运行器（ctx 含 path/cwd/runner）；缺省用原生分屏终端 @default nil
---@field opts VVExecConfig? 透传给 vv-utils.exec.resolve（运行器优先级 / shebang 等） @default {}

---@class VVExplorerTrashConfig
---@field enabled boolean 启用回收站 @default true
---@field max_items integer 回收站最大项目数 @default 5000
---@field warn_size_mb integer 打开面板时触发容量提醒的阈值 @default 500
---@field scan_on_open boolean 打开 explorer 时检查回收站容量 @default true

---@class VVExplorerConfig
---@field position 'left'|'right' @default 'left'
---@field width integer @default 32
---@field state VVStateHandle? 持久状态容器；默认注册 `vv-explorer/panel`
---@field persist_open boolean 跨 Neovim 会话恢复上次的打开状态 @default true
---@field hidden boolean 显示 dotfile（`.` 开头） @default false
---@field group_empty_dirs boolean 单链 dir 合并显示 @default true
---@field preview boolean VSCode 风单击预览 @default true
---@field preview_debounce_ms integer 预览防抖延迟（毫秒），光标停顿后才触发预览；0 = 不防抖 @default 138
---@field watch boolean libuv fs_event 自动刷新 @default true
---@field follow_file boolean 切换 buffer 时自动在树中展开并高亮对应文件（不抢焦点） @default true
---@field follow_file_debounce_ms integer follow_file BufEnter 防抖延迟（毫秒），用于快速 buffer 切换场景；0 = 不防抖 @default 0
---@field cwd string? 默认根目录（nil → vim.fn.getcwd()） @default nil
---@field sync_cwd_on_cd 'tab'|'global'|false `]`/`[` 切根时把 cwd 同步到新根，让 telescope / grep / `:terminal` / vv-git 跟随；`'tab'` = `tcd`（只影响 explorer 所在 tab），`'global'` = `cd`（整个 nvim），`false` = 不动 cwd @default 'tab'
---@field icon_rules VVExplorerIconRule[] @default {}
---@field filter VVExplorerFilterConfig @default { custom = {}, max_results = 1000, debounce_threshold = 5000, debounce_max_ms = 500 }
---@field git VVExplorerGitConfig|boolean @default { enabled = true, show_ignored = false }
---@field diagnostics VVExplorerDiagnosticsConfig|boolean @default { enabled = true }
---@field binary VVExplorerBinaryConfig @default { intercept = true, extensions = { ... } }
---@field execute VVExplorerExecuteConfig|boolean `X` 按文件类型执行光标文件 @default { enabled = true, confirm = true, opts = {} }
---@field trash VVExplorerTrashConfig|boolean @default { enabled = true, max_items = 5000, warn_size_mb = 500, scan_on_open = true }
---@field select_move_down boolean 多选时 Tab 切换选中后自动将光标下移一行 @default true
---@field lsp_rename_timeout_ms integer rename 时 willRenameFiles 请求的超时毫秒数，超时后继续执行文件重命名 @default 5000
---@field global_mappings VVExplorerGlobalMappings|false 全局快捷键（整个 nvim 范围）；设 false 禁用所有 @default { toggle = '<leader>E', reveal = '<leader>e' }
---@field mappings table<string, string|false|fun(state:table)> 树 buffer 内的 normal 模式键位表；value 可为内置 action 名、false 禁用、或自定义函数（接收 state） @default { ... }

---@class VVExplorerResolvedConfig: VVExplorerConfig
---@field git VVExplorerGitConfig
---@field diagnostics VVExplorerDiagnosticsConfig
---@field execute VVExplorerExecuteConfig
---@field trash VVExplorerTrashConfig

local defaults = {
  position = 'left',
  width = 32,
  state = nil,
  persist_open = true,
  hidden = false,
  group_empty_dirs = true,
  preview = true,
  preview_debounce_ms = 138,
  watch = true,
  follow_file = true,
  follow_file_debounce_ms = 0,
  select_move_down = true,
  lsp_rename_timeout_ms = 5000,
  cwd = nil,
  sync_cwd_on_cd = 'tab',
  icon_rules = {},
  filter = { custom = {}, max_results = 1000, debounce_threshold = 5000, debounce_max_ms = 500 },
  git = { enabled = true, show_ignored = false },
  diagnostics = { enabled = true },
  binary = {
    intercept = true,
    extensions = {
      -- image
      png = true, jpg = true, jpeg = true, gif = true, webp = true, avif = true,
      bmp = true, ico = true, tiff = true, tif = true, psd = true, raw = true,
      heic = true, heif = true, svgz = true,
      -- video
      mp4 = true, mkv = true, avi = true, mov = true, wmv = true, flv = true, webm = true,
      -- audio
      mp3 = true, wav = true, flac = true, aac = true, ogg = true, wma = true, m4a = true,
      -- archive
      zip = true, tar = true, gz = true, tgz = true, bz2 = true, tbz2 = true, xz = true, txz = true,
      ['7z'] = true, rar = true, zst = true, lz4 = true, lzma = true,
      jar = true, war = true, ear = true,
      deb = true, rpm = true, dmg = true, iso = true, apk = true, ipa = true,
      -- compiled / object
      exe = true, dll = true, so = true, dylib = true, o = true, a = true, class = true, pyc = true,
      wasm = true, bin = true,
      -- font
      ttf = true, otf = true, woff = true, woff2 = true, eot = true,
      -- document (binary)
      pdf = true, doc = true, docx = true, xls = true, xlsx = true, ppt = true, pptx = true,
      -- database
      sqlite = true, db = true,
    },
  },
  execute = {
    enabled = true,
    confirm = true,
    opts = {},
  },
  trash = {
    enabled = true,
    max_items = 5000,
    warn_size_mb = 500,
    scan_on_open = true,
  },
  global_mappings = {
    toggle = '<leader>E',
    reveal = '<leader>e',
  },
  mappings = {
    ['<C-e>'] = 'scroll_preview_down',
    ['<C-y>'] = 'scroll_preview_up',
    ['<CR>'] = 'open',
    ['l'] = 'open',
    ['gf'] = 'open',
    ['o'] = 'system_open',
    ['<LeftRelease>'] = function(state)
      local Actions = require('vv-explorer.actions')
      local node = Actions.node_under_cursor(state)
      if node and node.is_dir then Actions.open(state) end
    end,
    ['<RightMouse>'] = function(state)
      local pos = vim.fn.getmousepos()
      if pos.line > 0 then
        pcall(vim.api.nvim_win_set_cursor, state.win, { pos.line, 0 })
      end
      require('vv-explorer.actions').yank_abs_path(state)
    end,
    ['h'] = 'close_node',
    ['<Right>'] = 'open',
    ['<Left>'] = 'close_node',
    ['<C-l>'] = 'chain_select_deeper',
    ['<C-h>'] = 'chain_select_shallower',
    ['.'] = 'toggle_hidden',
    ['<M-.>'] = 'toggle_hidden',
    ['I'] = 'toggle_gitignored',
    ['<M-i>'] = 'toggle_gitignored',
    ['R'] = 'refresh',
    ['Y'] = 'yank_abs_path',
    [']'] = 'cd_to',
    ['['] = 'cd_up',
    ['/'] = 'start_filter',
    ['<Esc>'] = 'escape',
    ['q'] = '__quit',
    ['g?'] = 'help',
    ['<C-x>'] = 'open_split',
    ['<C-v>'] = 'open_vsplit',
    ['gx'] = 'system_open',
    ['X'] = 'execute',
    ['a'] = 'create',
    ['d'] = 'delete',
    ['r'] = 'rename',
    ['y'] = 'copy_mark',
    ['x'] = 'cut_mark',
    ['p'] = 'paste',
    ['<Tab>'] = 'toggle_select',
    ['T'] = 'trash_panel',
  },
}

---@param value any
---@return boolean
function M.is_valid_width(value)
  return type(value) == 'number' and value > 0 and value % 1 == 0
end

---@param opts VVExplorerConfig?
---@return VVExplorerResolvedConfig
function M.resolve(opts)
  local configured_state = opts and opts.state
  local config = vim.tbl_deep_extend('force', {}, defaults, opts or {})
  config.state = configured_state

  for _, key in ipairs({ 'trash', 'git', 'diagnostics', 'execute' }) do
    if config[key] == false then
      config[key] = { enabled = false }
    elseif config[key] == true then
      config[key] = vim.tbl_deep_extend('force', {}, defaults[key])
    end
  end

  ---@cast config VVExplorerResolvedConfig
  return config
end

return M

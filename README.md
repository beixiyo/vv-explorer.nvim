<h1 align="center">vv-explorer.nvim</h1>

<p align="center">
  <em>VSCode 风的 Neovim 文件树 — 实时预览、fd 异步过滤、回收站、零第三方依赖</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Neovim-0.10+-57A143?style=flat-square&logo=neovim&logoColor=white" alt="Requires Neovim 0.10+" />
  <img src="https://img.shields.io/badge/Lua-2C2D72?style=flat-square&logo=lua&logoColor=white" alt="Lua" />
</p>

---

## 为什么要这个插件

| | neo-tree / nvim-tree | vv-explorer |
|---|---|---|
| **实时预览** | 需要额外配置或不支持 | `j`/`k` 移动即时切换文件预览，`<CR>` 固定 |
| **过滤体验** | 无 / 基础 | fd 异步索引 + 三模式（fuzzy / glob / regex）+ 逐字高亮 + 祖先链保持 |
| **空目录折叠** | neo-tree 支持 | 支持，`a/b/c/` 单链合并显示 |
| **回收站** | 依赖额外插件 | 内置，支持恢复、大小警告、面板 UI |
| **依赖** | plenary / nui | 零第三方依赖，仅需 `vv-utils.nvim`（共享库） |
| **多 source** | buffers / git_status / ... | 只做文件树，全 repo picker 交给 Telescope / fzf |

## 安装

```lua
{
  'beixiyo/vv-explorer.nvim',
  dependencies = {
    'beixiyo/vv-utils.nvim',
    'beixiyo/vv-icons.nvim',
    -- 可选：彩色文件图标
    { 'echasnovski/mini.icons', opts = {} },
  },
  keys = { '<leader>e', '<leader>E' },
  ---@type VVExplorerConfig
  opts = {},
}
```

## 配置

所有选项及默认值：

```lua
---@type VVExplorerConfig
opts = {
  position = 'left',           -- 'left' | 'right'
  width = 32,                  -- 窗口宽度
  hidden = false,              -- 显示 dotfile（'.' 键切换）
  group_empty_dirs = true,     -- 单链目录合并
  preview = true,              -- VSCode 风单击预览
  watch = true,                -- libuv fs_event 自动刷新
  cwd = nil,                   -- 根目录（nil = vim.fn.getcwd()）
  icon_rules = {},             -- 自定义图标规则

  filter = {
    custom = {},               -- 永久隐藏 glob，如 { 'node_modules', '.DS_Store' }
  },

  git = {
    enabled = true,            -- 异步 git status 索引（非 git 仓库自动 no-op）
    show_ignored = false,      -- 显示 .gitignore 命中的路径（'I' 键切换）
  },

  diagnostics = {
    enabled = true,            -- LSP 诊断行尾符号（E/W/I/H）
  },

  trash = {
    enabled = true,            -- 删除时移入回收站而非真删
    max_items = 5000,          -- 回收站最大条目数，超出自动清理最旧的
    warn_size_mb = 500,        -- 打开 explorer 时若超过此大小则弹警告
    scan_on_open = true,       -- 启动时异步扫描回收站大小
  },

  global_mappings = {          -- 设 false 禁用全部全局键位
    toggle = '<leader>e',      -- 打开/关闭文件树
    reveal = '<leader>E',      -- 在树里定位当前 buffer
  },

  mappings = { ... },          -- 树内 buffer 键位（见下方键位表）
}
```

### 过滤（`/` 键触发）

需要 [`fd`](https://github.com/sharkdp/fd) 外部命令。三种搜索模式通过 `<S-Tab>` 切换：

| 模式 | 引擎 | 说明 |
|------|------|------|
| **fuzzy** | `vim.fn.matchfuzzypos` | 逐字位置高亮（默认） |
| **glob** | `vim.glob.to_lpeg` | 不含 `/` 时自动跨段（`*.lua` ≡ `**/*.lua`） |
| **regex** | `string.find` | Lua pattern |

### 回收站

删除的文件移入 `~/.local/share/vv-explorer/trash/`，附带元数据（原始路径、时间、大小）用于恢复。按 `T` 或 `:VVExplorerTrash` 打开回收站面板。

| 选项 | 默认值 | 说明 |
|------|--------|------|
| `trash.enabled` | `true` | `false` = 真删（不走回收站） |
| `trash.max_items` | `5000` | 超出时自动清理最旧条目 |
| `trash.warn_size_mb` | `500` | 打开 explorer 时异步扫描，超过则弹通知 |
| `trash.scan_on_open` | `true` | 是否启用启动时扫描 |

设 `trash = false` 可完全禁用回收站。

### 自定义图标规则

```lua
icon_rules = {
  { glob = '**/*.{test,spec}.{ts,tsx}', icon = '', hl = 'DiagnosticOk' },
  { glob = '.env*',                     icon = '', hl = 'WarningMsg' },
  { pattern = '^README',                icon = '', hl = 'Title', scope = 'file' },
}
```

`scope`：`'file'` / `'directory'` / `'any'`（默认）。优先级：icon_rules > mini.icons > 内置默认

## 键位

### 树内

| 键 | 动作 | 说明 |
|----|------|------|
| `<CR>` / `l` / `o` | `open` | 打开文件 / 切换目录展开 |
| 单击 | 展开/收起目录 | 文件不动，走预览 |
| 右键 | `yank_abs_path` | 复制绝对路径到剪贴板 |
| `h` | `close_node` | 关闭目录 / 跳到父目录 |
| `=` | `cd_to` | 把光标目录设为根 |
| `-` | `cd_up` | 返回上级 |
| `/` | `start_filter` | 打开过滤提示框 |
| `<Esc>` | `escape` | 清 filter → 清选区 → 关树 |
| `q` | `__quit` | 清 filter 或关树 |
| `.` | `toggle_hidden` | 切换 dotfile 显隐 |
| `I` | `toggle_gitignored` | 切换 gitignored 显隐 |
| `R` | `refresh` | 强制刷新 |
| `Y` | `yank_abs_path` | 复制路径（多选时复制所有） |
| `<C-x>` | `open_split` | 水平分屏打开 |
| `<C-v>` | `open_vsplit` | 垂直分屏打开 |
| `<C-t>` | `open_tab` | 新 tab 打开 |
| `gx` | `system_open` | 系统默认程序打开 |
| `a` | `create` | 新建文件（尾随 `/` 为目录） |
| `d` | `delete` | 删除 / 移入回收站（带确认） |
| `r` | `rename` | 重命名 |
| `y` | `copy_mark` | 标记复制 |
| `x` | `cut_mark` | 标记剪切 |
| `p` | `paste` | 粘贴到光标目录 |
| `<Tab>` | `toggle_select` | 切换多选 |
| `T` | `trash_panel` | 打开回收站面板 |
| `<C-e>` / `<C-y>` | 滚动预览 | 滚动主窗口预览 |
| `g?` | `help` | 键位帮助浮窗 |

### 过滤提示框

| 键 | 动作 |
|----|------|
| `<S-Tab>` | 切换搜索模式（fuzzy → glob → regex） |
| `<C-n>` / `<C-p>` | 跳到下/上一个匹配 |
| `<C-x>` / `<C-v>` | 以 split / vsplit 打开匹配 |
| `<CR>` | 提交（跳到首个匹配） |
| `<Esc>` / `q` | 取消过滤 |

### 回收站面板

| 键 | 动作 |
|----|------|
| `r` / `<CR>` | 恢复到原路径 |
| `d` | 永久删除条目 |
| `D` | 清空回收站（带确认） |
| `q` / `<Esc>` | 关闭 |

## 命令

| 命令 | 说明 |
|------|------|
| `:VVExplorerToggle` | 打开/关闭文件树 |
| `:VVExplorerOpen` | 打开文件树 |
| `:VVExplorerClose` | 关闭文件树 |
| `:VVExplorerReveal` | 在树里定位当前文件 |
| `:VVExplorerFocus` | 聚焦到树窗口 |
| `:VVExplorerTrash` | 打开回收站面板 |

## 依赖

- **必须**：[vv-utils.nvim](https://github.com/beixiyo/vv-utils.nvim) — 共享 fs/git/UI 工具库
- **必须**：[vv-icons.nvim](https://github.com/beixiyo/vv-icons.nvim) — 共享图标注册表
- **可选**：[mini.icons](https://github.com/echasnovski/mini.icons) — 彩色文件/目录图标
- **可选**：[fd](https://github.com/sharkdp/fd) — 仅 `/` 过滤功能需要

## License

MIT

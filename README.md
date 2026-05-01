<h1 align="center">vv-explorer.nvim</h1>

<p align="center">
  <em>VSCode 风的 Neovim 文件树 — 实时预览、fd 异步过滤、零第三方依赖</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Neovim-0.10+-57A143?style=flat-square&logo=neovim&logoColor=white" alt="Requires Neovim 0.10+" />
  <img src="https://img.shields.io/badge/Lua-2C2D72?style=flat-square&logo=lua&logoColor=white" alt="Lua" />
</p>

---

## 为什么要这个插件

用过 neo-tree / nvim-tree，几个问题解决不了：

| | neo-tree / nvim-tree | vv-explorer |
|---|---|---|
| **实时预览** | 需要额外配置或不支持 | `j`/`k` 移动即时切换文件预览，`<CR>` 固定 |
| **过滤体验** | 无 / 基础 | fd 异步索引 + 三模式（fuzzy / glob / regex）+ 逐字高亮 + 祖先链保持 |
| **空目录折叠** | neo-tree 支持 | 支持，`a/b/c/` 单链合并显示 |
| **依赖** | plenary / nui | 零第三方依赖 |
| **多 source** | buffers / git_status / ... | 只做文件树，全 repo picker 交给 Telescope / fff.nvim |

## 安装

```lua
{
  'beixiyo/vv-explorer.nvim',
  dependencies = {
    'beixiyo/vv-utils.nvim',
    -- 可选：彩色文件图标
    { 'echasnovski/mini.icons', opts = {} },
  },
  keys = { '<leader>e', '<leader>E' },
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
      enabled = true,            -- git status 索引（非 git 仓库自动 no-op）
      show_ignored = false,      -- 显示 .gitignore 命中的路径（'I' 键切换）
    },
    diagnostics = {
      enabled = true,            -- LSP 诊断行尾符号（E/W/I/H）
    },
    global_mappings = {          -- 设 false 禁用全部全局键位
      toggle = '<leader>e',      -- 打开/关闭文件树
      reveal = '<leader>E',      -- 在树里定位当前 buffer
    },
  },
}
```

## 配置

| 选项 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `position` | `'left' \| 'right'` | `'left'` | 文件树窗口位置 |
| `width` | `integer` | `32` | 窗口宽度 |
| `hidden` | `boolean` | `false` | 是否显示 `.` 开头文件（`.` 键运行时切换） |
| `group_empty_dirs` | `boolean` | `true` | 单链空目录合并显示 `a/b/c/` |
| `preview` | `boolean` | `true` | `j`/`k` 即时预览文件，`<CR>` / 编辑操作升为固定 |
| `watch` | `boolean` | `true` | libuv `fs_event` 自动刷新（150ms 防抖） |
| `cwd` | `string?` | `nil` | 根目录，`nil` 时用 `vim.fn.getcwd()` |
| `icon_rules` | `VVExplorerIconRule[]` | `{}` | 自定义图标：`{ glob?, pattern?, icon, hl?, scope? }` |
| `filter.custom` | `string[]` | `{}` | 永久隐藏的 glob 列表，独立于 dotfile 切换 |
| `git.enabled` | `boolean` | `true` | 异步 `git status` 索引，行尾显示 `A/U/M/D/R/C/!` |
| `git.show_ignored` | `boolean` | `false` | 是否显示 `.gitignore` 命中的路径 |
| `diagnostics.enabled` | `boolean` | `true` | 订阅 LSP 诊断，行尾显示最高 severity 符号 |
| `global_mappings` | `table \| false` | `{ toggle, reveal }` | 全局键位；设 `false` 禁用全部 |
| `mappings` | `table` | *25 项* | 树内 buffer 键位，可逐项覆盖或设 `false` 禁用 |

### 过滤（`/` 键触发）

需要 [`fd`](https://github.com/sharkdp/fd) 外部命令。三种搜索模式通过 `<S-Tab>` 切换：

| 模式 | 引擎 | 说明 |
|------|------|------|
| **fuzzy** | `vim.fn.matchfuzzypos` | 逐字位置高亮（默认） |
| **glob** | `vim.glob.to_lpeg` | 不含 `/` 时自动跨段（`*.lua` ≡ `**/*.lua`） |
| **regex** | `string.find` | Lua pattern |

### 自定义图标规则

```lua
icon_rules = {
  { glob = '**/*.{test,spec}.{ts,tsx}', icon = '', hl = 'DiagnosticOk' },
  { glob = '.env*',                     icon = '', hl = 'WarningMsg' },
  { pattern = '^README',                icon = '', hl = 'Title', scope = 'file' },
}
```

`scope`: `'file'` / `'directory'` / `'any'`（默认）。优先级：icon_rules > mini.icons > 内置默认

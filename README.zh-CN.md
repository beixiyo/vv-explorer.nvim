<div align="center">
  <h1>vv-explorer.nvim</h1>
  <p><a href="./README.md">English</a> | 中文</p>
  <img src="./docs/assets/vv-explorer.png" alt="vv-explorer 演示" width="900" />
  <p>想要我的 Neovim 配置？查看 <a href="https://github.com/beixiyo/dotfiles">dotfiles</a></p>
  <em>VSCode 风的 Neovim 文件树 — 实时预览、fd 异步过滤、回收站、零第三方依赖</em>
  <p>
    <img src="https://img.shields.io/badge/Neovim-0.10+-57A143?style=flat-square&logo=neovim&logoColor=white" alt="Requires Neovim 0.10+" />
    <img src="https://img.shields.io/badge/Lua-2C2D72?style=flat-square&logo=lua&logoColor=white" alt="Lua" />
  </p>
</div>

---

## 依赖

- **必须**：[vv-utils.nvim](https://github.com/beixiyo/vv-utils.nvim) — 共享 fs/git/UI 工具库
- **必须**：[vv-icons.nvim](https://github.com/beixiyo/vv-icons.nvim) — 共享图标注册表
- **可选**：[mini.icons](https://github.com/echasnovski/mini.icons) — 彩色文件/目录图标
- **可选**：[fd](https://github.com/sharkdp/fd) — 仅 `/` 过滤功能需要
- **可选**：[Git](https://github.com/git/git) — 启用 Git 状态、忽略文件识别与 Git 感知过滤

## 为什么要这个插件

| | neo-tree / nvim-tree | snacks.explorer | vv-explorer |
|---|---|---|---|
| **打开方式** | 双击打开（默认）| 双击打开 | **单击**即展开 / 进入目录，符合直觉（文件仍走键盘 `<CR>` / `l`） |
| **实时预览** | 需额外配置或不支持 | 底部小窗预览，过小难看清 | `j`/`k` 移动即时切换文件防抖预览，`<CR>` 固定 |
| **过滤体验** | 无 / 基础 | picker 模糊匹配 | fd 异步索引 + 三模式（fuzzy / glob / regex）+ 逐字高亮 + 祖先链保持 |
| **空目录折叠** | neo-tree 支持 | — | 支持，`a/b/c/` 单链合并显示 |
| **回收站** | 依赖额外插件 | 系统回收站（`trash=true`，无面板 / 恢复 UI）| 内置面板：恢复、大小警告、浏览 UI |
| **打包方式** | 独立插件 + plenary / nui | 全家桶：与 dashboard / picker / notifier 等**同仓打包**，装一个带一堆 | 拆成独立小插件（vv-explorer / vv-utils / vv-icons），按需装、零第三方依赖 |
| **多 source** | buffers / git_status / ... | picker 多源（本就是 picker） | 只做文件树，全 repo picker 交给 Telescope / fzf |

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
  preview = true,              -- 不打开自动预览
  watch = true,                -- libuv fs_event 自动刷新
  select_move_down = true,     -- Tab 多选后自动将光标下移一行
  cwd = nil,                   -- 根目录（nil = vim.fn.getcwd()）
  icon_rules = {},             -- 自定义图标规则

  filter = {
    custom = {},               -- 永久隐藏 glob，如 { 'node_modules', '.DS_Store' }
    max_results = 1000,        -- 最大搜索结果数，避免渲染卡死
    debounce_threshold = 5000, -- 文件数达到此阈值时开始动态防抖（以下 0ms）
    debounce_max_ms = 500,     -- 防抖延迟的最高封顶值（毫秒）
  },

  git = {
    enabled = true,            -- 异步 git status 索引（非 git 仓库自动 no-op）
    show_ignored = false,      -- 显示 .gitignore 命中的路径（'I' 键切换）
  },

  diagnostics = {
    enabled = true,            -- LSP 诊断行尾图标 + 数量（vv-icons + Diagnostic* 颜色）
  },

  binary = {
    intercept = true,          -- 拦截二进制文件：不在 nvim 打开，改用系统默认程序
    extensions = {             -- 视为二进制的扩展名集合（小写 key）
      -- 默认含：图片（png/jpg/gif/webp/…）、视频（mp4/mkv/mov/…）、
      -- 音频（mp3/wav/flac/…）、压缩包（zip/tar/gz/7z/…）、
      -- 编译产物（exe/dll/so/o/…）、字体（ttf/otf/woff/…）、
      -- 二进制文档（pdf/docx/xlsx/pptx/…）、数据库（sqlite/db）
    },
  },

  trash = {
    enabled = true,            -- 删除时移入回收站而非真删
    max_items = 5000,          -- 回收站最大条目数，超出自动清理最旧的
    warn_size_mb = 500,        -- 打开 explorer 时若超过此大小则弹警告
    scan_on_open = true,       -- 启动时异步扫描回收站大小
  },

  global_mappings = {          -- 设 false 禁用全部全局键位
    toggle = '<leader>E',      -- 打开/关闭文件树（简单 Toggle）
    reveal = '<leader>e',      -- 定位当前文件（若已打开且聚焦则 Toggle）
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

删除的文件移入 `~/.local/share/vv-explorer/trash/`，附带元数据（原始路径、时间、大小）用于恢复。按 `T` 或 `:VVExplorerTrash` 打开回收站面板

| 选项 | 默认值 | 说明 |
|------|--------|------|
| `trash.enabled` | `true` | `false` = 真删（不走回收站） |
| `trash.max_items` | `5000` | 超出时自动清理最旧条目 |
| `trash.warn_size_mb` | `500` | 打开 explorer 时异步扫描，超过则弹通知 |
| `trash.scan_on_open` | `true` | 是否启用启动时扫描 |

设 `trash = false` 可完全禁用回收站

### 二进制文件拦截

默认开启。`<CR>`/`l`/`<C-x>`/`<C-v>` 遇到二进制文件时，不在 nvim 内 `:edit`，改用系统默认程序打开；预览（`preview = true`）也会跳过二进制文件

```lua
-- 放行图片（未来 nvim 原生支持图片预览时）
opts = {
  binary = {
    extensions = {
      png = false, jpg = false, jpeg = false,
      gif = false, webp = false, avif = false,
    },
  },
}

-- 完全关闭拦截
opts = { binary = { intercept = false } }

-- 增加自定义扩展名
opts = { binary = { extensions = { sketch = true } } }
```

`extensions` 走 `vim.tbl_deep_extend`，只需写要覆盖的 key，不必重写整张表

### 执行文件（`X` 键）

按文件类型决定如何执行：**shebang > 扩展名优先级**（命令解析走 `vv-utils.exec.resolve`，取首个 `executable()` 的运行器）。默认 `confirm = true` 会先弹确认框显示将运行的命令

```lua
opts = {
  execute = {
    enabled = true,
    confirm = true,           -- 执行前确认（显示命令）；设 false 跳过
    -- 自定义运行器：默认开原生分屏终端；可改成浮动终端等
    run = function(cmd, ctx)  -- ctx = { path, cwd, runner }
      require('tools.term').run(cmd, ctx.cwd)
    end,
    -- 透传给 vv-utils.exec.resolve：增减扩展名 / 改优先级
    opts = {
      runners = {
        ts = { { 'bun', 'run' }, { 'tsx' } },  -- ts 优先 bun，其次 tsx
        rb = { { 'ruby' } },
      },
    },
  },
}
```

默认覆盖 `sh/bash/zsh/fish · ts/tsx/mts/cts · js/mjs/cjs · py · lua · rb · pl · php`，以及任何带可用 shebang 的文件

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
| `<CR>` / `l` / `→` | `open` | 打开文件 / 切换目录展开（`→` 同 `l`） |
| `↑` / `↓` | 移动 | 等同 `k` / `j`（上下，含首尾绕回） |
| 单击 | 展开/收起目录 | 文件不动，走预览 |
| 右键 | `yank_abs_path` | 复制绝对路径到剪贴板 |
| `h` / `←` | `close_node` | 关闭目录 / 跳到父目录（`←` 同 `h`） |
| `<C-l>` / `<C-h>` | 折叠链选段 | 折叠空目录链行上往深 / 往浅选中目标层级（见下方「折叠空目录链选段」） |
| `]` | `cd_to` | 进入：把光标目录设为根 |
| `[` | `cd_up` | 返回上级 |
| `/` | `start_filter` | 打开过滤提示框 |
| `<Esc>` | `escape` | 清 filter → 清选区 + 剪贴板标记（一起清）→ 关树 |
| `q` | `__quit` | 清 filter 或关树 |
| `.` / `<M-.>` | `toggle_hidden` | 切换 dotfile 显隐 |
| `I` / `<M-i>` | `toggle_gitignored` | 切换 gitignored 显隐 |
| `R` | `refresh` | 强制刷新 |
| `Y` | `yank_abs_path` | 复制绝对路径（多选时复制所有） |
| `<C-x>` | `open_split` | 水平分屏打开 |
| `<C-v>` | `open_vsplit` | 垂直分屏打开 |
| `o` / `gx` | `system_open` | 系统工具打开：目录→文件管理器，文件→默认程序 |
| `X` | `execute` | 按文件类型执行（确认后跑在终端） |
| `a` | `create` | 新建文件（尾随 `/` 为目录） |
| `d` | `delete` | 删除 / 移入回收站（带确认） |
| `r` | `rename` | 重命名 |
| `y` | `copy_mark` | 标记复制 |
| `x` | `cut_mark` | 标记剪切 |
| `p` | `paste` | 粘贴到光标目录 |
| 拖拽 | — | 从文件管理器拖文件/文件夹进来复制（详见下方「拖拽落点」） |
| `<Tab>` | `toggle_select` | 切换多选 |
| `T` | `trash_panel` | 打开回收站面板 |
| `<C-e>` / `<C-y>` | 滚动预览 | 滚动主窗口预览 |
| `g?` | `help` | 键位帮助浮窗 |

### 折叠空目录链选段（chain segment）

`group_empty_dirs = true` 时单链空目录（如 `test/n1/n2`）合并成一行，操作默认作用于**最深段**。用 `<C-l>` / `<C-h>` 往深 / 往浅选中某一层（高亮显示），之后 `a` / `d` / `r` / `y` / `x` / `p` 都作用于**所选层级**：

```
test/n1/n2   ← 默认（最深段）
test/n1      ← <C-h> 一次
test         ← 再一次
```

- 未选时 = 最深段（同原行为）；`a` 创建预填到所选层级，不用退格；光标离开该行自动复位
- 导航 `l` / `h` / `<CR>` / `←` / `→` 始终作用整行，不受选段影响
- 部分终端 `<C-h>` 被当 `<BS>`、往浅失效，属终端限制，可改用 `<C-l>`

### 拖拽落点（drag-and-drop）

从系统文件管理器（Finder 等）把**文件 / 文件夹**拖进 explorer 窗口即复制进来。支持多选、文件夹（递归复制）

两种模式，**按环境自动选择**：

| 环境 | 行为 |
|------|------|
| **kitty ≥ 0.47 且 nvim 不挂 tmux** | VSCode 风：按**鼠标松手的落点目录**复制，拖拽经过时**实时高亮**目标目录行（走 kitty DnD 协议 OSC 72） |
| **tmux / 其它终端** | 自动降级：复制到**键盘光标所在目录**、无高亮（走 bracketed paste）。tmux 不透传入站 OSC 72，这是 tmux 的限制，非本插件可绕过 |

- **安全**：目标已存在同名文件/目录时**自动改名** `xxx (copy)` / `xxx (copy 2)`，**绝不覆盖或删除**任何已存在内容
- **为何落点需脱 tmux**：落点坐标由终端经 OSC 72 上报，tmux 作为中间终端模拟器不转发该入站序列（kitty DnD 协议留有 `i=` 多路复用器字段，需 tmux 侧实现，目前尚无）。无坐标时退回光标目录方案
- 关闭落点协议、只保留粘贴回退：`require('vv-utils.drop').setup({ kitty_dnd = false })`

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

## License

MIT

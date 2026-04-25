# vv-explorer.nvim

VSCode 风的 Neovim 文件树，自实现，零第三方依赖

只做"侧栏 + 当前视图过滤"。全 repo picker 请搭配 [fff.nvim](https://github.com/dmtrKovalenko/fff.nvim) / Telescope 使用

## 为什么造这个轮子

用过 neo-tree / nvim-tree，两个问题解决不了：

- **UI 无法按 VSCode 手感定制**：jk 移动时自动预览、`group_empty_dirs`（`a/b/c/` 单链合并）同时要、又不想带一坨多 source（buffers / git_status / ...）
- **依赖膨胀**：plenary / nui 加起来为了几棵树不值得
- **过滤体验**：想要 fd 异步索引 + `matchfuzzypos` 字符级高亮 + 祖先链保持，没有现成的

## 特性

- **单 source 文件树**，`<leader>e` 开/关，`<leader>E` reveal 当前 buffer
- **VSCode 风单击预览**：`j/k` 即时换文件，`<CR>` 或编辑操作自动固定
- **空目录折叠**（`group_empty_dirs`，单链 `a/b/c/` 合并显示）
- **libuv fs_event 自动刷新**（150ms 防抖）
- **`/` 全树模糊过滤**：fd 异步索引 + `matchfuzzypos` + 字符位置高亮 + 祖先链保持（fd 缺失走英文提示，不自动 fallback）
- **git 状态**：异步 `git status --porcelain -z --ignored` 索引，行尾显示 `A/U/M/D/R/C/!` 符号（颜色对齐 VSCode gitDecoration.*），`.gitignore` 命中的路径暗色；`I` 切换显隐
- **LSP 诊断**：订阅 `DiagnosticChanged`，行尾显示 `E/W/I/H`（按最高 severity）
- **暗色路径**：dotfile（`.` 开头）+ gitignored 路径用 `VVExplorerDim`（默认 link `Comment`）
- **永久隐藏 glob**：`filter.custom` 独立于 `.` toggle，写死 `node_modules` 之类
- **`g?` help 浮窗**：反读 buffer mappings，永远和实际绑定一致
- **CRUD**：新建 / 删除 / 重命名，支持嵌套路径 `a/b/c.ts`；重命名会同步同名 nvim buffer
- **剪贴板**：yank / cut / paste（yazi/vim 风格），冲突追加 ` (copy)` 后缀
- **批量选择**：`<Tab>` 切换，批量动作自动作用于选区
- **图标走 mini.icons**，叠加用户 glob / Lua pattern 规则
- **目录行 chevron**：icon 左侧画展开/折叠箭头，槽位用 `strdisplaywidth` 补齐到 2 列（抗 1-col / 2-col glyph 混排）

## 依赖

- Neovim 0.10+（`vim.uv` / `vim.fs` / `vim.glob` / `matchfuzzypos`）
- 可选：[mini.icons](https://github.com/nvim-mini/mini.icons) —— 不装时所有文件统一显示 ``、目录 ``；装了则按 filetype / extension 渲染彩色图标
- 可选：[`fd`](https://github.com/sharkdp/fd) —— `/` 过滤需要，缺失时提示安装

## 安装

lazy.nvim（推荐同时装 mini.icons 获得彩色图标）：

```lua
{
  'beixiyo/vv-explorer.nvim',
  dependencies = {
    'beixiyo/vv-utils.nvim',
    -- 可选：彩色文件图标
    {
      'nvim-mini/mini.icons',
      opts = {},
      config = function(_, opts)
        require('mini.icons').setup(opts)
        MiniIcons.mock_nvim_web_devicons()  -- 让其它老插件也用同一份图标
      end,
    },
  },
  keys = { '<leader>e', '<leader>E' },
  -- setup 空表就够：git / diagnostics / 全局键位 都默认开
  opts = {},
}
```

## 配置

### 默认行为（开箱即用，`setup({})` 就够）

| 功能 | 默认 | 说明 |
|---|---|---|
| 全局键位 `<leader>e` / `<leader>E` | ✅ 开 | 打开/关闭 & reveal 当前文件（展开到并跳光标 + 切焦点到树） |
| `git` 状态 + ignored 暗色 | ✅ 开 | 走 `git status --porcelain --ignored`；非 git 仓库自动 no-op |
| `diagnostics` 行尾符号 | ✅ 开 | 订阅 `DiagnosticChanged`，最高 severity 显 `E/W/I/H` |
| VSCode 风单击预览 | ✅ 开 | `j/k` 即时换文件；`<CR>` / 编辑操作升为固定 |
| `fs_event` 自动刷新 | ✅ 开 | libuv 监听 + 150ms debounce |
| 空目录折叠 | ✅ 开 | `a/b/c/` 单链合并 |
| 显示 dotfile / gitignored | ❌ 关 | `.` / `I` 键按需切换 |
| `filter.custom` 永久隐藏 | ❌ 空 | 用户可填 `{ 'node_modules', '.DS_Store' }` 之类 |

### 完整默认值

```lua
require('vv-explorer').setup({
  position = 'left',            -- 'left' | 'right'
  width = 32,
  hidden = false,               -- 显示 . 开头（`.` 键切换）
  group_empty_dirs = true,      -- 单链目录合并
  preview = true,               -- VSCode 风单击预览
  watch = true,                 -- fs_event 自动刷新
  cwd = nil,                    -- 默认用 vim.fn.getcwd()
  icon_rules = {},              -- 见"自定义图标"
  filter = {
    custom = {},                -- 永久隐藏 glob，如 { 'node_modules', '.DS_Store' }
  },
  git = {
    enabled = true,             -- 走 `git status --porcelain --ignored`；非 git 仓自动 no-op
    show_ignored = false,       -- 是否显示 .gitignore 命中的路径（`I` 键切换）
  },
  diagnostics = {
    enabled = true,             -- 订阅 LSP 诊断并在行尾显示符号
  },
  global_mappings = {
    toggle = '<leader>e',       -- 打开/关闭文件树
    reveal = '<leader>E',       -- 在树里定位当前 buffer 对应的文件
    -- 整个 field 设 false 可禁用全部全局键位；单项设 false 只禁单个
  },
  mappings = { ... },           -- 树 buffer 内的 normal 键位，见下节
})
```

## 键位

全部是树内 buffer 的 `n` 模式映射，参考 yazi / vim 传统

### 导航

| 键 | 动作 |
|---|---|
| `<CR>` / `l` / `o` / 双击 | 打开目录 / 打开文件 |
| `h` | 关闭目录 / 跳到父目录 |
| `.` | 切换显示 dotfile（yazi 风） |
| `I` | 切换显示 gitignored 路径（需 `git.enabled`） |
| `R` | 刷新（含 git 索引） |
| `-` | 上移根目录 |
| `<C-]>` | 把光标所在目录设为根 |
| `g?` | 帮助浮窗（列所有 mappings） |
| `<C-e>` | 向下滚动预览窗口 |
| `<C-y>` | 向上滚动预览窗口 |
| `q` | 关树 |

### 打开方式

| 键 | 动作 |
|---|---|
| `<C-x>` | 水平分屏打开文件 |
| `<C-v>` | 垂直分屏打开文件 |
| `<C-t>` | 新 tab 打开文件 |
| `gx` | 系统默认程序打开（`xdg-open` / `open` / `start`） |
| `Y` | 复制绝对路径到 `+` |
| `<RightMouse>` | 右键复制绝对路径到 `+` |

### CRUD

| 键 | 动作 | 说明 |
|---|---|---|
| `a` | 新建 | 尾随 `/` 视为目录；支持嵌套 `foo/bar/baz.txt`，中间目录自动 `mkdir -p` |
| `d` | 删除 | 带确认；**批量作用于选区**，无选区回退到光标节点 |
| `r` | 重命名 | 单个；自动同步同名 nvim buffer（含目录下的子 buffer） |

### 剪贴板

| 键 | 动作 |
|---|---|
| `y` | yank（标记复制） |
| `x` | 标记剪切 |
| `p` | 粘贴到光标所在目录；同名追加 ` (copy)` / ` (copy 2)` 后缀 |

`cut` 到自身子孙目录会被拒绝（否则会丢数据）

### 批量选择

| 键 | 动作 |
|---|---|
| `<Tab>` | 切换选中（再按一次取消） |
| `<Esc>` | 优先级：有 filter 清 filter → 有选区清选区 |

选中项整行 Visual 底色。`y` / `x` / `d` 看到选区非空就对全部生效，否则只操作光标节点

### 过滤

| 键 | 动作 |
|---|---|
| `/` | 底部浮动输入框，实时过滤全树 |
| `<Esc>` | 关 filter（恢复正常视图） |

索引用 fd 构建，`matchfuzzypos` 打分 + 字符位置高亮，祖先链保持可见

## 自定义图标

图标走 [mini.icons](https://github.com/nvim-mini/mini.icons)（如果全局 setup 过）；再往上可以加 glob / Lua pattern 规则：

```lua
require('vv-explorer').setup({
  icon_rules = {
    -- glob: 用 vim.glob.to_lpeg 编译
    { glob = '**/*.{test,spec}.{ts,tsx,js,jsx}', icon = '', hl = 'DiagnosticOk' },
    { glob = '.env*', icon = '', hl = 'WarningMsg' },
    -- Lua pattern
    { pattern = '^README',                        icon = '', hl = 'Title', scope = 'file' },
    { pattern = '^docs$',                         icon = '', hl = 'Title', scope = 'directory' },
  },
})
```

`scope`: `'file'` / `'directory'` / `'any'`（默认）

规则匹配优先级：icon_rules（按顺序）> mini.icons > 内置默认

## 高亮组

全部 `default = true` link，colorscheme 可直接覆盖：

| 组 | 默认 | 用途 |
|---|---|---|
| `VVExplorerRoot` | `Title` | 根路径行 |
| `VVExplorerDir` | `Directory` | 目录名 |
| `VVExplorerFile` | `Normal` | 文件名 |
| `VVExplorerIndent` | `Comment` | chevron |
| `VVExplorerDim` | `Comment` | dotfile / gitignored 暗色 |
| `VVExplorerMatch` | `bg=#193d4c bold` | 过滤命中字符（逐字高亮：只改 bg，fg 透行色） |
| `VVExplorerSelected` | `Visual` | 批量选中整行底色 |
| `VVGitAdded` | fg `#81b88b` | `A` staged added（VSCode 绿） |
| `VVGitUntracked` | fg `#73c991` | `U` 未跟踪 `??`（VSCode 亮绿） |
| `VVGitModified` | fg `#e2c08d` | `M` 修改（VSCode 黄） |
| `VVGitDeleted` | fg `#c74e39` | `D` 删除（VSCode 红） |
| `VVGitRenamed` | fg `#73c991` | `R`/`C` 重命名 / 拷贝（VSCode 同 untracked 亮绿） |
| `VVGitConflict` | fg `#e4676b` bold | `!` 合并冲突（VSCode 红 bold） |
| `VVDiagError` | `DiagnosticError` | LSP error |
| `VVDiagWarn` | `DiagnosticWarn` | LSP warning |
| `VVDiagInfo` | `DiagnosticInfo` | LSP info |
| `VVDiagHint` | `DiagnosticHint` | LSP hint |

> 以上 `VVGit*` 是共享组，由 [`vv-utils.git.register_hl()`](https://github.com/beixiyo/vv-utils.nvim/blob/main/lua/vv-utils/git.lua) 注册，vv-explorer / vv-git / 其他 vendor 统一消费

## 公开 API

```lua
local ft = require('vv-explorer')
ft.setup(opts)           -- 配置 + 注册 :VVExplorer* 命令
ft.open({ cwd? })        -- 打开（已打开则聚焦）
ft.close()               -- 只关窗口，buf 和树数据保留
ft.toggle({ cwd? })
ft.reveal({ file? })     -- 展开到并定位指定文件（默认当前 buffer）
ft.focus()               -- 聚焦已打开的树窗口
ft.is_open()
```

## 用户命令

`:VVExplorerToggle` / `:VVExplorerOpen` / `:VVExplorerClose` / `:VVExplorerReveal` / `:VVExplorerFocus`

## 架构

13 个文件（fs 原语已抽到 [vv-utils.nvim](https://github.com/beixiyo/vv-utils.nvim) 共用）：

| 文件 | 职责 |
|---|---|
| `init.lua` | setup / 命令 / 默认高亮 / state 生命周期 |
| `tree.lua` | Node 数据结构 + `fs_scandir` + flatten（hidden / custom glob / ignored 三重过滤）+ expand_to |
| `render.lua` | 正常 / 过滤两条渲染路径，arrow/icon 槽位 `strdisplaywidth` 补齐；dim 判断 + 行尾 git/diag virt_text |
| `actions.lua` | open/close/toggle_hidden/toggle_gitignored/refresh/cd/filter/help + 打开方式 + yank + CRUD + 剪贴板 + 选区 |
| `preview.lua` | VSCode 风单击预览：CursorMoved + BufModifiedSet + find_main_win |
| `filter.lua` | fd 异步索引 + `matchfuzzypos` + 祖先链集合 |
| `prompt.lua` | 底部浮动 filter 输入框 + 实时过滤 + match count virt_text |
| `watch.lua` | `vim.uv.new_fs_event` + 150ms 防抖；同步触发 git 刷新 |
| `window.lua` | split 创建 + buffer/window 选项（`bufhidden='hide'` 让 buf 跨 close/open 存活） |
| `icons.lua` | 规则匹配（`vim.glob.to_lpeg` / Lua pattern）+ MiniIcons fallback |
| `git.lua` | 薄适配层：attach/detach + 200ms debounce；`vv-utils.git.index` 产出索引，转发 `symbol_for` |
| `diagnostics.lua` | 薄适配层：订阅 `DiagnosticChanged` → `vv-utils.diagnostics.collect_by_path` → render；转发 `symbol_for` |
| `help.lua` | `?` 浮窗：反读 buffer mappings（desc 前缀 `vv-explorer:`）列表展示 |

## 设计取舍

- **单 buffer 生命周期跨 close/open**：`bufhidden='hide'`，关树只关窗口，fs_event 继续后台跑，下次 `open` 秒显
- **filter 索引 fd-only**：不做 libuv fallback —— 没装 fd 就英文提示去 GitHub，避免 UX 分裂
- **rename 不走 `:saveas`**：直接 fs_rename + `nvim_buf_set_name`，保留 unsaved 状态
- **paste 永远非破坏**：冲突追加 ` (copy)` 后缀而非覆盖。如果要覆盖请先 `d` 删掉目标
- **cut 到自身子孙目录拒绝**：否则会丢数据
- **图标槽位固定 2 列**：MiniIcons 给的 folder 2-col / file 1-col 混排，用 `vim.fn.strdisplaywidth` 统一补齐，扛所有 nerd font

## 不做什么

- buffers / git_status / remote 等多 source 树 —— neo-tree 更适合
- 全 repo 模糊 picker —— 用 fff.nvim / Telescope
- 自己的 session 持久化 —— 靠 nvim 原生 `mksession` 和 `bufhidden='hide'` 跨 close/open 已经够用


## Testing

Smoke test (zero deps, runs in `-u NONE`):

```bash
nvim --headless -u NONE -l tests/test_smoke.lua
```

Expected: trailing line `X passed, 0 failed`.

## License

MIT

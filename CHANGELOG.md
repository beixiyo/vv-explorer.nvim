# Changelog

## [Unreleased]

### Fixed

- **回收站孤儿条目 crash**：trash 目录里若存在「数据文件在、配套 `.meta.json` 丢失」的孤儿条目（早先 `trash()` 中 rename 成功但 meta 写入失败被 pcall 吞、或 meta 被外部清理所致），`Trash.list()` 直接 `Fs.read_all` 该 meta → ENOENT error，连带 `enforce_max_items` 在每次删除后崩（`vim.schedule callback` 报错）。现把 meta 读取包 `pcall`，缺 meta 时按 `original_path='(unknown)'` 兜底列出，单个孤儿不再打挂整个 list/删除流程
- **树窗按 `gf` 报 E1513**：树 buffer `winfixbuf=true`，原生 `gf` 试图在锁定窗口切 buffer → `E1513: Cannot switch buffer`。现默认把 `gf` 映射为 `open`，与 `<CR>`/`l` 一致（打开节点 / 展开目录），走已处理 winfixbuf 的 `open_file` 路径

- **reveal 把光标跳到别处**：在被隐藏/过滤的文件（未跟踪 dotfile、gitignored、`.git/` 内文件）上按 `<leader>e` 时光标被带到别的文件。两处根因：① `find_row` 沿祖先回溯到最近可见目录行并强制定位 → 改 reveal/follow 用 strict 定位，只在目标文件**自身**那一行已渲染时归位（仍兼容 symlink 解析与 group_empty_dirs 合并目录），「hidden + git tracked」待 git 异步就绪后照常归位；② explorer buffer 跨 open/close 复用，定位失败时光标停在上一次的残留位置（如之前 follow 跟到的文件）→ 现 reveal 定位不到目标时把光标拉回根行

- **git 状态不刷新（外部变更）**：commit/push 等只动 `.git/`（index/HEAD）的操作不会在工作树目录上产生 fs_event，导致 watch.lua 监听不到、git 状态标记滞留。现订阅 vv-git 的 `User VVGitStatusChanged` 即时刷新，并叠加 `FocusGained`/`TermClose`/`TermLeave` 兜底外部工具（ClaudeCode/Codex 等直接跑 git）的场景；detach 时清理对应 augroup

### Added

- **方向键导航**：`↑/↓` 同 `j`/`k`（上/下，含首尾绕回）、`→` 同 `l`（进入文件/展开目录）、`←` 同 `h`（收起/回父级），照顾习惯方向键的用户
- **折叠空目录链选层操作**：被 `group_empty_dirs` 合并成一行的链（如 `test/n1/n2`）上，`C-l`/`C-h` 往深/往浅选层并高亮选中前缀段，选段会**贯穿所有单目标操作**——`d` 删除、`a` 创建...
- **LSP 文件重命名**：rename（`r`）时自动通知 LSP 服务端。流程：向支持 `workspace/willRenameFiles` 的客户端发异步请求 → apply 返回的 workspace edits（如更新 import 路径）→ 执行磁盘重命名 → 发 `workspace/didRenameFiles` 通知。无支持客户端时零开销直接重命名。等待期间在树行末尾显示 loading 动画（来自 `vv-utils.loading`），同时跳过该行 git/诊断图标渲染。`lsp_rename_timeout_ms`（默认 5000ms）可配，超时后英文 warn 并继续执行重命名。LSP 协议层独立于 `lua/vv-explorer/lsp.lua`

- **`X` 执行文件**：按文件类型（shebang / 扩展名优先级）解析运行器并在终端执行；执行前默认弹确认框显示命令（`execute.confirm` 可关），运行器可配（`execute.run`，默认原生分屏终端）；命令解析复用 `vv-utils.exec`
- **拖拽落点（VSCode 风）**：从文件管理器拖文件到 explorer，按**鼠标松手的落点目录**复制（拖拽经过时实时高亮目标目录行）。基于 kitty DnD 协议（OSC 72，kitty ≥ 0.47 且 nvim 不挂 tmux 时生效）；不支持的终端（tmux 等）自动回退到「复制到光标目录 / 打开文件」。多文件、同名自动重命名 `(copy N)`，**绝不覆盖/删除已存在文件或目录**
- **`<Esc>` 清剪贴板标记**：优先级 `filter > 选区+剪贴板 > 关树`，一键取消 cut/copy 标记
- **V 模式屏蔽**：树 buffer 里 `v`/`V` → `<Nop>`（`<C-v>` 仍是 vsplit）
- **鼠标 visual 屏蔽**：屏蔽 `<LeftDrag>` 和双击，避免触发选区
- **二进制文件拦截**：`binary.intercept`（默认开）遇二进制文件改用系统程序打开、预览跳过；内置 30+ 扩展名，`binary.extensions` 可增减
- **状态感应图标**：文件夹关闭/展开/空目录三态切换，对齐 snacks.nvim
- **特定目录展开态**：如 `src` 展开时换成展开态图标
- **鼠标操作**：单击展开/收起目录，右键复制绝对路径
- **大小写不敏感图标**：精确匹配失败时回退小写（`Components` → `components`）
- **回收站**：`d` 改为移入 `~/.local/share/vv-explorer/trash/` 不真删；`T` / `:VVExplorerTrash` 开面板（`r` 恢复 / `d` 永久删 / `D` 清空），可配 `trash.max_items`/`warn_size_mb`，`trash=false` 回退真删
- **剪贴板图标**：`x`/`y` 标记的文件行尾显示图标，粘贴后自动清除
- **多选复制路径**：`Y` 把所有选中路径复制到系统剪贴板
- **Tab 自动下移**：`<Tab>` 选中后自动移到下一行
- **删除后清理预览**：删除正在预览的文件时自动关闭对应 buffer
- **宽度持久化**：调整树宽后跨 session 记住
- **剪贴板 toggle 累加**：`x`/`y` toggle 文件进/出剪贴板，连按批量标记（Tab 多选后仍为批量替换）
- **预览防抖**：`preview_debounce_ms`光标停顿后才触发预览，避免快速移动时反复加载
- **follow_file 防抖**：`follow_file_debounce_ms`（默认 0）用于快速 buffer 切换场景

### Changed

- **`o` 键改为系统工具打开**：从 `open`（展开/打开）改为 `system_open`，目录→系统文件管理器、文件→默认程序（复用 `vv-utils.sys.open_default`）；展开/打开仍在 `<CR>`/`l`
- **移除 `<C-t>` open_tab**：新 tab 打开脱离 explorer 上下文、无人用
- **图标路由优化**：优先走 `vv-icons` 取状态图标，兼容全局 `MiniIcons`
- **键位**：`cd_to` 从 `<C-]>` 改为 `=`（与 `-` cd_up 对称）
- **过滤索引尊重 ignore 配置**：尊重 `show_ignored` 和 `filter.custom` glob
- **过滤失效**：切 hidden（`.`）/ gitignored（`I`）后过滤索引自动失效，下次 `/` 重建
- **粘贴后始终清空剪贴板**（之前 copy 模式可重复粘贴）

### Refactored

- filter 的 git 根探测改用 vv-utils.git.root（移除 shell 子进程调用）
- **actions.lua 拆为 actions/ 子模块**（826 行 → 5 文件），对外 API 不变
- **prompt.lua 浮窗选项改 `scope='local'`**：不再污染全局默认值
- git.lua / watch.lua 的手搓防抖统一复用 `vv-utils.timer.debounce`，detach 改用其 cancel 句柄释放 timer

### Fixed

- 粘贴：copy 模式也拦「粘到自身/自身子树」（原先只 cut 模式拦），避免触发 fs.copy 自包含递归
- 过滤框开着时从别处关掉树窗（state.win 置 nil）后，在框内按回车/Esc 不再崩（nvim_win_is_valid(nil)）
- 关树时 git 查询在后台跑，返回后不再往已销毁状态写残缺数据
- 反复按 `/` 过滤不再泄漏 uv timer
- 切根（`cd_to`/`cd_up`）后过滤即时重建索引，不再拼出旧 root 的无效路径（并修「构建中途切根永不重建」卡死）
- 经符号链接打开的文件：删除后 buffer 正确清理（不再像「同名文件被删」）、reveal 光标定位正确
- follow_file：折叠目录里的文件现在能正确展开定位（原先 `find_row` 的 ancestor 回溯把它误判为已可见，只移光标到折叠目录行而跳过展开）
- reveal/follow_file：定位「hidden + git tracked」目录下的文件（如 `.zsh/.../ff.sh`）时，首次打开光标不再卡在第一行——原因是 git `is_tracked` 异步未就绪时该子树被过滤、`find_row` 回退到 root 行；现用 `_pending_reveal` 等子树渲染出来后再归位
- `WinResized`/`WinClosed` autocmd 收进专用 augroup，不再随每次 open 累积
- reveal 祖先判断改前缀匹配，不再误把内嵌 root 路径的无关文件当后代
- `git`/`diagnostics` 传 `false`/`true` 不再崩（`setup` 做 table 归一化）
- `<C-n>`/`<C-p>` 导航不再光标乱跳（自动滚动只在过滤结果变化时触发）
- 删 buffer 后 explorer 不再撑满全屏（自动补建伴随窗口并恢复原宽度）
- reveal/open 时主窗口不再被切成预览
- `I` 模式不再漏搜个别 gitignored 文件（如 `.zsh/secret.zsh`）
- `I` 模式不再扫到 `~/Library/` 等系统目录（只递归含 `.git` 的嵌套 repo）
- 嵌套 git repo 不再无视父仓库 ignore 规则（改用 `git ls-files` 替代 fd）
- fuzzy 过滤无斜杠 query 只匹配文件名，去掉全路径打分噪音
- 编辑预览文件后自动提升为固定 buffer（出现在 bufferline）
- 兼容 Neovim 0.13 移除 `BufModifiedSet`（改用 `OptionSet modified`）
- 导航时已打开的 buffer 不再从 bufferline 消失
- 兼容 image.nvim：预览图片定向补发事件，切走后旧图片正确清除
- 兼容 render-markdown 等：filetype 检测移到设 buffer 之后
- perf：HOME-as-repo 下 git ignored 扫描从 13s+ 降到 ~20ms
- 树关窗隐藏期间不再因诊断变化做无谓的全量扫描（仅树窗口可见时才扫描，重开时补刷一次避免陈旧）

### Internal

- `Preview.clear_if_deleted` 封装预览 buffer 清理
- `clipboard_set` 提取公共 helper，消除 render/render_filter 重复构建
- `cleanup_deleted_bufs` 路径加尾斜杠防御


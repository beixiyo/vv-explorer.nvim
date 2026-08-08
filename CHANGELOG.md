# Changelog

## 0.3.3 - 2026-08-07

### Added

- **目录预览**：光标停在目录上时主窗显示目录属性
- **配置**：新增 `directory_preview`（`enabled` / `recursive` / `max_entries` / `budget_ms`），设 `false` 时光标停在目录上不改变主窗

### Fixed

- **回收站容量统计**：`scan_size` 曾调用 `du -sb`，而 BSD / macOS 的 `du` 不支持 `-b`，命令必然失败使容量恒为 0

## 0.3.2 - 2026-08-03

### Fixed

- **过滤索引生命周期**：`fd`、`git ls-files` 及动态发现的嵌套仓库扫描均绑定 filter request scope；关闭过滤、切换根目录或销毁面板会取消仍在运行的 producer
- **Git 状态刷新**：status、tracked、ignored 三路索引各自保留请求身份与 root 快照；防抖期间的 A→B→A 切根、重新 attach 或 detach 不会让旧结果覆盖当前状态
- **索引启动失败**：多 producer 管道构建失败时取消已经启动的进程

## 0.3.1 - 2026-07-30

### Changed

- **二进制预览**：复用 `vv-utils.fs` 按文件内容识别无扩展名二进制；`<CR>` / `l` / `<C-x>` / `<C-v>` 聚焦只读属性视图，`o` / `gx` 使用系统默认程序打开

## 0.3.0 - 2026-07-29

### Added

- **过滤路径补全**：filter prompt 通过 `vv-utils.completion` 暴露现有路径索引，供共享 `vv-utils.blink` source 在 fuzzy 与 glob 模式补全；沿用 hidden、gitignore

### Fixed

- **Glob 搜索简写**：glob 模式改用 `vv-utils.glob` 的共享编译结果，支持简写
- **补全排序**：Explorer matcher 结果标记为已过滤并携带稳定 rank，避免 Blink 对完整路径二次 fuzzy 后反转原顺序

## 0.2.3 - 2026-07-28

### Added

- **公开多选路径**：新增 `get_target_paths()`

## 0.2.2 - 2026-07-28

### Fixed

- **大小写重命名被误判为目标冲突**：在大小写不敏感文件系统上，`README.MD` → `README.md` 会因目标路径可解析而被拒绝。现由 `vv-utils.fs.rename` 仅在两侧确认是同一个文件对象时放行，仍拒绝覆盖真正存在的其他目标
- **操作数量通知显示 `item(s)`**：Trash、Delete、Copy 与 Dropped 通知现在按数量显示正确英文单复数，例如 `1 item` / `22 items`

## 0.2.1 - 2026-07-28

### Changed

- **恢复面板时可选是否聚焦**：`suspend({ focus = true })` 返回的恢复回调会在重新打开 explorer 后聚焦面板；默认保持当前窗口和 buffer，不打断原有编辑位置
- **统一项目注释为中文**：补齐核心模块、测试脚本与配置项注释，保留 API 名称、类型标记和协议术语

## 0.2.0 - 2026-07-26

### Added

- **面板状态跨会话恢复**：面板宽度和打开/关闭意图改由 `vv-utils.state` 持久化；新增 `persist_open`（默认开启）与可注入的 `state` 句柄。启动恢复不会抢走当前文件焦点，并会在树中定位当前文件
- **可恢复的临时挂起**：新增 `suspend()`，可临时隐藏 explorer 并返回一次性恢复函数，不把临时让位误记为用户主动关闭

### Changed

- **最低版本提升至 Neovim 0.11**：终端执行统一使用 `jobstart(..., { term = true })`，不再保留已弃用的 `termopen()` 兼容分支
- **按职责拆分核心模块**：配置、面板生命周期与键位从入口模块分离；文件操作拆为折叠链、剪贴板、拖放、变更与传输模块；过滤拆为索引与匹配器；回收站拆为存储与面板。原有公开入口继续由 facade 导出
- **收紧窗口生命周期**：`WinResized`、`WinClosed` 与 `VimLeavePre` 统一保存最终宽度、清理防抖任务并维持唯一 explorer 窗口；关闭伴随编辑窗时仍会保留可用的普通编辑窗口

## 0.1.1 - 2026-07-19

### Fixed

- **`]` / `[` 切根后 git 状态标记不刷新**：git 索引三条线（status / tracked / ignored）都以 `scope = true` 只扫当前 root 范围，而 `cd_to` / `cd_up` 换掉 `state.root` 后从不重跑索引，旧索引被直接复用。表现为 `[` 上翻后兄弟目录的改动全无色标（旧索引是更深层的子集），以及从 HOME-as-repo 进入嵌套独立仓库后仍沿用外层仓库的状态。现切根统一走 `after_root_change`，与 `refresh` 一样重跑三条线

### Added

- **切根时同步 cwd**：新增 `sync_cwd_on_cd`（`'tab'` | `'global'` | `false`，默认 `'tab'`）。`]` / `[` 切根时 `tcd` 到新根（tab-local，不污染其它 tab），telescope / grep / `:terminal` / 面板关着时的 vv-git 等一切读 `getcwd()` 的消费者随之跟随；设 `'global'` 用 `cd` 改全局，设 `false` 保持旧行为
- **广播 `User VVExplorerRootChanged`**：切根时发出 `data = { root }`，供持有自身根路径、够不着 `getcwd()` 的面板跟随（vv-git 已订阅，开着的面板即时切仓库、关着则记住作为下次打开的默认根）

## 0.1.0 - 2026-07-13

### Fixed

- **禁止鼠标多击 / 拖拽在文件树里选中 visual**：补全漏掉的 `<3-LeftMouse>`（三击选行）/ `<4-LeftMouse>`（四击选块）nop，并挂 `vv-utils.mouse.block_visual_drag` 兜底「从别窗点进树再拖 / 多击」的跨窗口路径（buffer-local Nop 拦不住）

### Changed

- **诊断行尾徽标改为 `vv-icons` 图标 + 数量**：文件树不再显示旧的 `E/W/I/H` 字母。诊断符号选择仍委托 `vv-utils.diagnostics`（最高 severity 决定图标与 `Diagnostic*` 颜色），vv-explorer 自己在行尾追加总数量，形如 `󰅙 3`，与 vv-bufferline 的 `icon + count` 展示保持一致
- **删除预览的反第三方 bufferline 防御 hack**：`preview_file` 在 `nvim_win_set_buf` 之后原有「同步 + `vim.schedule` 再强制 `buflisted = false`」两道还原，用于对抗早期 `akinsho/bufferline.nvim` 在 `BufWinEnter` 里把预览 buf 误升级为 listed。现配置已禁用 akinsho、改用自研 vv-bufferline（靠 window-local `is_preview` 标记决定归属，与 `buflisted` 无关），该防御已无对象，删除。保留 set_buf 之前的一次初始 `buflisted = false`（让预览不进 `:ls`、且满足旧预览可删条件）。已在完整真实配置下实测：移除后预览 buf 仍 unlisted、不进 `:ls`、不进分组、正常显示。配套：vv-bufferline 新增 `should_show`，预览期间窗口已有固定分组时**保留**标签栏可见（修掉「树里 j/k 预览新文件时右侧 bufferline 整条消失」）
- **过滤输入框骨架下沉 `vv-utils.prompt`**：底部双行浮动 filter 框（曾与 vv-flow `filter.lua` ~90% 逐字同构）抽离为共享模块，本仓 `prompt.lua` 瘦成薄封装。spinner 从「反向读 `state.filter.searching`」改为 push 模型（`handle.set_busy(true,'…')`），消除 `state.filter.on_redraw` 反向钩子；自适应防抖、`<C-n>`/`<C-p>` 导航、`<C-x>`/`<C-v>` 分屏、mode badge 均经 opts 注入。纯内部重构，交互/外观不变

### Fixed

- **打开文件会复原已从分屏分组删除的 buffer**：`open_file` 原先在 `:edit` 之前无条件 `Preview.promote(state)`，把「上一个悬停预览」顺手升级为固定标签——当你只是悬停过 B、随后打开 C 时，B 会被复活，即便它已被 `<leader>bd` 从该分屏分组删除。改为「先 `:edit` 切到目标、再 `Preview.commit(state, main)`」：commit 只升级**真正打开的** buffer，对指向其他文件的陈旧预览只丢弃不升级（`open_in`/分屏走 `Preview.discard`）。配合 vv-bufferline 的 window-local `removed` 标记（`track_current` 与 render 均尊重），被删除的分组 buffer 只有显式重开（点 tab / 经树打开）才回来。删除无调用方的 `Preview.promote`
- **回收站孤儿条目 crash**：trash 目录里若存在「数据文件在、配套 `.meta.json` 丢失」的孤儿条目（早先 `trash()` 中 rename 成功但 meta 写入失败被 pcall 吞、或 meta 被外部清理所致），`Trash.list()` 直接 `Fs.read_all` 该 meta → ENOENT error，连带 `enforce_max_items` 在每次删除后崩（`vim.schedule callback` 报错）。现把 meta 读取包 `pcall`，缺 meta 时按 `original_path='(unknown)'` 兜底列出，单个孤儿不再打挂整个 list/删除流程
- **树窗按 `gf` 报 E1513**：树 buffer `winfixbuf=true`，原生 `gf` 试图在锁定窗口切 buffer → `E1513: Cannot switch buffer`。现默认把 `gf` 映射为 `open`，与 `<CR>`/`l` 一致（打开节点 / 展开目录），走已处理 winfixbuf 的 `open_file` 路径

- **reveal 把光标跳到别处**：在被隐藏/过滤的文件（未跟踪 dotfile、gitignored、`.git/` 内文件）上按 `<leader>e` 时光标被带到别的文件。两处根因：① `find_row` 沿祖先回溯到最近可见目录行并强制定位 → 改 reveal/follow 用 strict 定位，只在目标文件**自身**那一行已渲染时归位（仍兼容 symlink 解析与 group_empty_dirs 合并目录），「hidden + git tracked」待 git 异步就绪后照常归位；② explorer buffer 跨 open/close 复用，定位失败时光标停在上一次的残留位置（如之前 follow 跟到的文件）→ 现 reveal 定位不到目标时把光标拉回根行

- **git 状态不刷新（外部变更）**：commit/push 等只动 `.git/`（index/HEAD）的操作不会在工作树目录上产生 fs_event，导致 watch.lua 监听不到、git 状态标记滞留。现订阅 vv-git 的 `User VVGitStatusChanged` 即时刷新，并叠加 `FocusGained`/`TermClose`/`TermLeave` 兜底外部工具（ClaudeCode/Codex 等直接跑 git）的场景；detach 时清理对应 augroup

- **filter 索引被陈旧异步构建污染**：大仓 `ensure_filter_index` 异步 `build_index`（git ls-files）的回调无 root/generation 校验，慢构建在切根（cd_to/cd_up）后才返回时会把旧 root 绝对路径写进新 root 的 `f.index` 并触发错误 refilter（匹配重建成新 root 下不存在的路径）。现为每次构建打 generation token，`invalidate_filter_index` 一并 bump，回调命中 stale 检查（gen 或 index_root 不符）即丢弃结果，并重置 `index_rels` 强制按当前 root 重建

- **粘贴全失败仍清空剪贴板**：`paste` 在全部条目被自包含跳过（把目录粘进自身/子目录）或全部出错时仍无条件清 `state.clipboard`，导致没粘成功却丢了 cut/copy 选区（cut 的源无法从 explorer 恢复）。现仅在确有条目落盘成功（`last_dst` 非 nil）时才清剪贴板，与 `drop_into` 的非破坏性行为一致

- **root 为 `/` 时无法展开/定位**：`Tree.expand_to`/`Tree.find` 及 `to_tree_path` 的前缀判断用 `root.path .. '/'`，当 root 是文件系统根 `/` 时前缀退化成 `//`，任何真实后代都被误判不在 root 下 → reveal/follow_file/拖拽落目录/filter open-in-tree 全部静默失效、光标退回根行。现 base 为 `/` 时折叠尾斜杠（前缀取 `/`），后代正常解析且兄弟拒绝（`/home/dev` vs `/home/devil`）仍成立

- **恢复孤儿回收站条目移到 `(unknown)` 垃圾路径**：缺 meta 的孤儿条目 `original_path` 为 `(unknown)` 哨兵，`Trash.restore` 无校验直接 rename，把文件挪到 cwd 下名为 `(unknown)` 的文件、数据静默丢失。现 `restore` 在动磁盘前拦截哨兵/非绝对路径并 `error`，面板 `r`/`<CR>` 用 `pcall` 包裹并以 WARN 通知失败原因而非搬运文件

- **经符号链接打开的文件重复 :edit 报 E37**：`open_file` 用 `fnamemodify(':p')`（不解析 symlink）与 buffer 名（realpath 解析形）比对，符号链接目录下的文件被误判「未打开」而重跑无 `!` 的 `:edit`，脏 buffer 时抛 `E37: No write since last change`。现两侧统一到 `Fs.realpath` 空间比对，与本仓库其余 symlink 等价判断一致，已打开文件成为真正的 no-op

- **外部删除焦点文件后光标停在无关行**：`render_stable` 在 `prev_path` 重渲后不在 `path_to_row` 时（外部 rm 焦点文件）不移动光标，nvim 自动 clamp 使其落在变成别的文件的同一行号上，后续 `<CR>`/`d`/`Y` 误操作邻近节点。现复用 `find_row` 的祖先回溯惯用法，回溯到最近存在祖先（被删文件的父目录）落点

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

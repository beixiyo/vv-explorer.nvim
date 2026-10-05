# Changelog

## 0.5.0 - 2026-10-04

### Added

- 本实例 `x` → `p` 批量剪切以整批一次请求同步 LSP，并在改写文件后通知
- 目录与子项同批 cut 时只移动目录，成功后同步清除子项剪切标记
- `Transfer.execute_async` 新增整批移动前后的 `before_moves` / `after_moves` 钩子
- 新增折叠链选层高亮 `VVExplorerChainSelected`，默认链接 `CurSearch`，不再与过滤匹配共用高亮

### Changed

- `persist_open` 默认改为 `false`
- `Y` / 右键复制路径成功后不再提示，新增 `yank_notify`（默认 `false`）
- 重命名与 cut 的 LSP 编辑仅在移动成功后保存，失败仅回滚 buffer、不写盘
- `d` 移入回收站后异步统计目录大小
- `D` 永久删除改为分片异步
- 重命名 / cut 的 LSP loading 改到图标槽，长文件名也可见
- `VVExplorerMatch` / `VVExplorerDropTarget` 默认链接 `Search` / `PmenuSel`，跟随主题

### Fixed

- 重命名 / cut 清理目标路径上未修改且文件已不存在的过期 buffer
- 焦点在面板时，右键点击其他窗口不再误复制树内路径

## 0.4.1 - 2026-09-26

### Changed

- 合并 Git 索引结果重画，减少打开面板时的刷新次数
- explorer 隐藏期间不响应 Git 变化，重新显示时补刷

## 0.4.0 - 2026-09-07

### Added

- `y` / `x` 文件剪贴板跨 Neovim 实例共享，已打开面板实时同步标记
- 粘贴同名目标默认弹窗选择完整覆盖或递增命名保留两份，也可用 `clipboard.conflict` 指定策略
- 新增 `D`，确认后绕过回收站永久删除所选项目

### Changed

- 复制记录在首次成功粘贴或所属 Neovim 退出后清除；剪切仅移除移动成功项，保留失败项
- 文件传输加强覆盖、递增命名与跨设备剪切的原子性，失败时提供可见 recovery 路径

### Fixed

- 防止并发创建、目录变化、符号链接重定向与临时路径冲突造成覆盖、误删或隐藏恢复内容
- 修复根路径规范化、目标父目录符号链接与 symlink source 复制语义

## 0.3.5 - 2026-09-01

### Added

- 新增 `restore_main_win(win)`：属性页关闭且原 buffer 失效时可接管主窗，否则回退到 vv-dashboard 或空白 buffer

### Fixed

- 关闭 explorer 时撤下目录 / 二进制属性页、恢复原 buffer 并取消统计；属性页被外部回收后也不再遗留后台任务

## 0.3.4 - 2026-08-10

### Changed

- 删除、永久删除、清空回收站与 `X` 执行文件改用分层确认浮窗，展示目标、工作目录与命令

### Fixed

- 切根、关闭面板、发起新操作或目标变化时取消旧确认，避免误删或误执行
- 执行前校验路径、工作目录与命令，运行器或终端启动失败时通知而非抛错
- 回收站永久删除 / 清空前复核条目，外部修改或新增后取消操作

## 0.3.3 - 2026-08-07

### Added

- 新增目录属性预览与 `directory_preview` 配置，设为 `false` 时目录行不改变主窗

### Fixed

- 修复 BSD / macOS 上回收站容量恒为 0 的问题

## 0.3.2 - 2026-08-03

### Fixed

- 关闭过滤、切根或销毁面板时取消在途索引进程；索引启动失败时清理已启动进程
- 切根、重新 attach 或 detach 后丢弃旧 Git 索引结果，避免覆盖当前状态

## 0.3.1 - 2026-07-30

### Changed

- 二进制预览支持无扩展名文件；`<CR>` / `l` / `<C-x>` / `<C-v>` 聚焦只读属性视图，`o` / `gx` 用系统程序打开

## 0.3.0 - 2026-07-29

### Added

- 过滤输入通过 `vv-utils.completion` / `vv-utils.blink` 补全 fuzzy 与 glob 路径，沿用 hidden、gitignore 设置

### Fixed

- Glob 搜索支持共享简写语法，路径补全在 Blink 中保持原匹配顺序

## 0.2.3 - 2026-07-28

### Added

- 新增多选路径查询 `get_target_paths()`

## 0.2.2 - 2026-07-28

### Fixed

- 大小写不敏感文件系统允许同一文件仅改大小写，仍拒绝覆盖其他目标
- 操作数量通知使用正确英文单复数

## 0.2.1 - 2026-07-28

### Changed

- `suspend({ focus = true })` 恢复时可聚焦面板，默认保留当前编辑位置
- 统一项目注释为中文，保留 API 名称与协议术语

## 0.2.0 - 2026-07-26

### Added

- 面板宽度与开关意图跨会话持久化，新增 `persist_open`（默认开启）与可注入的 `state`；恢复时定位当前文件但不抢焦点
- 新增 `suspend()`，临时隐藏面板并返回一次性恢复函数，不改变用户开关意图

### Changed

- 最低版本提升至 Neovim 0.11，不再兼容 `termopen()`
- 关闭 / 调整窗口时保存最终宽度并清理任务，维持唯一 explorer 与可用的普通编辑窗

## 0.1.1 - 2026-07-19

### Added

- 新增 `sync_cwd_on_cd`，`]` / `[` 切根默认同步 tab-local cwd；设 `'global'` 同步全局，设 `false` 保持旧行为
- 切根广播 `User VVExplorerRootChanged`（`data = { root }`），供 vv-git 等面板跟随

### Fixed

- `]` / `[` 切根后重新刷新 Git 状态，正确显示兄弟目录与嵌套仓库改动

## 0.1.0 - 2026-07-13

### Added

- 新增方向键导航，行为与 `j/k/h/l` 一致，支持首尾绕回
- 折叠空目录链支持 `<C-l>` / `<C-h>` 选层并高亮，单目标操作作用于所选层级
- `r` 重命名同步 LSP 文件操作与返回编辑，等待时显示 loading；`lsp_rename_timeout_ms` 默认 5000ms，超时提示后继续重命名
- 新增 `X` 按文件类型在终端执行，默认确认命令，支持 `execute.confirm` / `execute.run` 自定义
- 拖放支持多文件与鼠标落点高亮（kitty ≥ 0.47、无 tmux）；其他环境回退到光标目录 / 打开文件，同名自动递增且不覆盖已有内容
- `<Esc>` 依次清过滤、选区与剪贴板标记、关闭树；屏蔽树内 Visual 与鼠标拖选，保留 `<C-v>` 分屏
- 二进制文件默认拦截并用系统程序打开、跳过预览，可通过 `binary.intercept` / `binary.extensions` 调整
- 文件夹图标随关闭、展开、空目录状态变化，支持特定目录展开图标与大小写不敏感匹配
- 鼠标单击切换目录展开，右键复制绝对路径；`Y` 支持复制全部选中路径
- `d` 默认移入 `~/.local/share/vv-explorer/trash/`；`T` / `:VVExplorerTrash` 可恢复、永久删除或清空，`trash = false` 回退真删
- `x` / `y` 支持累加切换剪贴板标记并显示图标，Tab 多选仍批量替换；`<Tab>` 选中后自动下移
- 删除预览文件后自动清理 buffer，面板宽度跨会话记忆
- 新增 `preview_debounce_ms` 与 `follow_file_debounce_ms`（默认 0），减少快速导航与切 buffer 时的重复预览

### Changed

- 诊断徽标改为 `vv-icons` 图标与数量，按最高严重程度着色
- 预览不再强制对抗第三方 bufferline 的自动列出行为；配合 vv-bufferline 保留固定标签栏，其他 bufferline 需尊重 unlisted
- `o` 改为系统程序打开，树内打开 / 展开仍用 `<CR>` / `l`；移除 `<C-t>` 新 tab 打开
- 图标优先使用 `vv-icons`，兼容全局 `MiniIcons`
- `cd_to` 键位从 `<C-]>` 改为 `=`，与 `-` 上级目录对称
- 过滤遵守 `show_ignored` 与 `filter.custom`，切换 hidden / gitignored 后重建索引
- 成功粘贴后清空剪贴板，copy 模式不再重复粘贴

### Fixed

- 文件树禁止鼠标多击与跨窗口拖拽进入 Visual
- 打开文件只固定实际目标，不再复原已从分屏分组删除的悬停预览；移除 `Preview.promote`，同窗打开改用 `Preview.commit`，分屏改用 `Preview.discard`
- 缺元数据的回收站条目可列出且不打断删除流程，恢复时拒绝未知或非绝对原路径并提示
- 树窗 `gf` 改为打开节点 / 展开目录，不再报 E1513
- reveal / follow 不再误定位隐藏或过滤目标，reveal 找不到目标时回根行；折叠目录正确展开，隐藏但已跟踪文件待 Git 就绪后定位
- 外部删除焦点文件后光标回到最近存在祖先，不再落到无关文件
- 外部 Git 操作后刷新状态，隐藏期间暂停诊断扫描并在重开后补刷
- 切根后重建过滤索引并丢弃陈旧结果，不再产生无效路径或卡住构建
- 粘贴全部失败时保留剪贴板，copy 与 cut 均拒绝粘入自身或子树
- 根目录为 `/` 时正常展开与定位，路径边界判断不再误认无关后代
- 符号链接文件正确定位与删除后清理，重复打开已修改文件不再报 E37
- 关闭树后过滤确认 / 退出不再崩溃，后台 Git 查询不再写回已销毁状态
- 修复反复过滤、打开面板造成的 timer 与窗口事件累积，过滤浮窗选项不再污染全局
- `git` / `diagnostics` 接受布尔配置不再崩溃，`<C-n>` / `<C-p>` 导航不再乱跳
- 删除 buffer 后保留编辑窗与树宽，reveal / open 不再将主窗误切为预览
- `I` 模式不再漏搜忽略文件或扫描无关系统目录，嵌套仓库遵守父仓库 ignore 规则
- fuzzy 无斜杠查询只匹配文件名，避免全路径干扰排序
- 编辑预览文件后自动固定，导航到已打开 buffer 时不再从 bufferline 消失
- 兼容 Neovim 0.13 移除 `BufModifiedSet`、image.nvim 图片清理与 render-markdown 等 filetype 检测
- HOME-as-repo 的 Git ignored 扫描从 13s+ 降至约 20ms

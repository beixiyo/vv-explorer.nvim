# Changelog

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本遵循 [SemVer](https://semver.org/lang/zh-CN/)

## [Unreleased]

### Added

- **回收站**：`d` 删除改为移入 `~/.local/share/vv-explorer/trash/`，不再真删
  - `T` 键 / `:VVExplorerTrash` 打开彩色回收站面板，支持恢复（`r`）、永久删除（`d`）、清空（`D`）
  - 每个条目附带 `.meta.json` 元数据（原始路径、时间戳、大小），用于恢复
  - 可配置：`trash.max_items`（超出自动清理最旧，默认 5000）、`trash.warn_size_mb`（打开时异步警告，默认 500）、`trash.scan_on_open`
  - `trash = false` 完全禁用（回退到真删）
- **剪贴板图标**：`x` 剪切和 `y` 复制后，被标记的文件行尾显示对应图标（来自 `vv-icons`）
  - 粘贴（`p`）后或剪贴板被替换时自动清除
- **多选复制路径**：`Y` 在有选区时复制所有选中路径（换行分隔）到系统剪贴板
- **Tab 自动下移**：`<Tab>`（toggle_select）切换选中后自动移到下一行
- **删除后清理预览 buffer**：删除正在预览的文件时，自动关闭主窗口中对应的 buffer

### Changed

- **键位**：`cd_to` 从 `<C-]>` 改为 `=`（与 `-`（cd_up）对称配对）
- **过滤索引**：尊重 `show_ignored`（传 `--no-ignore` 给 fd）和 `filter.custom` glob（传 `--exclude`）
- **过滤失效**：切换 hidden（`.`）或 gitignored（`I`）后自动失效过滤索引，下次 `/` 用新配置重建
- **粘贴**：粘贴后始终清空剪贴板（之前仅 cut 模式清空，copy 模式可重复粘贴）

### Fixed

- **preview**：filetype 检测移到 `nvim_win_set_buf` 之后，修复 render-markdown 等插件在预览窗口不渲染的问题（根因：`FileType` 触发时 buffer 尚无归属窗口，插件 `buf.win(buf)` 返回 -1 导致初始渲染被跳过）
- **perf**：HOME-as-repo 场景下 `git status --ignored` 递归扫全盘导致文件树卡 13s+，改用 `git ls-files --others --ignored --directory`（`--directory` 不递归进 ignored 目录，~20ms）

### Internal

- `Preview.clear_if_deleted(state, path_set)` — 封装预览 buffer 清理（原先直接访问 `_preview` 内部表）
- `clipboard_set(state)` — render.lua 提取公共 helper，消除 `M.render` 和 `M.render_filter` 的重复构建逻辑
- `cleanup_deleted_bufs` 路径规范化加尾斜杠防御

## [0.1.0]

### Added

- 初始公开版本：单 source 文件树、VSCode 风单击预览、空目录折叠、libuv fs_event 自动刷新、`/` 全树模糊过滤、git 状态 + ignored 暗色、LSP 诊断、CRUD、剪贴板（yank / cut / paste）、批量选择、help 浮窗、自定义 icon 规则
- filter prompt 三种搜索模式（fuzzy / glob / regex），`<S-Tab>` 循环切换
- filter prompt 内 `<C-n>` / `<C-p>` 在 tree 窗口里跳到下/上一个 match（焦点不离 prompt，自动驱动预览）
- filter prompt 内 `<C-x>` / `<C-v>` 直接以 split / vsplit 打开当前 match
- filter prompt 双行布局：line 0 = mode badge + 状态，line 1 = 干净输入区
- 新建文件后自动在主窗口打开并聚焦（目录保持树内定位）

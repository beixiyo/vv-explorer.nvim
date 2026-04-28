# Changelog

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本遵循 [SemVer](https://semver.org/lang/zh-CN/)

## [Unreleased]

### Fixed

- **perf**: HOME-as-repo 场景下 `git status --ignored` 递归扫全盘导致文件树卡 13s+，改用 `git ls-files --others --ignored --directory`（`--directory` 不递归进 ignored 目录，~20ms）

### Added

- filter prompt 三种搜索模式（fuzzy / glob / regex），`<S-Tab>` 循环切换
- filter prompt 内 `<C-n>` / `<C-p>` 在 tree 窗口里跳到下/上一个 match（焦点不离 prompt，自动驱动预览）
- filter prompt 内 `<C-x>` / `<C-v>` 直接以 split / vsplit 打开当前 match（清 filter + expand_to + 复用 open_split/vsplit）
- filter prompt 双行布局：line 0 = mode badge + `<S-Tab> switch` 提示 + `N matches` / `indexing…` 状态，line 1 = 干净输入区（无 inline 前缀，输入再长不会被装饰挤掉）
- filter prompt 空输入时 overlay 显示 `type to filter…` placeholder，第一字符即覆盖
- mode badge 高亮组：`VVExplorerFilterModeFuzzy`（青蓝）/ `Glob`（橙）/ `Regex`（粉），与 vv-replace 同色系
- `Filter.display(mode)` / `Filter.next_mode(mode)` API：mode 元数据集中维护

### Changed

- Update `<Esc>` (escape action): Close the explorer if no active filter or selection.
- 空 query 时不进过滤渲染，保持普通树视图（"打开 / 不立刻筛掉一切"）
- tree 内 `q` 在 filter 视图下清 filter，否则关树（之前总是关树）
- `glob` 模式 query 不含 `/` 时自动跨段：`*.lua` ≡ `**/*.lua`，纯文本 `foo` ≡ `**/*foo*`（VSCode 风）
- 内部重构（无外部 API 变化）：
  - `actions.M.open` 拆为 `open_dir_from_filter_view` / `toggle_dir` / `open_file`
  - `actions.M.start_filter` 抽 `make_prompt_callbacks` / `ensure_filter_index`
  - `prompt.M.open` 拆 `setup_floating_window` / `setup_decorations` / `setup_keymaps`
  - `git.attach` 抽 `run_status` / `run_tracked`，首次调用与 debounced refresh 共享
  - `actions` 抽 `open_in_explorer_split`，`M.open` 文件分支与 `open_in` fallback 复用
  - `state.filter.matched` 全程统一空表常量，删除散落的 nil 守卫
  - `state.filter.on_match_count_update` 重命名为 `on_redraw`（实际职责扩到了整个 label 重画）
  - `MODE_DISPLAY` 从 prompt.lua 移入 filter.lua，避免与 `MODES` 双源不同步
  - `SCROLL_LINES = 5` 提为常量
  - 4 处手写 path_to_row 查询 + set_cursor 统一用 `focus_path` helper

### Removed

- filter prompt 内的 `<C-t>`（tree 内 `<C-t>` 仍保留作为新 tab 打开）

## [0.1.0]

### Added

- 初始公开版本：单 source 文件树、VSCode 风单击预览、空目录折叠、libuv fs_event 自动刷新、`/` 全树模糊过滤、git 状态 + ignored 暗色、LSP 诊断、CRUD、剪贴板（yank / cut / paste）、批量选择、help 浮窗、自定义 icon 规则

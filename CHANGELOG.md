# Changelog

## [Unreleased]

### Added

- **拖拽粘贴**：从文件管理器拖文件到 explorer，复制到光标所在目录（多文件、同名自动重命名）
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

### Changed

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

- 过滤框开着时从别处关掉树窗（state.win 置 nil）后，在框内按回车/Esc 不再崩（nvim_win_is_valid(nil)）
- 关树时 git 查询在后台跑，返回后不再往已销毁状态写残缺数据
- 反复按 `/` 过滤不再泄漏 uv timer
- 切根（`cd_to`/`cd_up`）后过滤即时重建索引，不再拼出旧 root 的无效路径（并修「构建中途切根永不重建」卡死）
- 经符号链接打开的文件：删除后 buffer 正确清理（不再像「同名文件被删」）、reveal 光标定位正确
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


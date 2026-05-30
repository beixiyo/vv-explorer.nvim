# Changelog

## [Unreleased]

### Added

- **拖拽粘贴**：从文件管理器拖拽文件到 explorer 窗口，自动复制到光标所在目录。基于 `vv-utils.drop` 的 handler 机制，explorer 打开时自动注册；支持多文件拖拽、同名自动重命名（`Fs.unique_dest`）。已验证：Kitty (Linux/macOS)、Ghostty (Linux/GTK4)
- **`<Esc>` 清除剪贴板标记**：`<Esc>` 优先级调整为 `filter > 选区 + 剪贴板（一起清）> 关树`；`x`/`c` 标记的 cut/copy 状态现在可通过 `<Esc>` 一键取消，多选和剪贴板标记同时存在时也一并清除
- **V 模式屏蔽**：`v`/`V` 在树 buffer 中映射为 `<Nop>`（nofile buffer 里 visual 无意义）；`<C-v>` 已映射为 `open_vsplit` 不受影响
- **鼠标 visual 屏蔽**：屏蔽 `<LeftDrag>`（左键拖拽）和 `<2-LeftMouse>`（双击左键），防止鼠标操作触发 visual 选区

- **二进制文件拦截**：`binary.intercept = true`（默认开启），`<CR>`/`l`/`o`/`<C-x>`/`<C-v>`/`<C-t>` 遇到二进制文件时不在 nvim 内 `:edit`，改用系统默认程序打开；预览也会跳过二进制文件。内置 30+ 常见扩展名（图片/视频/音频/压缩包/编译产物/字体/二进制文档/数据库），支持 `binary.extensions` 逐 key 增减覆盖
- **状态感应图标**：文件夹现在支持三种状态切换：关闭 (󰉋)、展开 (󰝰)、空目录 (󰉖)，视觉风格对齐 `snacks.nvim`
- **特定目录展开态**：如 `src` 目录在展开时会从普通文件夹图标变为展开状态图标 (`󰝰`)
- **鼠标操作**：单击（`<LeftRelease>`）展开/收起目录（文件不动，走预览）；右键（`<RightMouse>` + `getmousepos()`）复制绝对路径，屏蔽右键 visual 选区
- **大小写不敏感图标**：MiniIcons 精确匹配失败时自动尝试小写（如 `Components` → `components`）
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

- **宽度持久化**：调整文件树宽度后跨 session 记住，通过 `WinResized` 实时跟踪 + `VimLeavePre` 写入 `stdpath('data')/vv-explorer.json`

- **剪贴板 toggle 累加**：`x`/`y` 不再替换剪贴板，而是 toggle 当前文件进/出剪贴板——连按多个文件的 `x` 即可批量标记剪切，再按一次取消。Tab 多选后按 `x`/`y` 仍为批量替换

### Changed

- **移除 `<C-t>` open_tab**：新 tab 打开文件脱离 explorer 上下文，实际无人使用。action 函数一并移除

- **图标路由优化**：重构 `icons.lua`，优先通过 `vv-icons` 获取增强的状态图标，并保持对全局 `_G.MiniIcons` 的标准兼容
- **键位**：`cd_to` 从 `<C-]>` 改为 `=`（与 `-`（cd_up）对称配对）
- **过滤索引**：尊重 `show_ignored`（传 `--no-ignore` 给 fd）和 `filter.custom` glob（传 `--exclude`）
- **过滤失效**：切换 hidden（`.`）或 gitignored（`I`）后自动失效过滤索引，下次 `/` 用新配置重建
- **粘贴**：粘贴后始终清空剪贴板（之前仅 cut 模式清空，copy 模式可重复粘贴）

### Refactored

- **actions.lua 拆分为 actions/ 子模块**（826 → 5 文件，最大 264 行）：`helpers.lua`（共享辅助）、`navigation.lua`（导航/选区/滚动）、`crud.lua`（CRUD + 剪贴板）、`filter.lua`（过滤操作）、`init.lua`（facade）。对外 API 不变

- **prompt.lua `vim.wo` → `scope='local'`**：浮窗选项设置不再污染全局默认值（与 vv-utils.ui_window 同步修复）

### Fixed

- **符号链接路径归一化：删除后 buffer 清理 + reveal 定位**：`nvim_buf_get_name` 对经符号链接打开的文件返回「已解析真实路径」，而 `node.path` / `fnamemodify(':p')` / `vim.fs.normalize` 保留 symlink 形，两套口径在有 symlink 时对不上，引发两类问题：① 删 `link/foo` 后其 buffer（解析形 `real/foo`）漏清，残留指向已删文件、`:w` 会把已删文件重建（表现像「同名文件被删」，实为漏清、**非真删磁盘**）；② reveal / follow_file 查 `path_to_row` 失败 → 光标爬到错误祖先行。修复：新增共享 `vv-utils.fs.realpath`，`cleanup_deleted_bufs` / `M.delete`（删除前先解析，因删后 symlink 已不在）/ `preview.clear_if_deleted` 改在真实路径空间比对；reveal 经新增 `helpers.find_row` / `to_tree_path` / `expand_to_file` 统一口径。无 symlink 场景走快路径零额外开销；磁盘删除仍只作用于精确 `node.path`，不误删、不连带删同名文件

- **explorer：`WinResized` / 全局 `WinClosed` autocmd 随每次 open 累积泄漏**：「完整打开」分支每次都裸注册（无 augroup、非 once）这两个 win 相关 autocmd，靠回调 `return not state` 自删；但 `open → :bwipe → 再 open` 后 `state` 重新非 nil，旧回调永远删不掉，多次循环叠加 N 个回调对同一 state 重复执行宽度写入 / 补窗逻辑。修复：收进专用 augroup `vv-explorer.win`（每次 `open` 用 `clear = true` 复用，先清旧再注册），计数恒定不叠加；业务逻辑（`_tracked_width` 宽度跟踪 + sole-window `vnew` 补窗）零改动。另两处 `WinClosed`（场景 A 复用窗 / 手动关窗 `close_window_only`）本就是 `pattern + once`，自清不泄漏，未动

- **reveal：`Tree.expand_to` / `Tree.find` 误把内嵌 root 路径的无关文件当后代**：祖先判断用 `target_path:find(root.path .. '/', 1, true)`，`plain=true` 只关魔法字符、仍是「任意位置子串匹配」而非前缀判断。打开一个绝对路径里碰巧内嵌了 explorer 根路径的无关文件（如 `/tmp<root>/x`）时，guard 误判为后代，`sub(#root+2)` 切出错位相对路径；多数情况下静默失败看不出，但 root 内恰好存在同名链时会把光标/展开定位到错误节点。修复：`tree.lua` 两处改为真正的前缀判断 `target_path:sub(1, #root.path + 1) == root.path .. '/'`

- **config：`git` / `diagnostics` 传 `false`（或 `true`）时打开崩溃**：`setup` 用 `vim.tbl_deep_extend('force', defaults, opts)` 合并，当 `git = false`（非 table）时整个 `git` 字段被替换成布尔，`M.open` 里 `if config.git.enabled` 对布尔取下标抛 `attempt to index a boolean value`，文件树打不开；`git = true` 简写同样被替换成布尔而崩。原本只给 `trash` 做了归一化，漏了 `git`/`diagnostics`。修复：在 `setup` 里对二者做同款归一化（`false → { enabled = false }`、`true → 合并默认表`），保证 `config.git`/`config.diagnostics` 恒为 table

- **filter：`<C-n>` / `<C-p>` 导航时光标乱跳**：`render_filter` 末尾无条件将光标拉回首个 match（`matched_abs[1]`）。glob/fuzzy 过滤出多个结果后，按 `<C-n>`/`<C-p>` 在 match 间切换时，`filter_navigate` 移动光标后调 `Preview.preview_file`，预览打开文件触发诊断 / fs 等增量重渲 → `render_filter` 又把光标抢回首个 match，导致永远停不到目标行（同根因下，过滤期间任意 LSP 诊断刷新也会抢走浏览光标）。修复：自动滚动改为一次性开关 `state.filter._want_scroll`，仅 `refilter`（query / 模式变化）置位、`render_filter` 渲染后立即消费；导航与增量重渲不再移动光标

- **宽度撑满：删除 buffer 后 explorer 宽度撑满整个屏幕**：内容窗口被关闭（`:bd` / `:bwipe` / `bufdel.smart` 等）后 explorer 成为 tabpage 唯一窗口，Neovim 忽略 `winfixwidth` 将其拉满，`WinResized` 还把错误宽度写入 `_tracked_width` 污染持久化。修复三处：① `is_sole_window()` 检测 explorer 是否为唯一非浮动窗口；② `WinResized` 回调跳过 sole-window 场景不更新 `_tracked_width`；③ 全局 `WinClosed` autocmd 在 explorer 成为唯一窗口时自动 `vnew` 补建 unlisted 伴随窗口并恢复原宽度

- **preview：reveal / open 时主窗口被意外切换为预览**：复用旧 buffer（场景 A）时，`Render.render` → `nvim_buf_set_lines` 替换全部行可能 clamp cursor 到已变更的行号，触发 `CursorMoved` → `preview_file` 将主窗口切到非目标文件。修复：`M.open()` / `M.reveal()` 期间设 `state._skip_preview` 标志阻止 preview 回调；`preview_file` 路径比对加 `vim.fs.normalize` 归一化防止符号链接等微妙路径差异

- **filter：`I`（show_ignored=true）仍搜不到个别 gitignored 文件**：两阶段策略的阶段二只处理以 `/` 结尾的目录行（嵌套 git repo 检测），非 `/` 结尾的个别 gitignored 文件（如 `.zsh/secret.zsh`）被直接丢弃。现在将这类行收集为 individually-ignored 文件直接加入结果，无需嵌套 repo 即可在 `/` filter 中搜到

- **filter：`I`（show_ignored=true）扫到 `~/Library/` 等系统目录**：原实现对 git repo 也走 `fd --no-ignore`，`~/.gitignore` 存在 `*` catch-all 规则时整个家目录都被扫入。改为两阶段策略：阶段一 `git ls-files` 取正常文件，阶段二 `git ls-files --ignored --directory` 列出 gitignored 目录后只递归含 `.git` 的嵌套 repo（如 `vendors/vv-*.nvim`），跳过无 `.git` 的系统目录

- **filter：`show_ignored=false` 时 `vendors/vv-*.nvim` 等嵌套 git repo 仍出现在结果中**：`fd` 遇到含独立 `.git` 的子目录时会切换到该 repo 的 gitignore 上下文，导致父仓库的 ignore 规则失效。改用 `git ls-files --cached --others --exclude-standard` 替代 fd，git 原生正确处理嵌套 repo

- **filter fuzzy：无斜杠 query 匹配全路径导致大量噪音**：搜索 `.gitignore`、`App.tsx` 等纯文件名时，`matchfuzzypos` 对完整相对路径打分，路径中散落的同字母字符得分异常高。改为：query 不含 `/` 时只对 basename 做 fuzzy（`match_fuzzy_basename`），命中后将 position 偏移回完整 rel 路径坐标保持高亮正确；query 含 `/` 时仍走全路径 fuzzy 并以 basename 命中优先排序

- **preview：编辑预览文件后未自动提升为固定 buffer**：`BufModifiedSet`/`OptionSet modified` 回调只做了取消追踪（`M._preview[state] = nil`），漏掉了 `buflisted = true`，导致编辑后 buffer 不出现在 bufferline 里。修复：两个分支均补上 `buflisted = true`，与 `promote()` 行为对齐。此 bug 在 0.12 就存在，只是此次升级 nightly 时才被发现
- **compat：Neovim 0.13 移除 `BufModifiedSet`**：0.13 nightly（[#35610](https://github.com/neovim/neovim/pull/35610)，2026-04-27）将 `BufModifiedSet` 替换为 `OptionSet modified`（原事件只在 redraw 时对当前 buffer 触发，`:wa` 写非当前 buffer 时延迟/丢失）。现用 `exists('##BufModifiedSet')` 运行时检测，0.12 走旧事件，0.13+ 走 `OptionSet`；`OptionSet` 回调改用 `args.buf`（对应 Vimscript `expand('<abuf>')`），比 `nvim_get_current_buf()` 更准确

- **preview：导航时已打开的 buffer 从 bufferline 消失**：`nvim_win_set_buf` 触发 `BufWinEnter` autocmd，部分 bufferline 插件在其中将预览 buffer 强制设为 `buflisted = true`，导致其以「已升级」状态存入 `M._preview`；下次光标移走时，该 buffer 作为旧预览被 `nvim_buf_delete` 删除。修复：① `nvim_win_set_buf` 之后同步 + 异步（`vim.schedule`）两次强制还原 `buflisted = false`；② 在 `bufadd` 之后检查 `is_fixed`，已 listed 的 buffer（曾被 promote）不再纳入预览追踪；③ 删除旧预览时增加 `not buflisted` 守卫作为最后一道保险
- **preview + image.nvim 兼容**：`nvim_win_set_buf` 不触发 `BufLeave`/`BufWinEnter`，导致 image.nvim 无法 hijack 图片 buffer、切走后旧图片不清除。现在对图片文件定向补发事件（通过 `nvim_win_call` 确保窗口上下文正确），非图片文件不受影响
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

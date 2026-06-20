# AGENTS.md — vv-explorer 开发指南

## 预览系统

### 核心理念：动态预览 vs 固定 buffer

vv-explorer 的预览实现了一种「零感知」体验：光标在树里移动时，主窗口会即时切换内容，但不会在 bufferline 里留下任何痕迹。直到用户主动按 `l`/`<CR>` 确认打开，该文件才变成真正的「固定」buffer

这两种状态的本质区别：

| | 动态预览 | 固定 buffer |
|--|---------|-----------|
| 来源 | 光标移动触发 | 用户按 `l`/`<CR>` 打开 |
| `buflisted` | `false`（不出现在 bufferline） | `true` |
| 生命周期 | 光标移开即删除 | 用户关闭前永久存在 |
| 追踪 | `M._preview[state]`（单槽） | 不追踪，由 Neovim 自行管理 |

### 单槽追踪

预览系统用一张 weak-key 表 `M._preview` 以 `state` 为 key，每个 explorer 实例最多只追踪**一个**动态预览 buffer。每次光标移到新文件，旧预览自动被销毁，新预览接入

### 生命周期

```
CursorMoved（树 buffer）
  → preview_file(path)
      ├─ bufadd(path)           — 复用或创建 buffer，保持 unlisted
      ├─ nvim_win_set_buf       — 换入主窗口，不移动焦点
      ├─ M._preview[state] = X  — 记录当前预览 buf
      └─ 删除上一个预览 buf      — 若满足条件

用户按 l/CR
  → open_file → :edit target（先切到目标文件）→ commit(state, main)
      ├─ 把 main 当前显示的 buffer 升级为固定（buflisted = true，纳入 bufferline 分组）
      ├─ 指向「其他文件」的陈旧预览 → 丢弃，绝不顺手升级
      └─ M._preview[state] = nil — 脱离追踪，成为固定 buffer
```

---

## 删除旧预览的条件（全部满足才删）

光标移到新文件时，上一个预览 buf（`old`）须同时满足以下所有条件才会被 `nvim_buf_delete`：

1. **有效**：`nvim_buf_is_valid(old)` — 未被其他机制删掉
2. **未修改**：`not vim.bo[old].modified` — 用户在预览中编辑过就不删（此时 `M._preview` 也已被 `BufModifiedSet` 清掉，不再追踪）
3. **未被 list**：`not vim.bo[old].buflisted` — listed 说明已升级为固定 buffer 或被第三方插件接管
4. **不在其他窗口可见**：`not is_visible_elsewhere(old)` — 多窗口场景下，buf 被其他窗口引用则不删；检索范围限定在**同一 tabpage**，不跨 tab

任一条件不满足，旧预览就被「遗忘」（`old` 引用丢失），但 buffer 本身继续存活

---

## 边界情况

### 文件不可读 / 是目录
直接跳过，不触发预览

### 主窗口已经显示该文件
`cur_buf_name == abs` 时提前返回，不重复换 buf

### 找不到主窗口
`find_main_win` 只在同一 tabpage 里找非树、非浮窗的普通窗口。只有 explorer 一个窗口时返回 `nil`，预览静默跳过

### 光标在目录行
`CursorMoved` 回调里检测 `node.is_dir`，目录不触发预览

### 用户在预览中编辑
`BufModifiedSet` autocmd 监听：一旦预览 buf 被改动，立刻清空追踪（`M._preview[state] = nil`），该 buf 不再被视为可删除的预览，自动升级为固定 buffer

### 回到已 promote 的文件（如用 k 重新移到之前用 l 打开的文件）
`bufadd` 返回已存在的 listed buf，`is_fixed = true`，不设 `buflisted = false`，也不纳入追踪（`M._preview[state] = nil`）。这样旧的预览 buf（若有）仍会被清理，而固定 buf 不受影响

### 第三方 bufferline 插件干扰（历史坑，已不再防御）
历史背景：`nvim_win_set_buf` 会触发 `BufWinEnter`，早期搭配的 `akinsho/bufferline.nvim` 会在该 autocmd 里把进入窗口的 buf 强制 `buflisted = true`，导致预览 buf 被误升级。当时在 `preview_file` 里加了「set_buf 后同步 + `vim.schedule` 再强制 unlisted」两道防御。

现状：本配置改用自研 **vv-bufferline**（akinsho 已禁用），它靠 window-local 的 `is_preview` 标记决定归属——`track_current` 与 `render` 都会跳过预览 buf，**与 buffer 的 `buflisted` 无关**。因此那两道防御已无对象，**已删除**（仅保留 set_buf 之前的一次初始 `buflisted = false`，用于让预览不进 `:ls` 且满足「旧预览可删」条件）。已在完整配置下实测：移除后预览 buf 仍保持 unlisted、不进 `:ls`、不进分组。若将来重新启用会自动 list buf 的第三方 bufferline，需要的是让那个插件尊重 unlisted，而非在此重新加 hack。

---

## 打开文件时的预览结算：commit / discard

用户主动打开文件时（永远不在 CursorMoved 里）按如下结算预览，二者都会清空 `M._preview[state]`，确保单槽不残留：

- `Preview.commit(state, win)`：用于 `open_file`（在同一主窗口打开）。**必须在 `:edit` 已切到目标文件之后调用**——这样 `win` 当前显示的就是真正打开的 buffer，把它升级为固定；同时丢弃任何指向「其他文件」的陈旧预览，**绝不把它顺手 promote**。这条「切文件在前、结算在后」的顺序，连同 vv-bufferline 的 window-local `removed` 标记，共同保证：用 `<leader>bd` 从某分屏分组删除过的 buffer，不会因为「打开另一个文件时顺手升级上一个悬停预览」而被复原
- `Preview.discard(state)`：用于 `open_in`（分屏新窗口打开）和「无主窗」兜底。只丢弃当前预览、不升级；预览 buf 若属一次性（未改 / 未 list / 别处不可见）则一并清理

> 旧实现里的 `Preview.promote(state)` 会在 `:edit` 之前、无条件升级「上一个悬停预览」，正是分组缓冲区被误复原的根因，已由 commit/discard 取代

---

## 与 bufferline 的契约

预览系统与 vv-bufferline 的契约是**显式**的，不再依赖 `buflisted`：
- `preview_file` 对非固定预览调 `mark_preview(main, target)`（→ `State.set_preview`），把该 buf 标成所在窗口的预览；
- vv-bufferline 的 `track_current` / `render` 见到 `is_preview(win, buf)` 即跳过，不纳入分组、也不渲染为标签；窗口仍显示既有固定标签（见 vv-bufferline `should_show`）；
- 升级（commit/promote）/丢弃（discard）时调 `clear_preview`，需要时 `{ promote = true }` 把它正式纳入分组。

`buflisted` 现在只承担「不进 `:ls` + 满足旧预览可删条件」，不再是「是否属于 bufferline」的判据。

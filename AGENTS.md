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
  → promote(state)
      ├─ buflisted = true       — 纳入 bufferline
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

### 第三方 bufferline 插件干扰（关键已知坑）
`nvim_win_set_buf` 会触发 `BufWinEnter` 等 autocmd。部分 bufferline 插件在这些 autocmd 中将进入窗口的 buf 强制设为 `buflisted = true`，导致动态预览 buf 被「误升级」，在下一次导航时因条件 3 不满足而无法删除，或在 promote 之前就出现在 bufferline 里

应对方案：
- `nvim_win_set_buf` 之后立刻同步还原 `buflisted = false`
- 同时调度一次 `vim.schedule(...)` 内的还原，覆盖使用 `vim.schedule` 的插件

---

## promote 的唯一调用点

`Preview.promote(state)` 只在用户主动打开文件时调用（`open_file` 和 `open_in` 均有），永远不在 CursorMoved 里调用。调用后立刻清空 `M._preview[state]`，确保单槽不残留

---

## 与 bufferline 的契约

预览系统的正确性依赖一条隐式契约：**动态预览 buf 必须保持 unlisted**。任何破坏这一点的第三方插件（在 `BufWinEnter` / `BufEnter` 中自动 list buf）都会触发上文描述的干扰问题，需要在 `preview_file` 里加防御性还原

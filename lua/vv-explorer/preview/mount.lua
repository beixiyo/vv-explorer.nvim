-- 预览追踪与挂载：谁是当前的动态预览、怎么把它挂进主窗、旧 buffer 何时能删
--
-- 「追踪」是 buf + 所属窗口一对：同一个 buffer 可能在下方 split 是固定标签、在上方
-- split 只是预览，因此固定与否是 window-local 语义，不能用全局 buflisted 表达
--
-- vv-bufferline 是可选依赖，全部交互经本模块的适配函数，缺失时退回 buflisted

local InfoBuf = require('vv-explorer.preview.info_buf')

local M = {}

-- state -> bufnr (weak key，state gc 后自动清理)
M.preview = setmetatable({}, { __mode = 'k' })

-- state -> winid。preview buffer 可能已经因其他 split 而 listed，此时需要
-- 让 vv-bufferline 按窗口跳过追踪，不能再靠全局 buflisted 表达 preview/fixed
M.preview_win = setmetatable({}, { __mode = 'k' })

-- state -> bufnr。预览链开始前主窗显示的真实 buffer，用于预览链整体撤销时原样恢复
-- （而不是回退到空白 buffer）。链内后续替换（如目录 A 换目录 B）不应覆盖它
M.restore_buf = setmetatable({}, { __mode = 'k' })

-- 预览追踪是「buf + 所属窗口 + 恢复目标」一组，置空必须成组，避免只清一半留下野引用
---@param state table
function M.reset(state)
  M.preview[state] = nil
  M.preview_win[state] = nil
  M.restore_buf[state] = nil
end

-- 同样限定在树的 tabpage 内（跨 tab 的同 buf 显示不影响本 tab 的 preview 清理决策）
---@param buf integer
---@param tree_win integer
---@return boolean
local function is_visible_elsewhere(buf, tree_win)
  if not vim.api.nvim_win_is_valid(tree_win) then return false end
  local tab = vim.api.nvim_win_get_tabpage(tree_win)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if w ~= tree_win and vim.api.nvim_win_get_buf(w) == buf then
      return true
    end
  end
  return false
end

local function bufferline()
  local ok, mod = pcall(require, 'vv-bufferline')
  if ok and type(mod) == 'table' then return mod end
end

---@param win integer
---@param buf integer
---@return boolean
function M.is_fixed_for_win(win, buf)
  local bl = bufferline()
  if bl and type(bl.has) == 'function' then
    return bl.has(win, buf)
  end

  return vim.bo[buf].buflisted
end

---@param win integer?
---@param buf integer?
---@param promote? boolean
function M.clear_bufferline(win, buf, promote)
  if not win or not buf then return end

  local bl = bufferline()
  if bl and type(bl.clear_preview) == 'function' then
    bl.clear_preview(win, buf, { promote = promote })
  end
end

---@param win integer
---@param buf integer
function M.mark_bufferline(win, buf)
  local bl = bufferline()
  if bl and type(bl.mark_preview) == 'function' then
    bl.mark_preview(win, buf)
  end
end

---@class VVExplorerPreviewMountOptions
---@field cur_buf integer 挂载前主窗显示的 buffer
---@field is_fixed boolean target 在该窗口已是固定 buffer，不纳入预览追踪
---@field was_listed boolean 挂载前 target 是否已 listed
---@field scratch boolean target 是本次新建的 scratch，挂载失败时需要删除
---@field after_mount? fun() 换 buf 成功后、清理旧 buffer 前执行

-- 把 target 挂到主窗并结算预览追踪与旧 buffer 清理。文件预览和目录预览的差异只在
-- 「target 怎么来」，挂载与清理是同一套语义，不能各写一遍
---@param state table
---@param main integer
---@param target integer
---@param opts VVExplorerPreviewMountOptions
---@return boolean mounted
function M.mount(state, main, target, opts)
  local old = M.preview[state]
  local old_win = M.preview_win[state]

  -- 「是否链内替换」只能看 cur_buf 本身是不是上一轮的预览产物，不能看 M.preview[state]
  -- 是否为 nil：主窗被 :e / :bd 等预览系统之外的操作换过之后追踪仍会残留，此时
  -- old 非 nil 但窗里已经是用户的真实内容，必须刷新恢复目标
  local cur_is_preview = opts.cur_buf == old
    or (vim.api.nvim_buf_is_valid(opts.cur_buf) and InfoBuf.is_info(opts.cur_buf))
  if not cur_is_preview then M.restore_buf[state] = opts.cur_buf end

  if old and (old ~= target or opts.is_fixed) then
    M.clear_bufferline(old_win, old, false)
  end

  if not opts.is_fixed and not opts.was_listed then
    vim.bo[target].buflisted = false
  end
  if not vim.api.nvim_buf_is_loaded(target) then
    vim.fn.bufload(target)
  end

  if not opts.is_fixed then
    M.mark_bufferline(main, target)
  end

  local ok = pcall(vim.api.nvim_win_set_buf, main, target)
  if not ok then
    M.clear_bufferline(main, target, false)
    if opts.scratch and vim.api.nvim_buf_is_valid(target) then
      pcall(vim.api.nvim_buf_delete, target, { force = true })
    end
    return false
  end

  -- 固定 buf 不追踪（不会被预览系统删除），但仍清理旧预览引用
  M.preview[state] = opts.is_fixed and nil or target
  M.preview_win[state] = opts.is_fixed and nil or main

  if opts.after_mount then opts.after_mount() end

  -- 被 displace 的 cur_buf 若是空 [No Name]（startup buffer / `:enew` 残留）→ wipe
  -- 不影响有内容/有名/被修改的 buffer；dashboard 等 bufhidden=wipe 的 buf 走自己的清理
  require('vv-utils.bufdelete').wipe_if_throwaway(opts.cur_buf)

  -- 双重保险：即使 bufferline 在 nvim_win_set_buf 期间把 old 重新 list 了，也不删
  if old and old ~= target
     and vim.api.nvim_buf_is_valid(old)
     and not vim.bo[old].modified
     and not vim.bo[old].buflisted
     and not is_visible_elsewhere(old, state.win) then
    pcall(vim.api.nvim_buf_delete, old, { force = false })
  end

  return true
end

-- 丢弃一个预览 buffer：清掉 bufferline 预览态（不升级、不复原），并在它确属一次性
-- 预览（未改、未 list、别处不可见）时清理掉，避免遗留隐藏 buffer
---@param state table
---@param buf integer?
---@param win integer?
function M.drop(state, buf, win)
  M.clear_bufferline(win, buf, false)
  if buf and vim.api.nvim_buf_is_valid(buf)
     and not vim.bo[buf].modified
     and not vim.bo[buf].buflisted
     and not is_visible_elsewhere(buf, state.win) then
    pcall(vim.api.nvim_buf_delete, buf, { force = false })
  end
end

return M

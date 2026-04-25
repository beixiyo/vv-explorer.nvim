-- VSCode 风「单击预览」buffer 行为
--   ① 树里光标移到文件 A → 主窗口自动打开 A 作为「动态预览」
--   ② 光标继续移到文件 B → 删 A、打开 B（同一时刻最多一个动态预览）
--   ③ 用户按 <CR>/l/o 打开 → 当前预览升级为「固定」（清空追踪）
--   ④ 用户在动态 buffer 里编辑 → 自动升级为固定（不能删用户改了的东西）
--
-- 边界（已处理）：
--   • 当前节点不是 file → 不预览
--   • 主窗口已显示该文件 → 跳过 :edit
--   • 没有可用主窗口（浮窗模式或只有树） → 跳过
--   • 旧预览被另一窗口共用 → 不删
--   • 旧预览处于 modified → 不删

local Window = require('vv-explorer.window')

local M = {}

-- state -> bufnr (weak key，state gc 后自动清理)
M._preview = setmetatable({}, { __mode = 'k' })

-- 必须限定在树所在 tabpage 内搜索。nvim_list_wins() 是跨所有 tab 的，
-- 用户如果在 tab 1 开了 vv-explorer、在 tab 2 开别的窗口，预览会错把 tab 2
-- 的窗口当成 "main"，nvim_win_set_buf 会把预览内容推到不相关的 tab 里。
---@param tree_win integer
---@return integer? main_win
function M.find_main_win(tree_win)
  if not vim.api.nvim_win_is_valid(tree_win) then return nil end
  local tab = vim.api.nvim_win_get_tabpage(tree_win)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if win ~= tree_win then
      local cfg = vim.api.nvim_win_get_config(win)
      local b = vim.api.nvim_win_get_buf(win)
      if cfg.relative == '' and vim.bo[b].filetype ~= Window.FILETYPE then
        return win
      end
    end
  end
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

---@param state table
---@param path string
function M.preview_file(state, path)
  if vim.fn.filereadable(path) == 0 then return end
  local abs = vim.fn.fnamemodify(path, ':p')
  local main = M.find_main_win(state.win)
  if not main then return end
  if not vim.api.nvim_win_is_valid(main) then return end

  local cur_buf = vim.api.nvim_win_get_buf(main)
  if vim.api.nvim_buf_get_name(cur_buf) == abs then return end

  local old = M._preview[state]

  -- 用 bufadd + bufload，保留焦点在树窗口；窗口换 buf 不动焦点
  local target = vim.fn.bufadd(path)
  if target == 0 then return end
  -- 预览状态保持 unlisted：避免污染 bufferline；复活已 bdelete 的旧 bufnr 时也不再
  -- 被 tab 吸进去。用户按 <CR>/l/o 走 Preview.promote → 由 :edit 自然升级为 listed
  vim.bo[target].buflisted = false
  if not vim.api.nvim_buf_is_loaded(target) then
    vim.fn.bufload(target)
  end

  -- bufload 在 Lua 调用 + 无窗口归属的路径下不会跑 filetype 检测，
  -- 导致 FileType autocmd 不 fire → treesitter 不启动 → 无高亮
  -- 显式检测一次：set filetype 会自动触发 FileType autocmd
  if vim.bo[target].filetype == '' then
    local ft = vim.filetype.match({ buf = target, filename = path })
    if ft then vim.bo[target].filetype = ft end
  end

  local ok = pcall(vim.api.nvim_win_set_buf, main, target)
  if not ok then return end
  M._preview[state] = target

  -- 被 displace 的 cur_buf 若是空 [No Name]（startup buffer / `:enew` 残留）→ wipe
  -- 不影响有内容/有名/被修改的 buffer；dashboard 等 bufhidden=wipe 的 buf 走自己的清理
  require('vv-utils.bufdelete').wipe_if_throwaway(cur_buf)

  if old and old ~= target
     and vim.api.nvim_buf_is_valid(old)
     and not vim.bo[old].modified
     and not is_visible_elsewhere(old, state.win) then
    pcall(vim.api.nvim_buf_delete, old, { force = false })
  end
end

---@param state table 用户开了文件 → 不再追踪（升级为固定）
function M.promote(state)
  local buf = M._preview[state]
  -- 升级为「固定」：此时才把 buffer 纳入 bufferline
  -- actions.lua:M.open 后续若走 :edit 也会自然 listed，这里覆盖同路径跳过 edit 的分支
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].buflisted = true
  end
  M._preview[state] = nil
end

---@param state table
function M.attach(state)
  local aug = vim.api.nvim_create_augroup('vv-explorer.preview.' .. state.buf, { clear = true })

  vim.api.nvim_create_autocmd('CursorMoved', {
    group = aug,
    buffer = state.buf,
    callback = function()
      if vim.api.nvim_get_current_win() ~= state.win then return end
      local node = require('vv-explorer.actions').node_under_cursor(state)
      if not node or node.is_dir then return end
      M.preview_file(state, node.path)
    end,
  })

  vim.api.nvim_create_autocmd('BufModifiedSet', {
    group = aug,
    callback = function(args)
      if M._preview[state] == args.buf then
        local ok, modified = pcall(function() return vim.bo[args.buf].modified end)
        if ok and modified then M._preview[state] = nil end
      end
    end,
  })
end

---@param state table
function M.detach(state)
  pcall(vim.api.nvim_del_augroup_by_name, 'vv-explorer.preview.' .. state.buf)
  M._preview[state] = nil
end

return M

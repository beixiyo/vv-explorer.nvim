-- 编辑区主窗口的定位与历史
--
-- 「哪个窗口该接收文件」这件事本身与预览无关：树里按 <CR> 打开文件、拖放落点、
-- 分屏打开都要先回答它，因此 actions 与 init 会直接使用本模块
--
-- 选取顺序：当前 state 已追踪的预览窗 → 最近聚焦过的编辑窗 → 本 tab 内第一个
-- 真实编辑窗 → 可被替换的占位窗（dashboard / 空 [No Name]）

local Mount = require('vv-explorer.preview.mount')
local Window = require('vv-explorer.window')

local M = {}

-- tabpage -> winid。用于让 explorer 打开文件时优先进入最近聚焦过的编辑 split
M.last_editor_win = {}

---@param win integer
---@return boolean
local function is_editor_win(win)
  if not vim.api.nvim_win_is_valid(win) then return false end
  if vim.api.nvim_win_get_config(win).relative ~= '' then return false end
  if vim.wo[win].winfixbuf then return false end

  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= '' then return false end
  if vim.bo[buf].filetype == Window.FILETYPE then return false end
  if vim.api.nvim_buf_get_name(buf) == '' then return false end

  return true
end

---@param buf integer
---@return boolean
local function is_empty_normal_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  if vim.bo[buf].buftype ~= '' then return false end
  if vim.bo[buf].modified then return false end
  if vim.api.nvim_buf_get_name(buf) ~= '' then return false end

  return vim.api.nvim_buf_line_count(buf) == 1
    and (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or '') == ''
end

---@param win integer
---@return boolean
local function is_replaceable_main_win(win)
  if not vim.api.nvim_win_is_valid(win) then return false end
  if vim.api.nvim_win_get_config(win).relative ~= '' then return false end
  if vim.wo[win].winfixbuf then return false end

  local buf = vim.api.nvim_win_get_buf(win)
  local ft = vim.bo[buf].filetype

  return ft == 'dashboard' or ft == 'alpha' or ft == 'ministarter' or is_empty_normal_buf(buf)
end

-- 本 tab 内除了 explorer 树窗与浮窗之外，win 是唯一的普通窗口
---@param win integer
---@return boolean
local function is_sole_content_win(win)
  local tab = vim.api.nvim_win_get_tabpage(win)
  for _, other in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if other ~= win and vim.api.nvim_win_get_config(other).relative == '' then
      if vim.bo[vim.api.nvim_win_get_buf(other)].filetype ~= Window.FILETYPE then return false end
    end
  end

  return true
end

-- vv-dashboard 是可选依赖，缺失时静默跳过（与 mount 的 vv-bufferline 适配同一手法）
--
-- 它只有「在当前窗口打开」的语义（内部自己挑窗，没有接收 winid 的入口），因此有三条约束：
--   ① 调用方必须先把 win 变成 current（见 nvim_win_call），否则内容会落到别的窗口
--   ② 本 tab 里除 win 外还有别的普通窗口时不尝试：它挑窗的规则不该在这里复刻，
--      布局不明确就交给下一级兜底，绝不冒险顶掉用户别处的 buffer
--   ③ 它是跨 tab 单例，已在别处打开时 open() 会先跳到那个窗口再返回；这一跳会触发
--      TabEnter / WinEnter 等 autocmd，所以必须在调用前用 is_open 拦下，而不是事后比对
---@param win integer 必须已经是 current window
---@return boolean handed_over win 的内容确实被换走
function M.restore_with_dashboard(win)
  if not vim.api.nvim_win_is_valid(win) then return false end
  if vim.api.nvim_get_current_win() ~= win then return false end
  if not is_sole_content_win(win) then return false end

  local ok, dashboard = pcall(require, 'vv-dashboard')
  if not ok or type(dashboard) ~= 'table' or type(dashboard.open) ~= 'function' then return false end
  if type(dashboard.is_open) == 'function' and dashboard.is_open() then return false end

  local before = vim.api.nvim_win_get_buf(win)
  pcall(dashboard.open)

  return vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) ~= before
end

-- 用一个可 list 的空 [No Name] 顶掉窗口当前内容。被顶掉的 buffer 由调用方决定去留：
-- 占位窗替换要主动删，属性页 scratch 自带 bufhidden=wipe 会自己回收
---@param win integer
---@return integer? replacement 换上去的空 buffer；窗口无效或换 buf 失败时为 nil
function M.replace_with_blank(win)
  if not vim.api.nvim_win_is_valid(win) then return nil end

  local replacement = vim.api.nvim_create_buf(true, false)
  if replacement == 0 then return nil end
  if not pcall(vim.api.nvim_win_set_buf, win, replacement) then
    pcall(vim.api.nvim_buf_delete, replacement, { force = true })
    return nil
  end

  return replacement
end

---@param win integer
---@return integer prev_buf
function M.prepare_main_win(win)
  local prev_buf = vim.api.nvim_win_get_buf(win)
  if not is_replaceable_main_win(win) then return prev_buf end
  if not M.replace_with_blank(win) then return prev_buf end

  if vim.api.nvim_buf_is_valid(prev_buf) and #vim.fn.win_findbuf(prev_buf) == 0 then
    pcall(vim.api.nvim_buf_delete, prev_buf, { force = true })
  end

  return prev_buf
end

---@param win integer?
function M.remember_editor_win(win)
  win = win or vim.api.nvim_get_current_win()
  if not is_editor_win(win) then return end

  local tab = vim.api.nvim_win_get_tabpage(win)
  M.last_editor_win[tab] = win
end

function M.setup_editor_history()
  local group = vim.api.nvim_create_augroup('vv-explorer.editor-history', { clear = true })

  vim.api.nvim_create_autocmd({ 'WinEnter', 'BufEnter' }, {
    group = group,
    callback = function() M.remember_editor_win() end,
  })

  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(args)
      local closed = tonumber(args.match)
      if not closed then return end

      for tab, win in pairs(M.last_editor_win) do
        if win == closed then M.last_editor_win[tab] = nil end
      end
    end,
  })
end

-- 必须限定在树所在 tabpage 内搜索。nvim_list_wins() 是跨所有 tab 的，
-- 用户如果在 tab 1 开了 vv-explorer、在 tab 2 开别的窗口，预览会错把 tab 2
-- 的窗口当成 "main"，nvim_win_set_buf 会把预览内容推到不相关的 tab 里
---@param tree_win integer
---@param state? table
---@return integer? main_win
function M.find_main_win(tree_win, state)
  if not vim.api.nvim_win_is_valid(tree_win) then return nil end
  local tab = vim.api.nvim_win_get_tabpage(tree_win)

  -- binary info 使用 nofile scratch，不能通过 is_editor_win；只复用当前 state 已追踪的
  -- preview window，避免把其它特殊窗口误判为编辑区
  local preview_win = state and Mount.preview_win[state]
  local preview_buf = state and Mount.preview[state]
  if preview_win
      and preview_buf
      and preview_win ~= tree_win
      and vim.api.nvim_win_is_valid(preview_win)
      and vim.api.nvim_buf_is_valid(preview_buf)
      and vim.api.nvim_win_get_buf(preview_win) == preview_buf
      and vim.api.nvim_win_get_tabpage(preview_win) == tab
      and vim.api.nvim_win_get_config(preview_win).relative == ''
      and not vim.wo[preview_win].winfixbuf then
    return preview_win
  end

  local last = M.last_editor_win[tab]
  if last
     and last ~= tree_win
     and vim.api.nvim_win_is_valid(last)
     and vim.api.nvim_win_get_tabpage(last) == tab
     and is_editor_win(last)
  then
    return last
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if win ~= tree_win then
      if is_editor_win(win) then
        return win
      end
    end
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if win ~= tree_win and is_replaceable_main_win(win) then
      return win
    end
  end
end

return M

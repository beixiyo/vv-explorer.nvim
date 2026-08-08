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

---@param win integer
---@return integer prev_buf
function M.prepare_main_win(win)
  local prev_buf = vim.api.nvim_win_get_buf(win)
  if not is_replaceable_main_win(win) then return prev_buf end

  local replacement = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(win, replacement)

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

-- 窗口/缓冲区管理
-- buffer 用 bufhidden='hide'：close 时 window 关掉但 buf 留住，下次 open 秒显
-- buffer 和 window 的生命周期分离：
--   create_buf()     — 只在首次 open 调用
--   open_split(buf)  — 每次 open 都调用，创建新 split 并挂上 buf
--   close(win)       — close 时只关 win，不动 buf

local M = {}

M.FILETYPE = 'vv-explorer'

---@return integer buf  创建并配置好 vv-explorer 的 buffer（bufhidden='hide'）
function M.create_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = 'hide' -- 关键：窗口关时 buf 保留
  vim.bo[buf].filetype = M.FILETYPE
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, 'vv-explorer://' .. tostring(buf))
  return buf
end

---@param win integer
local function apply_win_opts(win)
  require('vv-utils.ui_window').hide_chrome(win, {
    cursorline = true,
    winfixwidth = true,
    -- winfixbuf：从根上拒绝任何 :edit / :bnext / LSP 跳转把别的 buf 切进来
    -- 配合 actions.M.open 的"切到 main 再 :edit"模型，文件树窗口的 winopts
    -- 永远不会污染到普通文件 buffer。需要 Neovim 0.10+
    winfixbuf = true,
  })
end

---@param buf integer  要挂上去的 buffer
---@param opts {position:'left'|'right', width:integer}
---@return integer win, integer prev_win
function M.open_split(buf, opts)
  local prev = vim.api.nvim_get_current_win()
  local cmd = opts.position == 'right' and 'botright vsplit' or 'topleft vsplit'
  vim.cmd(cmd)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(win, opts.width)
  vim.api.nvim_win_set_buf(win, buf)
  apply_win_opts(win)
  return win, prev
end

---@param win integer  只关 window，不动 buf（靠 bufhidden='hide' 保留内容）
function M.close_win(win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

---@param buf integer  真正销毁 buffer（用户退出 nvim / 手动 :bwipe）
function M.wipe_buf(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

return M

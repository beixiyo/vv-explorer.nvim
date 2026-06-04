-- 拖拽落点（VSCode 风）：基于 kitty DnD 协议（OSC 72），把鼠标松手的屏幕 cell 映射到
-- 树里的目标目录并复制进去；拖拽经过时实时高亮目标目录行。
--
-- 仅在 kitty ≥ 0.47 且 nvim 不挂 tmux 时生效（坐标事件由 vv-utils.drop 自动探测并喂入；
-- tmux 不透传入站 OSC，届时 vv-utils.drop 回退到 vim.paste 路径 → 复制到光标目录 / 打开文件）。
--
-- 坐标系：kitty 上报的 x/y 是屏幕 cell（原点左上）。nvim 直跑 kitty（无 tmux）时，屏幕格
-- 即 nvim 的全局编辑器格，nvim_win_get_position 同源，可直接换算到窗口内行。

local Actions = require('vv-explorer.actions')

local M = {}
local hl_ns = vim.api.nvim_create_namespace('vv-explorer.dnd')

---@param state table
local function clear_hl(state)
  state._dnd_hl = nil
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_clear_namespace(state.buf, hl_ns, 0, -1)
  end
end

-- 屏幕 cell (x,y) → explorer buffer 行号；落在窗外返回 nil，落在树下方空白处归到 root 行
---@param state table
---@param x integer
---@param y integer
---@return integer?
local function cell_to_lnum(state, x, y)
  local win = state.win
  if not win or not vim.api.nvim_win_is_valid(win) then return nil end
  if not vim.api.nvim_buf_is_valid(state.buf) then return nil end
  -- explorer 在别的 tabpage → 其 win 坐标会和当前 tab 屏幕重叠，误判落点，直接放弃
  if vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage() then return nil end

  local pos = vim.api.nvim_win_get_position(win) -- {row, col} 0-based，全局屏幕格
  local wrow, wcol = pos[1], pos[2]
  local w = vim.api.nvim_win_get_width(win)
  local h = vim.api.nvim_win_get_height(win)
  if x < wcol or x >= wcol + w then return nil end
  if y < wrow or y >= wrow + h then return nil end

  local info = vim.fn.getwininfo(win)[1]
  if not info then return nil end
  local winbar = (info.winbar == 1) and 1 or 0
  local row_in_text = y - wrow - winbar
  if row_in_text < 0 then return nil end -- 落在 winbar 上

  local lnum = info.topline + row_in_text -- wrap=false 时一行 buffer = 一行屏幕
  local last = vim.api.nvim_buf_line_count(state.buf)
  if lnum > last then return 1 end -- 树下方空白 → root
  return lnum
end

-- 该行对应的目标目录：目录行→自身，文件行→父目录，root/越界→根
---@param state table
---@param lnum integer
---@return string
local function dir_for_lnum(state, lnum)
  local node = Actions.node_at_line(state, lnum)
  if not node or node == state.root then return state.root.path end
  if node.is_dir then return node.path end
  return vim.fs.dirname(node.path)
end

-- 拖拽移动：高亮目标目录所在行（同一行则跳过，避免抖动）
---@param state table
---@param x integer
---@param y integer
local function on_move(state, x, y)
  local lnum = cell_to_lnum(state, x, y)
  if not lnum then return clear_hl(state) end

  local dir = dir_for_lnum(state, lnum)
  local drow = (state.path_to_row and state.path_to_row[dir]) or 1
  if state._dnd_hl == drow then return end

  clear_hl(state)
  state._dnd_hl = drow
  pcall(vim.api.nvim_buf_set_extmark, state.buf, hl_ns, drow - 1, 0, {
    line_hl_group = 'VVExplorerDropTarget',
  })
end

--- 接到 vv-utils.drop 的拖拽事件流与落点
---@param get_state fun(): table?  返回当前 explorer state（关闭时为 nil）
function M.attach(get_state)
  local drop = require('vv-utils.drop')

  drop.on_drag(function(ev)
    local s = get_state()
    if not s then return end
    if ev.kind == 'leave' then return clear_hl(s) end
    on_move(s, ev.x, ev.y)
  end)

  drop.register(function(paths, pos)
    local s = get_state()
    if not s then return false end

    if pos then
      -- kitty DnD：按落点 cell 决定目录
      clear_hl(s)
      local lnum = cell_to_lnum(s, pos.x, pos.y)
      if not lnum then return false end -- 落在 explorer 窗外 → 交回默认（打开文件）
      local dir = dir_for_lnum(s, lnum)
      vim.schedule(function() Actions.drop_into(s, paths, dir) end)
      return true
    end

    -- 回退（无坐标，如 tmux）：仅当 explorer 聚焦时复制到光标目录
    if vim.api.nvim_get_current_buf() ~= s.buf then return false end
    vim.schedule(function() Actions.drop_paste(s, paths) end)
    return true
  end)
end

return M

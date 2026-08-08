-- libuv fs_event 自动刷新：监听所有 open 状态的目录
-- 文件系统变化 → 防抖 150ms → refresh 树 + render

local uv = vim.uv or vim.loop
local Timer = require('vv-utils.timer')

local FS_DEBOUNCE_MS = 150

local M = {}

---@param state table
function M.attach(state)
  state._watches = state._watches or {}

  local function do_refresh()
    if not vim.api.nvim_buf_is_valid(state.buf) then return end
    local Tree = require('vv-explorer.tree')
    local Render = require('vv-explorer.render')

    -- tree 数据一直刷新（即使窗口隐藏也要保持最新，下次打开不用重扫）
    Tree.refresh(state.root)

    -- 目录统计是递归的，任何一层的增删都会让缓存的总大小 / 文件数失真
    require('vv-explorer.preview.dir').invalidate_cache(state)

    -- git 状态跟随文件系统变化刷新（git 自身 debounce，会在索引完成后再 render 一次）
    if state.git and state.git.refresh then state.git.refresh() end

    -- 但 render 只在 window 有效时做（hide 期间没窗口，render 没意义）
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      Render.render_stable(state)
    end
  end

  local refresh_debounced, cancel_refresh = Timer.debounce(do_refresh, FS_DEBOUNCE_MS)
  state._fs_cancel = cancel_refresh

  local function watch_dir(path)
    if state._watches[path] then return end
    local handle = uv.new_fs_event()
    if not handle then return end
    local ok = pcall(handle.start, handle, path, {}, function() refresh_debounced() end)
    if ok then
      state._watches[path] = handle
    else
      pcall(handle.close, handle)
    end
  end

  local function rescan()
    if not state.root then return end
    local Tree = require('vv-explorer.tree')
    local used = {}
    for _, p in ipairs(Tree.open_dirs(state.root)) do
      used[p] = true
      watch_dir(p)
    end
    for path, handle in pairs(state._watches) do
      if not used[path] then
        pcall(handle.close, handle)
        state._watches[path] = nil
      end
    end
  end

  state._rescan_watches = rescan
  rescan()
end

---@param state table
function M.detach(state)
  for _, handle in pairs(state._watches or {}) do
    pcall(handle.close, handle)
  end

  state._watches = {}

  if state._fs_cancel then
    pcall(state._fs_cancel)
    state._fs_cancel = nil
  end
  state._rescan_watches = nil
end

return M

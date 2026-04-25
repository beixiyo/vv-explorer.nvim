-- libuv fs_event 自动刷新：监听所有 open 状态的目录
-- 文件系统变化 → 防抖 150ms → refresh 树 + render

local uv = vim.uv or vim.loop

local FS_DEBOUNCE_MS = 150

local M = {}

---@param state table
function M.attach(state)
  state._watches = state._watches or {}
  state._timer = state._timer or assert(uv.new_timer())

  local function refresh_debounced()
    state._timer:stop()
    state._timer:start(FS_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
      if not vim.api.nvim_buf_is_valid(state.buf) then return end
      local Tree = require('vv-explorer.tree')
      local Render = require('vv-explorer.render')
      -- tree 数据一直刷新（即使窗口隐藏也要保持最新，下次打开不用重扫）
      Tree.refresh(state.root)
      -- git 状态跟随文件系统变化刷新（git 自身 debounce，会在索引完成后再 render 一次）
      if state.git and state.git.refresh then state.git.refresh() end
      -- 但 render 只在 window 有效时做（hide 期间没窗口，render 没意义）
      if state.win and vim.api.nvim_win_is_valid(state.win) then
        Render.render(state)
      end
    end))
  end

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
  if state._timer then
    pcall(state._timer.stop, state._timer)
    pcall(state._timer.close, state._timer)
    state._timer = nil
  end
  state._rescan_watches = nil
end

return M

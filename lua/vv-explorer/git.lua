-- vv-explorer 的 git 适配层：attach/detach + 200ms debounce 刷新
-- 纯数据逻辑（porcelain 解析 / ignored 判断 / 符号表）在 vv-utils.git

local uv = vim.uv or vim.loop
local UGit = require('vv-utils.git')

local M = {}

local DEBOUNCE_MS = 200

-- status (含 --ignored) 完成时调用：覆盖 status_map / is_ignored
-- 不动 is_tracked，那条线由 apply_tracked 单独管，时序可以早于 status
local function apply(state, idx)
  state.git = state.git or {}
  if idx then
    state.git.status_map = idx.status_map
    state.git.is_ignored = idx.is_ignored
  else
    state.git.status_map = {}
    state.git.is_ignored = function() return false end
  end
end

local function apply_tracked(state, t)
  state.git = state.git or {}
  if t then
    state.git.is_tracked = t.is_tracked
  else
    state.git.is_tracked = function() return false end
  end
end

---@param state table
function M.attach(state)
  state.git = state.git or {}
  state.git.status_map = state.git.status_map or {}
  state.git.is_ignored = state.git.is_ignored or function() return false end
  state.git.is_tracked = state.git.is_tracked or function() return false end
  state.git._timer = state.git._timer or assert(uv.new_timer())
  state.git._tracked_timer = state.git._tracked_timer or assert(uv.new_timer())

  local function rerender()
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      require('vv-explorer.render').render(state)
    end
  end

  -- status（--ignored）一次拉取 + apply + 重画；可选 after 回调（用于 debounced caller 串行）
  local function run_status(after)
    UGit.index(state.root.path, function(idx)
      apply(state, idx)
      rerender()
      if after then after() end
    end)
  end

  -- tracked 一次拉取 + apply + 重画
  local function run_tracked()
    UGit.tracked(state.root.path, function(t)
      apply_tracked(state, t)
      rerender()
    end)
  end

  state.git.refresh = function(after)
    if not state.git then return end
    -- status (--ignored) 在 HOME-as-repo 这种大仓上可能要几秒，独立 debounce
    if state.git._timer then
      state.git._timer:stop()
      state.git._timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function() run_status(after) end))
    end
    -- tracked 只读 .git/index，毫秒级；不能被慢的 status 拖，独立 debounce + render
    if state.git._tracked_timer then
      state.git._tracked_timer:stop()
      state.git._tracked_timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(run_tracked))
    end
  end

  -- 首次：两条线并行跑，各自完成各自重画（不走 debounce，要立刻拉数据）。
  -- tracked 通常几十 ms 就回来，dotfile 立刻可见；status 慢就慢，不影响 tracked dotfile 的早期可见性。
  run_tracked()
  run_status()
end

---@param state table
function M.detach(state)
  if not state or not state.git then return end
  if state.git._timer then
    pcall(state.git._timer.stop, state.git._timer)
    pcall(state.git._timer.close, state.git._timer)
  end
  if state.git._tracked_timer then
    pcall(state.git._tracked_timer.stop, state.git._tracked_timer)
    pcall(state.git._tracked_timer.close, state.git._tracked_timer)
  end
  state.git = nil
end

-- render.lua 通过 M.symbol_for(xy) 查符号，转发 vv-utils.git
M.symbol_for = UGit.symbol_for

return M

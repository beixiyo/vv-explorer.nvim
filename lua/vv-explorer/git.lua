-- vv-explorer 的 git 适配层：attach/detach + 200ms debounce 刷新
-- 纯数据逻辑（porcelain 解析 / ignored 判断 / 符号表）在 vv-utils.git
--
-- ignored 检测策略（v2）：
--   不再用 `git status --ignored`（HOME-as-repo 递归扫全盘 13s+），
--   改为 `git ls-files --others --ignored --directory`：
--   `--directory` 让 git 不递归进 ignored 目录，20ms 拿到全量 ignored。

local uv = vim.uv or vim.loop
local UGit = require('vv-utils.git')

local M = {}

local DEBOUNCE_MS = 200

---@param state table
function M.attach(state)
  state.git = state.git or {}
  state.git.status_map = state.git.status_map or {}
  state.git.is_ignored = state.git.is_ignored or function() return false end
  state.git.is_tracked = state.git.is_tracked or function() return false end
  state.git._timer = state.git._timer or assert(uv.new_timer())
  state.git._tracked_timer = state.git._tracked_timer or assert(uv.new_timer())
  state.git._ignored_timer = state.git._ignored_timer or assert(uv.new_timer())

  local function rerender()
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      require('vv-explorer.render').render(state)
    end
  end

  -- status（不含 --ignored）：只拿 modified/added/untracked 等状态标记
  local function run_status(after)
    UGit.index(state.root.path, function(idx)
      state.git = state.git or {}
      if idx then
        state.git.status_map = idx.status_map
      else
        state.git.status_map = {}
      end
      rerender()
      if after then after() end
    end, { ignored = false, scope = true })
  end

  -- tracked：只读 .git/index，毫秒级
  local function run_tracked()
    UGit.tracked(state.root.path, function(t)
      state.git = state.git or {}
      if t then
        state.git.is_tracked = t.is_tracked
      else
        state.git.is_tracked = function() return false end
      end
      rerender()
    end, { scope = true })
  end

  -- ignored：ls-files --others --ignored --directory，不递归进 ignored 目录
  local function run_ignored()
    UGit.ignored_entries(state.root.path, function(ifiles, idirs)
      state.git = state.git or {}
      state.git.is_ignored = UGit.make_is_ignored(ifiles, idirs)
      rerender()
    end, { scope = true })
  end

  state.git.refresh = function(after)
    if not state.git then return end
    if state.git._timer then
      state.git._timer:stop()
      state.git._timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function() run_status(after) end))
    end
    if state.git._tracked_timer then
      state.git._tracked_timer:stop()
      state.git._tracked_timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(run_tracked))
    end
    if state.git._ignored_timer then
      state.git._ignored_timer:stop()
      state.git._ignored_timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(run_ignored))
    end
  end

  -- 首次：三条线并行跑，各自完成各自重画
  run_tracked()
  run_status()
  run_ignored()
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
  if state.git._ignored_timer then
    pcall(state.git._ignored_timer.stop, state.git._ignored_timer)
    pcall(state.git._ignored_timer.close, state.git._ignored_timer)
  end
  state.git = nil
end

-- render.lua 通过 M.symbol_for(xy) 查符号，转发 vv-utils.git
M.symbol_for = UGit.symbol_for

return M

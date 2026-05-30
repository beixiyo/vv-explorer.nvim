-- vv-explorer 的 git 适配层：attach/detach + 200ms debounce 刷新
-- 纯数据逻辑（porcelain 解析 / ignored 判断 / 符号表）在 vv-utils.git
--
-- ignored 检测策略（v2）：
--   不再用 `git status --ignored`（HOME-as-repo 递归扫全盘 13s+），
--   改为 `git ls-files --others --ignored --directory`：
--   `--directory` 让 git 不递归进 ignored 目录，20ms 拿到全量 ignored。

local UGit = require('vv-utils.git')
local Timer = require('vv-utils.timer')

local M = {}

local DEBOUNCE_MS = 200

---@param state table
function M.attach(state)
  state.git = state.git or {}
  state.git.status_map = state.git.status_map or {}
  state.git.is_ignored = state.git.is_ignored or function() return false end
  state.git.is_tracked = state.git.is_tracked or function() return false end

  local function rerender()
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      require('vv-explorer.render').render_stable(state)
    end
  end

  -- status（不含 --ignored）：只拿 modified/added/untracked 等状态标记
  local function run_status(after)
    UGit.index(state.root.path, function(idx)
      if not state.git then return end -- detach 后丢弃在途结果，不复活孤儿 state.git
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
      if not state.git then return end -- 同上：detach 后短路
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
      if not state.git then return end -- 同上：detach 后短路
      state.git.is_ignored = UGit.make_is_ignored(ifiles, idirs)
      rerender()
    end, { scope = true })
  end

  -- 三条线各自 debounce（复用 vv-utils.timer.debounce：内部 stop+restart + schedule_wrap）
  -- debounce 会转发参数，故 refresh_status(after) → run_status(after)，语义不变
  local refresh_status,  cancel_status  = Timer.debounce(run_status,  DEBOUNCE_MS)
  local refresh_tracked, cancel_tracked = Timer.debounce(run_tracked, DEBOUNCE_MS)
  local refresh_ignored, cancel_ignored = Timer.debounce(run_ignored, DEBOUNCE_MS)
  state.git._cancels = { cancel_status, cancel_tracked, cancel_ignored }

  state.git.refresh = function(after)
    if not state.git then return end
    refresh_status(after)
    refresh_tracked()
    refresh_ignored()
  end

  -- 首次：三条线并行跑，各自完成各自重画
  run_tracked()
  run_status()
  run_ignored()
end

---@param state table
function M.detach(state)
  if not state or not state.git then return end
  for _, cancel in ipairs(state.git._cancels or {}) do
    pcall(cancel)
  end
  state.git = nil
end

-- render.lua 通过 M.symbol_for(xy) 查符号，转发 vv-utils.git
M.symbol_for = UGit.symbol_for

return M

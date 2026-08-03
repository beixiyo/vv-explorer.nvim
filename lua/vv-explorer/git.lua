-- vv-explorer 的 git 适配层：attach/detach + 200ms debounce 刷新
-- 纯数据逻辑（porcelain 解析 / ignored 判断 / 符号表）在 vv-utils.git
--
-- ignored 检测策略（v2）：
--   不再用 `git status --ignored`（HOME-as-repo 递归扫全盘 13s+），
--   改为 `git ls-files --others --ignored --directory`：
--   `--directory` 让 git 不递归进 ignored 目录，20ms 拿到全量 ignored

local UGit = require('vv-utils.git')
local Async = require('vv-utils.async')
local Timer = require('vv-utils.timer')

local M = {}

local DEBOUNCE_MS = 200

---@param state table
function M.attach(state)
  if state.git then
    for _, cancel in ipairs(state.git._cancels or {}) do pcall(cancel) end
    if state.git._scope then state.git._scope:dispose() end
  end
  state.git = {}
  local git_state = state.git
  local request_scope = Async.scope()
  git_state._scope = request_scope
  state.git.status_map = state.git.status_map or {}
  state.git.is_ignored = state.git.is_ignored or function() return false end
  state.git.is_tracked = state.git.is_tracked or function() return false end

  local function rerender()
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      require('vv-explorer.render').render_stable(state)
    end
  end

  -- status（不含 --ignored）：只拿 modified/added/untracked 等状态标记
  local function begin(key)
    return request_scope:begin({ key = key, cancel_previous = true })
  end

  local function run_status(after, request, root)
    request = request or begin('status')
    root = root or state.root.path
    if not request:is_current() then return end
    local cancel = UGit.index(root, function(idx)
      local current = request:finish()
      if not current or state.git ~= git_state or state.root.path ~= root then return end
      if idx then
        state.git.status_map = idx.status_map
      else
        state.git.status_map = {}
      end
      rerender()
      if after then after() end
    end, { ignored = false, scope = true })
    request:set_cancel(cancel)
  end

  -- tracked：只读 .git/index，毫秒级
  local function run_tracked(request, root)
    request = request or begin('tracked')
    root = root or state.root.path
    if not request:is_current() then return end
    local cancel = UGit.tracked(root, function(t)
      local current = request:finish()
      if not current or state.git ~= git_state or state.root.path ~= root then return end
      if t then
        state.git.is_tracked = t.is_tracked
      else
        state.git.is_tracked = function() return false end
      end
      rerender()
    end, { scope = true })
    request:set_cancel(cancel)
  end

  -- ignored：ls-files --others --ignored --directory，不递归进 ignored 目录
  local function run_ignored(request, root)
    request = request or begin('ignored')
    root = root or state.root.path
    if not request:is_current() then return end
    local cancel = UGit.ignored_entries(root, function(ifiles, idirs)
      local current = request:finish()
      if not current or state.git ~= git_state or state.root.path ~= root then return end
      state.git.is_ignored = UGit.make_is_ignored(ifiles, idirs)
      rerender()
    end, { scope = true })
    request:set_cancel(cancel)
  end

  -- 三条线各自 debounce（复用 vv-utils.timer.debounce：内部 stop+restart + schedule_wrap）
  -- debounce 会转发参数，故 refresh_status(after) → run_status(after)，语义不变
  local refresh_status,  cancel_status  = Timer.debounce(run_status,  DEBOUNCE_MS)
  local refresh_tracked, cancel_tracked = Timer.debounce(run_tracked, DEBOUNCE_MS)
  local refresh_ignored, cancel_ignored = Timer.debounce(run_ignored, DEBOUNCE_MS)
  state.git._cancels = { cancel_status, cancel_tracked, cancel_ignored }

  state.git.refresh = function(after)
    if state.git ~= git_state then return end
    local root = state.root.path
    refresh_status(after, begin('status'), root)
    refresh_tracked(begin('tracked'), root)
    refresh_ignored(begin('ignored'), root)
  end

  -- 外部 git 状态变更的刷新触发器（watch.lua 的 fs_event 只感知工作树文件变化，
  -- 感知不到 .git/ 里的 index/HEAD 变更，故 commit/push 等不会触发它）：
  --   * User VVGitStatusChanged —— vv-git 的 stage/commit/push 等操作完成后广播（即时）
  --   * FocusGained ——————————— 从别的窗口/另一个 nvim 切回来（独立终端里跑 git 的场景）
  --   * TermClose/TermLeave ————— 退出内嵌终端（ClaudeCode/Codex 在 :terminal 里直接跑 git）
  -- 三条 refresh 各自 200ms 去抖，重复/同 tick 的事件会自动合并
  local aug = vim.api.nvim_create_augroup('VVExplorerGitRefresh', { clear = true })
  local function on_external_change()
    if state.git and state.git.refresh then state.git.refresh() end
  end
  vim.api.nvim_create_autocmd({ 'FocusGained', 'TermClose', 'TermLeave' }, {
    group = aug,
    callback = on_external_change,
  })
  vim.api.nvim_create_autocmd('User', {
    group = aug,
    pattern = 'VVGitStatusChanged',
    callback = on_external_change,
  })

  -- 首次：三条线并行跑，各自完成各自重画
  run_tracked()
  run_status()
  run_ignored()
end

---@param state table
function M.detach(state)
  if not state or not state.git then return end
  pcall(vim.api.nvim_del_augroup_by_name, 'VVExplorerGitRefresh')
  for _, cancel in ipairs(state.git._cancels or {}) do
    pcall(cancel)
  end
  if state.git._scope then state.git._scope:dispose() end
  state.git = nil
end

-- render.lua 通过 M.symbol_for(xy) 查符号，转发 vv-utils.git
M.symbol_for = UGit.symbol_for

return M

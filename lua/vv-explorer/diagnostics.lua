-- vv-explorer 的 diagnostics 适配层：订阅 DiagnosticChanged → 填 state.diagnostics → 重画
-- 路径聚合 + 符号选择在 vv-utils.diagnostics

local UDiag = require('vv-utils.diagnostics')

local M = {}

local function refresh(state)
  -- 树窗口未打开时直接跳过：collect_by_path 会遍历所有 loaded buffer 取诊断计数，
  -- 而 render 反正因 win 失效被跳过 —— 全量扫描纯属浪费。仅关窗保留 buf（close_window_only）、
  -- 树长期隐藏期间，DiagnosticChanged 仍高频触发本回调，这里短路掉无谓工作。
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then return end
  state.diagnostics = UDiag.collect_by_path()
  require('vv-explorer.render').render(state)
end

---@param state table
function M.attach(state)
  state.diagnostics = state.diagnostics or {}
  local aug = vim.api.nvim_create_augroup('vv-explorer.diagnostics.' .. state.buf, { clear = true })
  vim.api.nvim_create_autocmd('DiagnosticChanged', {
    group = aug,
    callback = function() vim.schedule(function() refresh(state) end) end,
  })
  -- 首次：调度一次（LSP 可能还没 attach，晚一点更稳）
  vim.schedule(function() refresh(state) end)
end

---@param state table
function M.detach(state)
  if not state or not state.buf then return end
  pcall(vim.api.nvim_del_augroup_by_name, 'vv-explorer.diagnostics.' .. state.buf)
  state.diagnostics = nil
end

-- render.lua 通过 M.symbol_for(counts) 查符号，转发 vv-utils.diagnostics
M.symbol_for = UDiag.symbol_for

-- 重开树（场景 A）时由 init.lua 调用：隐藏期间 refresh 被 win 守卫短路、state.diagnostics 不再更新，
-- 重开需补一次，避免渲染陈旧诊断
M.refresh = refresh

return M

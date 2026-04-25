-- vv-explorer 的 diagnostics 适配层：订阅 DiagnosticChanged → 填 state.diagnostics → 重画
-- 路径聚合 + 符号选择在 vv-utils.diagnostics

local UDiag = require('vv-utils.diagnostics')

local M = {}

local function refresh(state)
  state.diagnostics = UDiag.collect_by_path()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    require('vv-explorer.render').render(state)
  end
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

return M

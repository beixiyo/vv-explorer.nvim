-- 折叠目录链的层级选择、目标解析与高亮生命周期

local M = {}

local CHAIN_NS = vim.api.nvim_create_namespace('vv-explorer.chain_sel')

---@param tip table
---@param chain string[]
---@param idx integer
---@return table
local function node_at(tip, chain, idx)
  local node = tip
  for _ = 1, (#chain - idx) do
    if not node.parent then break end
    node = node.parent
  end
  return node
end

---@param state table
---@param H table
---@return table?
function M.target_node(state, H)
  local node = H.node_under_cursor(state)
  if not node then return nil end

  local row = H.row_under_cursor(state)
  if not row or not row.group_chain or #row.group_chain <= 1 then return node end

  local selection = state._chain_sel
  local line = vim.api.nvim_win_get_cursor(state.win)[1]
  local index = selection and selection.lnum == line and selection.idx or #row.group_chain
  return node_at(node, row.group_chain, index)
end

---@param state table
function M.reset(state)
  state._chain_sel = nil
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_clear_namespace(state.buf, CHAIN_NS, 0, -1)
  end
end

---@param Actions table
---@param H table
function M.attach(Actions, H)
  ---@param state table
  ---@param delta integer
  local function select(state, delta)
    if not vim.api.nvim_win_is_valid(state.win) then return end

    local line = vim.api.nvim_win_get_cursor(state.win)[1]
    local row = H.row_at_line(state, line)
    if not row or not row.group_chain or #row.group_chain <= 1 then return end

    local count = #row.group_chain
    local selection = state._chain_sel
    if not selection or selection.lnum ~= line then
      selection = { lnum = line, idx = count }
    end

    selection.idx = math.min(count, math.max(1, selection.idx + delta))
    state._chain_sel = selection

    vim.api.nvim_buf_clear_namespace(state.buf, CHAIN_NS, 0, -1)
    local name_col = state.name_cols and state.name_cols[line] or 0
    local offset = 0
    for index = 1, selection.idx do
      offset = offset + #row.group_chain[index]
      if index < selection.idx then offset = offset + 1 end
    end

    pcall(vim.api.nvim_buf_set_extmark, state.buf, CHAIN_NS, line - 1, name_col, {
      end_col = name_col + offset,
      hl_group = 'VVExplorerMatch',
      priority = 200,
    })
  end

  function Actions.chain_select_deeper(state) select(state, 1) end
  function Actions.chain_select_shallower(state) select(state, -1) end

  ---@param state table
  function Actions.chain_sel_clear(state)
    if not state._chain_sel then return end
    M.reset(state)
  end
end

return M

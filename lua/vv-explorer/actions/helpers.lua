-- actions 子模块间共享的辅助函数

local Render = require('vv-explorer.render')

local H = {}

H.EMPTY_MATCHED = { abs = {}, rels = {}, positions = {}, total_count = 0 }

---@param path string
---@param opts VVExplorerConfig
---@return boolean
function H.is_binary(path, opts)
  local cfg = opts.binary
  if not cfg or not cfg.intercept then return false end
  local ext = path:match('%.([%w_]+)$')
  return ext and cfg.extensions[ext:lower()] or false
end

---@param state table
function H.ensure_state_fields(state)
  state.selection = state.selection or {}
  state.clipboard = state.clipboard or nil
end

---@param state table
---@return string[]
function H.selected_paths(state)
  local out = {}
  for p in pairs(state.selection or {}) do out[#out + 1] = p end
  table.sort(out)
  return out
end

---@param state table
---@param path string?
function H.focus_path(state, path)
  if not path or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local lnum = state.path_to_row and state.path_to_row[path]
  if lnum then
    pcall(vim.api.nvim_win_set_cursor, state.win, { lnum, 0 })
  end
end

---@param state table
---@return table?
function H.node_under_cursor(state)
  if not vim.api.nvim_win_is_valid(state.win) then return nil end
  local lnum = vim.api.nvim_win_get_cursor(state.win)[1]
  local f = state.filter
  if f and f.active and (f.query or '') ~= '' then
    local row = state.rows and state.rows[lnum]
    return row and row.node or nil
  end
  if lnum == 1 then return state.root end
  local row = state.rows and state.rows[lnum - 1]
  return row and row.node or nil
end

-- 在 explorer 窗内执行 split-like 命令打开 path，并把新窗口 chrome 拉回全局默认
---@param state table
---@param cmd string
---@param path string
function H.open_in_explorer_split(state, cmd, path)
  vim.api.nvim_set_current_win(state.win)
  vim.cmd(cmd .. ' ' .. vim.fn.fnameescape(path))
  require('vv-utils.ui_window').show_chrome(vim.api.nvim_get_current_win())
end

---@param state table
function H.render(state) Render.render(state) end

return H

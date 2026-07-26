-- Buffer-local mappings and cursor behavior for the explorer panel

local M = {}

---@param state table
local function apply_wrap_movement(state)
  local function move(delta)
    local last = vim.api.nvim_buf_line_count(state.buf)
    if last <= 0 then return end
    local line = vim.api.nvim_win_get_cursor(state.win)[1]
    local target = ((line - 1 + delta) % last + last) % last + 1
    vim.api.nvim_win_set_cursor(state.win, { target, 0 })
  end

  for lhs, delta in pairs({ j = 1, k = -1, ['<Down>'] = 1, ['<Up>'] = -1 }) do
    local direction = delta == 1 and 'next' or 'prev'
    vim.keymap.set('n', lhs, function() move(delta) end, {
      buffer = state.buf,
      nowait = true,
      silent = true,
      desc = 'vv-explorer: ' .. direction .. ' (wrap)',
    })
  end
end

---@param state table
---@param opts {mappings:table<string, string|false|fun(state:table)>, actions:table, close:fun()}
function M.apply(state, opts)
  apply_wrap_movement(state)

  for lhs, action in pairs(opts.mappings) do
    if action then
      local is_function = type(action) == 'function'
      local desc = is_function and 'vv-explorer: <fn>' or ('vv-explorer: ' .. action)

      vim.keymap.set('n', lhs, function()
        if is_function then return action(state) end
        if action == '__close' then return opts.close() end
        if action == '__quit' then
          if state.filter and state.filter.active then
            return opts.actions.clear_filter(state)
          end
          return opts.close()
        end

        local callback = opts.actions[action]
        if callback then callback(state) end
      end, {
        buffer = state.buf,
        nowait = true,
        silent = true,
        desc = desc,
      })
    end
  end

  vim.keymap.set('n', 'v', '<Nop>', { buffer = state.buf, silent = true })
  vim.keymap.set('n', 'V', '<Nop>', { buffer = state.buf, silent = true })

  local blocked_mouse_keys = {
    '<LeftDrag>',
    '<2-LeftMouse>',
    '<3-LeftMouse>',
    '<4-LeftMouse>',
    '<RightRelease>',
    '<2-RightMouse>',
    '<3-RightMouse>',
    '<4-RightMouse>',
  }
  for _, key in ipairs(blocked_mouse_keys) do
    vim.keymap.set({ 'n', 'x' }, key, '<Nop>', { buffer = state.buf, silent = true })
  end
  vim.keymap.set('x', '<RightMouse>', '<Esc>', { buffer = state.buf, silent = true })

  require('vv-utils.mouse').block_visual_drag(state.buf)
end

---@param state table
---@param actions table
function M.attach_cursor_snap(state, actions)
  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = state.buf,
    callback = function()
      if not state.name_cols or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
      local cursor = vim.api.nvim_win_get_cursor(state.win)
      local target_col = state.name_cols[cursor[1]]
      if target_col and cursor[2] ~= target_col then
        vim.api.nvim_win_set_cursor(state.win, { cursor[1], target_col })
      end
      if state._chain_sel and state._chain_sel.lnum ~= cursor[1] then
        actions.chain_sel_clear(state)
      end
    end,
  })
end

return M

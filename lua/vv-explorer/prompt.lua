-- 底部浮动输入框 + 实时过滤（debounced）
-- TextChangedI 驱动 on_change；<CR> submit；<Esc> cancel

local QUERY_DEBOUNCE_MS = 30

local M = {}

---@param state table
---@param initial string
---@param on_change fun(query:string)
---@param on_submit fun(query:string)
---@param on_cancel fun()
function M.open(state, initial, on_change, on_submit, on_cancel)
  initial = initial or ''
  local tree_win = state.win
  if not vim.api.nvim_win_is_valid(tree_win) then return end

  local tree_pos = vim.api.nvim_win_get_position(tree_win)
  local tree_width = vim.api.nvim_win_get_width(tree_win)
  local tree_height = vim.api.nvim_win_get_height(tree_win)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { initial })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = tree_pos[1] + tree_height - 1,
    col = tree_pos[2],
    width = tree_width,
    height = 1,
    style = 'minimal',
    border = 'none',
    focusable = true,
    zindex = 50,
  })

  vim.wo[win].winhighlight = 'Normal:NormalFloat'
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].number = false
  vim.wo[win].cursorline = false

  -- 前缀 "/" 用 inline virt text 显示（不占 buffer 内容）
  local ns = vim.api.nvim_create_namespace('vv-explorer-prompt')
  local match_ns = vim.api.nvim_create_namespace('vv-explorer-prompt-match')
  local function draw_prefix()
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      virt_text = { { '/ ', 'Question' } },
      virt_text_pos = 'inline',
    })
  end
  local function draw_match_count()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_clear_namespace(buf, match_ns, 0, -1)
    local text
    local f = state.filter
    if f and f.index_building then
      text = ' indexing… '
    elseif f and f.match_count ~= nil and f.query ~= '' then
      text = string.format(' %d match%s ', f.match_count, f.match_count == 1 and '' or 'es')
    end
    if text then
      vim.api.nvim_buf_set_extmark(buf, match_ns, 0, 0, {
        virt_text = { { text, 'Comment' } },
        virt_text_pos = 'right_align',
      })
    end
  end
  draw_prefix()
  draw_match_count()

  -- 给 actions.refilter 一个回调，让它在每次过滤后回调刷新
  state.filter.on_match_count_update = draw_match_count

  -- 光标移到行尾
  vim.api.nvim_win_set_cursor(win, { 1, #initial })
  vim.cmd.startinsert({ bang = true })

  local function get_query()
    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''
    return line
  end

  local closed = false
  local function close()
    if closed then return end
    closed = true
    if state.filter then state.filter.on_match_count_update = nil end
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  local uv = vim.uv or vim.loop
  local timer = uv.new_timer()

  local aug = vim.api.nvim_create_augroup('vv-explorer-prompt.' .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    group = aug,
    buffer = buf,
    callback = function()
      draw_prefix() -- 编辑行内容变化时 virt_text 会被清，重画
      timer:stop()
      timer:start(QUERY_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
        if closed or not vim.api.nvim_buf_is_valid(buf) then return end
        on_change(get_query())
      end))
    end,
  })

  -- stopinsert 必须先于 close：否则关闭 prompt 窗后 Insert 模式残留，
  -- 焦点回到 tree 窗口时光标仍在 Insert，用户按键会写到落脚的 buffer
  vim.keymap.set({ 'i', 'n' }, '<Esc>', function()
    timer:stop(); pcall(timer.close, timer)
    vim.cmd.stopinsert()
    close()
    on_cancel()
  end, { buffer = buf, nowait = true })

  vim.keymap.set({ 'i', 'n' }, '<CR>', function()
    local q = get_query()
    timer:stop(); pcall(timer.close, timer)
    vim.cmd.stopinsert()
    close()
    on_submit(q)
  end, { buffer = buf, nowait = true })

  -- 统一哲学：任何 q（Normal 模式）都能退出
  vim.keymap.set('n', 'q', function()
    timer:stop(); pcall(timer.close, timer)
    vim.cmd.stopinsert()
    close()
    on_cancel()
  end, { buffer = buf, nowait = true })

  -- 失焦自动取消（点击了别的窗口）
  vim.api.nvim_create_autocmd({ 'BufLeave', 'WinLeave' }, {
    group = aug,
    buffer = buf,
    once = true,
    callback = function()
      timer:stop(); pcall(timer.close, timer)
      if not closed then
        close()
        on_cancel()
      end
    end,
  })
end

return M

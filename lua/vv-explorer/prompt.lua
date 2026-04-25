-- 底部浮动输入框（双行）+ 实时过滤（debounced）
--
-- 两行布局（buffer 实际有 2 行，避开 floating window 里 virt_lines_above 不稳定的坑）：
--   line 0 = 空字符串，用 extmark overlay 画 label：mode badge + <S-Tab> 提示 + 状态
--   line 1 = 用户输入；空时 overlay 显示 placeholder（第一字符即覆盖）
--
-- 光标锁在 line 1：CursorMoved/CursorMovedI 无差别兜底拉回（覆盖键盘 / 鼠标 / <C-o>gg
-- 等所有离开方式，比 keymap nop 黑名单更稳）。
-- input 行干净：没有 inline 前缀占位，输入再长都不会被装饰挤掉。
--
-- 增强键位（i / n 模式都生效）：
--   <S-Tab>        循环切换搜索模式（fuzzy → glob → regex）
--   <C-n> / <C-p>  在 tree 窗口里跳到下/上一个 match（焦点不离开 prompt）
--   <C-x> / <C-v>  以 split / vsplit 直接打开当前 match

local Filter = require('vv-explorer.filter')

local QUERY_DEBOUNCE_MS = 30
local PROMPT_HEIGHT = 2
local LABEL_ROW = 0 -- 0-indexed
local INPUT_ROW = 1
local INPUT_LNUM = INPUT_ROW + 1 -- nvim_win_set_cursor 是 1-indexed

local M = {}

---@class VVExplorerPromptOpts
---@field initial? string
---@field on_change fun(query:string)
---@field on_submit fun(query:string)
---@field on_cancel fun()
---@field on_cycle_mode? fun():string
---@field on_navigate? fun(dir:integer)
---@field on_open_in? fun(kind:'split'|'vsplit')
---@field get_mode? fun():string

-- 创建浮窗 buffer + window，贴在 tree 窗口底部 PROMPT_HEIGHT 行
---@param state table
---@param initial string
---@return integer? buf, integer? win   tree_win 失效时返回 nil
local function setup_floating_window(state, initial)
  local tree_win = state.win
  if not vim.api.nvim_win_is_valid(tree_win) then return nil, nil end

  local tree_pos = vim.api.nvim_win_get_position(tree_win)
  local tree_width = vim.api.nvim_win_get_width(tree_win)
  local tree_height = vim.api.nvim_win_get_height(tree_win)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  -- 两行 buffer：line 0 占位给 label overlay；line 1 是用户输入
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '', initial })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = tree_pos[1] + tree_height - PROMPT_HEIGHT,
    col = tree_pos[2],
    width = tree_width,
    height = PROMPT_HEIGHT,
    style = 'minimal',
    border = 'none',
    focusable = true,
    zindex = 50,
  })

  vim.wo[win].winhighlight = 'Normal:NormalFloat'
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].number = false
  vim.wo[win].cursorline = false
  return buf, win
end

-- 装饰：label（mode badge + <S-Tab> 提示 + 状态）overlay 在 line 0；placeholder overlay 在 line 1
-- 返回 redraw() 函数，调用方在 mode 切换 / 状态变化时调它
---@param buf integer
---@param state table
---@param opts VVExplorerPromptOpts
---@return fun() redraw
local function setup_decorations(buf, state, opts)
  local label_ns = vim.api.nvim_create_namespace('vv-explorer-prompt-label')
  local ph_ns = vim.api.nvim_create_namespace('vv-explorer-prompt-ph')

  local function current_mode()
    return (opts.get_mode and opts.get_mode()) or 'fuzzy'
  end

  -- line 0 永远空字符串，用 overlay 画 mode badge + 快捷键提示 + 状态文案
  local function draw_label()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_clear_namespace(buf, label_ns, 0, -1)

    local md = Filter.display(current_mode())
    local segs = {
      { ' ',                           'Comment' },
      { md.icon .. ' ' .. md.label,    md.hl },
      { '  ',                          'Comment' },
      { '<S-Tab>',                     'Special' },
      { ' switch',                     'Comment' },
    }

    local f = state.filter
    local status
    if f and f.index_building then
      status = 'indexing…'
    elseif f and f.match_count ~= nil and (f.query or '') ~= '' then
      status = string.format('%d match%s', f.match_count, f.match_count == 1 and '' or 'es')
    end
    if status then
      segs[#segs + 1] = { ' · ',  'Comment' }
      segs[#segs + 1] = { status, 'Comment' }
    end

    vim.api.nvim_buf_set_extmark(buf, label_ns, LABEL_ROW, 0, {
      virt_text = segs,
      virt_text_pos = 'overlay',
      right_gravity = false,
    })
  end

  -- placeholder：input 行为空时 overlay；第一字符即被覆盖
  local function draw_placeholder()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_clear_namespace(buf, ph_ns, 0, -1)
    local line = vim.api.nvim_buf_get_lines(buf, INPUT_ROW, INPUT_ROW + 1, false)[1] or ''
    if #line == 0 then
      vim.api.nvim_buf_set_extmark(buf, ph_ns, INPUT_ROW, 0, {
        virt_text = { { 'type to filter…', 'Comment' } },
        virt_text_pos = 'overlay',
        right_gravity = false,
      })
    end
  end

  return function()
    draw_label()
    draw_placeholder()
  end
end

-- 绑定 prompt 内的所有 keymap：取消 / 提交 / 模式切换 / match 导航 / 分屏打开
---@param buf integer
---@param opts VVExplorerPromptOpts
---@param ctx { close:fun(), redraw:fun(), get_query:fun():string }
local function setup_keymaps(buf, opts, ctx)
  local map = function(lhs, fn)
    vim.keymap.set({ 'i', 'n' }, lhs, fn, { buffer = buf, nowait = true, silent = true })
  end

  -- 光标锁定 100% 走 CursorMoved/CursorMovedI（在 setup_autocmds 里），不再列 keymap 黑名单——
  -- 黑名单覆盖不全（<C-o>gg / 鼠标点击 / 折叠跳转 等），autocmd 是唯一稳妥兜底

  -- stopinsert 必须先于 close：否则 prompt 关后 Insert 模式残留，焦点回 tree 时按键写到落脚 buffer
  map('<Esc>', function()
    vim.cmd.stopinsert()
    ctx.close()
    opts.on_cancel()
  end)

  map('<CR>', function()
    local q = ctx.get_query()
    vim.cmd.stopinsert()
    ctx.close()
    opts.on_submit(q)
  end)

  vim.keymap.set('n', 'q', function()
    vim.cmd.stopinsert()
    ctx.close()
    opts.on_cancel()
  end, { buffer = buf, nowait = true, silent = true })

  if opts.on_cycle_mode then
    map('<S-Tab>', function()
      opts.on_cycle_mode()
      ctx.redraw()
    end)
  end

  if opts.on_navigate then
    map('<C-n>', function() opts.on_navigate(1) end)
    map('<C-p>', function() opts.on_navigate(-1) end)
  end

  if opts.on_open_in then
    local function open_then_close(kind)
      return function()
        vim.cmd.stopinsert()
        ctx.close()
        opts.on_open_in(kind)
      end
    end
    map('<C-x>', open_then_close('split'))
    map('<C-v>', open_then_close('vsplit'))
  end
end

---@param state table
---@param opts VVExplorerPromptOpts
function M.open(state, opts)
  local initial = opts.initial or ''
  local buf, win = setup_floating_window(state, initial)
  if not buf or not win then return end

  local redraw = setup_decorations(buf, state, opts)
  redraw()
  -- 让 actions.refilter 在每次过滤后回调，刷新 mode badge / status / placeholder
  state.filter.on_redraw = redraw

  -- 光标落在 input 行行尾
  vim.api.nvim_win_set_cursor(win, { INPUT_LNUM, #initial })
  vim.cmd.startinsert({ bang = true })

  local function get_query()
    local line = vim.api.nvim_buf_get_lines(buf, INPUT_ROW, INPUT_ROW + 1, false)[1] or ''
    return line
  end

  local closed = false
  local uv = vim.uv or vim.loop
  local timer = uv.new_timer()

  local function close()
    if closed then return end
    closed = true
    if state.filter then state.filter.on_redraw = nil end
    timer:stop(); pcall(timer.close, timer)
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  local aug = vim.api.nvim_create_augroup('vv-explorer-prompt.' .. buf, { clear = true })

  -- 兜底：用户用任何方式（鼠标、误按方向键）跑到 line 0 就拉回 line 1
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = aug,
    buffer = buf,
    callback = function()
      if closed or not vim.api.nvim_win_is_valid(win) then return end
      local pos = vim.api.nvim_win_get_cursor(win)
      if pos[1] ~= INPUT_LNUM then
        pcall(vim.api.nvim_win_set_cursor, win, { INPUT_LNUM, pos[2] })
      end
    end,
  })

  -- 编辑后重画：label 上的 status 段 / placeholder 都依赖当前 input 内容
  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    group = aug,
    buffer = buf,
    callback = function()
      redraw()
      timer:stop()
      timer:start(QUERY_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
        if closed or not vim.api.nvim_buf_is_valid(buf) then return end
        opts.on_change(get_query())
      end))
    end,
  })

  setup_keymaps(buf, opts, { close = close, redraw = redraw, get_query = get_query })

  -- 失焦自动取消（点击了别的窗口）
  vim.api.nvim_create_autocmd({ 'BufLeave', 'WinLeave' }, {
    group = aug,
    buffer = buf,
    once = true,
    callback = function()
      if not closed then
        close()
        opts.on_cancel()
      end
    end,
  })
end

return M

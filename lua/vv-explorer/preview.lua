-- VSCode 风「单击预览」buffer 行为
--   ① 树里光标移到文件 A → 主窗口自动打开 A 作为「动态预览」
--   ② 光标继续移到文件 B → 删 A、打开 B（同一时刻最多一个动态预览）
--   ③ 用户按 <CR>/l 打开文本文件 → 当前预览升级为「固定」（清空追踪）
--   ④ 用户在动态 buffer 里编辑 → 自动升级为固定（不能删用户改了的东西）
--
-- 边界（已处理）：
--   • 当前节点不是 file → 不预览
--   • 主窗口已显示该文件 → 跳过 :edit
--   • 没有可用主窗口（浮窗模式或只有树） → 跳过
--   • 旧预览被另一窗口共用 → 不删
--   • 旧预览处于 modified → 不删

local FilePolicy = require('vv-explorer.file_policy')
local Window = require('vv-explorer.window')
local Fs = require('vv-utils.fs')

local M = {}

local IMAGE_EXTS = { png = true, jpg = true, jpeg = true, gif = true, webp = true, avif = true }

---@param path string
local function is_image(path)
  local ext = path:match('%.(%w+)$')
  return ext and IMAGE_EXTS[ext:lower()] or false
end

-- state -> bufnr (weak key，state gc 后自动清理)
M._preview = setmetatable({}, { __mode = 'k' })

-- state -> winid。preview buffer 可能已经因其他 split 而 listed，此时需要
-- 让 vv-bufferline 按窗口跳过追踪，不能再靠全局 buflisted 表达 preview/fixed
M._preview_win = setmetatable({}, { __mode = 'k' })

-- state -> cancel fn（debounce timer 清理，state gc 后自动释放引用）
M._cancel = setmetatable({}, { __mode = 'k' })

-- tabpage -> winid。用于让 explorer 打开文件时优先进入最近聚焦过的编辑 split
M._last_editor_win = {}

-- 预览追踪是「buf + 所属窗口」一对，置空必须成对，避免只清一半留下野引用
---@param state table
local function reset_preview_state(state)
  M._preview[state] = nil
  M._preview_win[state] = nil
end

---@param win integer
---@return boolean
local function is_editor_win(win)
  if not vim.api.nvim_win_is_valid(win) then return false end
  if vim.api.nvim_win_get_config(win).relative ~= '' then return false end
  if vim.wo[win].winfixbuf then return false end

  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= '' then return false end
  if vim.bo[buf].filetype == Window.FILETYPE then return false end
  if vim.api.nvim_buf_get_name(buf) == '' then return false end

  return true
end

---@param buf integer
---@return boolean
local function is_empty_normal_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  if vim.bo[buf].buftype ~= '' then return false end
  if vim.bo[buf].modified then return false end
  if vim.api.nvim_buf_get_name(buf) ~= '' then return false end

  return vim.api.nvim_buf_line_count(buf) == 1
    and (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or '') == ''
end

---@param win integer
---@return boolean
local function is_replaceable_main_win(win)
  if not vim.api.nvim_win_is_valid(win) then return false end
  if vim.api.nvim_win_get_config(win).relative ~= '' then return false end
  if vim.wo[win].winfixbuf then return false end

  local buf = vim.api.nvim_win_get_buf(win)
  local ft = vim.bo[buf].filetype

  return ft == 'dashboard' or ft == 'alpha' or ft == 'ministarter' or is_empty_normal_buf(buf)
end

---@param win integer
---@return integer prev_buf
function M.prepare_main_win(win)
  local prev_buf = vim.api.nvim_win_get_buf(win)
  if not is_replaceable_main_win(win) then return prev_buf end

  local replacement = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(win, replacement)

  if vim.api.nvim_buf_is_valid(prev_buf) and #vim.fn.win_findbuf(prev_buf) == 0 then
    pcall(vim.api.nvim_buf_delete, prev_buf, { force = true })
  end

  return prev_buf
end

---@param win integer?
function M.remember_editor_win(win)
  win = win or vim.api.nvim_get_current_win()
  if not is_editor_win(win) then return end

  local tab = vim.api.nvim_win_get_tabpage(win)
  M._last_editor_win[tab] = win
end

function M.setup_editor_history()
  local group = vim.api.nvim_create_augroup('vv-explorer.editor-history', { clear = true })

  vim.api.nvim_create_autocmd({ 'WinEnter', 'BufEnter' }, {
    group = group,
    callback = function() M.remember_editor_win() end,
  })

  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(args)
      local closed = tonumber(args.match)
      if not closed then return end

      for tab, win in pairs(M._last_editor_win) do
        if win == closed then M._last_editor_win[tab] = nil end
      end
    end,
  })
end

-- 必须限定在树所在 tabpage 内搜索。nvim_list_wins() 是跨所有 tab 的，
-- 用户如果在 tab 1 开了 vv-explorer、在 tab 2 开别的窗口，预览会错把 tab 2
-- 的窗口当成 "main"，nvim_win_set_buf 会把预览内容推到不相关的 tab 里
---@param tree_win integer
---@param state? table
---@return integer? main_win
function M.find_main_win(tree_win, state)
  if not vim.api.nvim_win_is_valid(tree_win) then return nil end
  local tab = vim.api.nvim_win_get_tabpage(tree_win)

  -- binary info 使用 nofile scratch，不能通过 is_editor_win；只复用当前 state 已追踪的
  -- preview window，避免把其它特殊窗口误判为编辑区
  local preview_win = state and M._preview_win[state]
  local preview_buf = state and M._preview[state]
  if preview_win
      and preview_buf
      and preview_win ~= tree_win
      and vim.api.nvim_win_is_valid(preview_win)
      and vim.api.nvim_buf_is_valid(preview_buf)
      and vim.api.nvim_win_get_buf(preview_win) == preview_buf
      and vim.api.nvim_win_get_tabpage(preview_win) == tab
      and vim.api.nvim_win_get_config(preview_win).relative == ''
      and not vim.wo[preview_win].winfixbuf then
    return preview_win
  end

  local last = M._last_editor_win[tab]
  if last
     and last ~= tree_win
     and vim.api.nvim_win_is_valid(last)
     and vim.api.nvim_win_get_tabpage(last) == tab
     and is_editor_win(last)
  then
    return last
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if win ~= tree_win then
      if is_editor_win(win) then
        return win
      end
    end
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if win ~= tree_win and is_replaceable_main_win(win) then
      return win
    end
  end
end

-- 同样限定在树的 tabpage 内（跨 tab 的同 buf 显示不影响本 tab 的 preview 清理决策）
---@param buf integer
---@param tree_win integer
---@return boolean
local function is_visible_elsewhere(buf, tree_win)
  if not vim.api.nvim_win_is_valid(tree_win) then return false end
  local tab = vim.api.nvim_win_get_tabpage(tree_win)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if w ~= tree_win and vim.api.nvim_win_get_buf(w) == buf then
      return true
    end
  end
  return false
end

local function bufferline()
  local ok, mod = pcall(require, 'vv-bufferline')
  if ok and type(mod) == 'table' then return mod end
end

---@param win integer
---@param buf integer
---@return boolean
local function is_fixed_for_win(win, buf)
  local bl = bufferline()
  if bl and type(bl.has) == 'function' then
    return bl.has(win, buf)
  end

  return vim.bo[buf].buflisted
end

---@param win integer?
---@param buf integer?
---@param promote? boolean
local function clear_bufferline_preview(win, buf, promote)
  if not win or not buf then return end

  local bl = bufferline()
  if bl and type(bl.clear_preview) == 'function' then
    bl.clear_preview(win, buf, { promote = promote })
  end
end

---@param win integer
---@param buf integer
local function mark_bufferline_preview(win, buf)
  local bl = bufferline()
  if bl and type(bl.mark_preview) == 'function' then
    bl.mark_preview(win, buf)
  end
end

---@param info VVFsFileInfo
---@param display_path string
---@param abs string
---@return integer
local function create_binary_preview(info, display_path, abs)
  local buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = buf })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, Fs.file_info_lines(info, {
    display_path = display_path,
  }))

  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  vim.api.nvim_set_option_value('readonly', true, { buf = buf })
  vim.api.nvim_set_option_value('filetype', 'vv-explorer-info', { buf = buf })

  Fs.highlight_file_info(buf)

  vim.b[buf].vv_explorer_binary_info = true
  vim.b[buf].vv_explorer_binary_path = abs

  return buf
end

---@param state table
---@param path string
function M.preview_file(state, path)
  if vim.fn.filereadable(path) == 0 then return end
  local abs = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  local info = FilePolicy.binary_info(abs, state.opts.binary)
  local main = M.find_main_win(state.win, state)
  if not main then return end
  if not vim.api.nvim_win_is_valid(main) then return end

  local cur_buf = vim.api.nvim_win_get_buf(main)
  local cur_buf_name = vim.fs.normalize(vim.api.nvim_buf_get_name(cur_buf))
  local cur_binary_path = vim.b[cur_buf].vv_explorer_binary_path
  if info and cur_binary_path == abs then return end
  if not info and cur_buf_name == abs then return end

  local old = M._preview[state]
  local old_win = M._preview_win[state]

  local target
  local is_fixed = false
  local was_listed = false
  if info then
    target = create_binary_preview(info, path, abs)
  else
    -- 用 bufadd + bufload，保留焦点在树窗口；窗口换 buf 不动焦点
    target = vim.fn.bufadd(path)
    if target == 0 then return end
    -- 固定与否是 window-local 语义：同一个 buf 可能在下方 split 是固定的，
    -- 但在上方 split 已被 <leader>bd 从分组移除，此时 explorer preview 不应重新加入
    is_fixed = is_fixed_for_win(main, target)
    was_listed = vim.bo[target].buflisted
  end

  if old and (old ~= target or is_fixed) then
    clear_bufferline_preview(old_win, old, false)
  end

  if not is_fixed and not was_listed then
    vim.bo[target].buflisted = false
  end
  if not vim.api.nvim_buf_is_loaded(target) then
    vim.fn.bufload(target)
  end

  if not is_fixed then
    mark_bufferline_preview(main, target)
  end

  local ok = pcall(vim.api.nvim_win_set_buf, main, target)
  if not ok then
    clear_bufferline_preview(main, target, false)
    if info and vim.api.nvim_buf_is_valid(target) then
      pcall(vim.api.nvim_buf_delete, target, { force = true })
    end
    return
  end

  -- 固定 buf 不追踪（不会被预览系统删除），但仍清理旧预览引用
  M._preview[state] = is_fixed and nil or target
  M._preview_win[state] = is_fixed and nil or main

  -- nvim_win_set_buf 会触发 BufWinEnter 但不触发 BufEnter；
  -- 仅对图片文件补发 BufLeave/BufWinEnter 以确保 image.nvim 正常工作，
  -- 普通文件不补发，避免触发 LSP attach / auto-save 等重操作
  if is_image(abs) or is_image(cur_buf_name) then
    pcall(vim.api.nvim_win_call, main, function()
      if vim.api.nvim_buf_is_valid(cur_buf) then
        vim.api.nvim_exec_autocmds('BufLeave', { buffer = cur_buf })
      end
      if vim.api.nvim_buf_is_valid(target) then
        vim.api.nvim_exec_autocmds('BufWinEnter', { buffer = target })
      end
    end)
  end

  -- filetype 检测必须在 buffer 进入窗口之后：
  -- render-markdown 等插件在 FileType 时调 buf.win(buf) 取窗口句柄，
  -- 若 buffer 还没有归属窗口则初始渲染会被跳过
  if vim.bo[target].filetype == '' then
    local ft = vim.filetype.match({ buf = target, filename = path })
    if ft then vim.bo[target].filetype = ft end
  end

  -- 被 displace 的 cur_buf 若是空 [No Name]（startup buffer / `:enew` 残留）→ wipe
  -- 不影响有内容/有名/被修改的 buffer；dashboard 等 bufhidden=wipe 的 buf 走自己的清理
  require('vv-utils.bufdelete').wipe_if_throwaway(cur_buf)

  -- 双重保险：即使 bufferline 在 nvim_win_set_buf 期间把 old 重新 list 了，也不删
  if old and old ~= target
     and vim.api.nvim_buf_is_valid(old)
     and not vim.bo[old].modified
     and not vim.bo[old].buflisted
     and not is_visible_elsewhere(old, state.win) then
    pcall(vim.api.nvim_buf_delete, old, { force = false })
  end
end

-- 丢弃一个预览 buffer：清掉 bufferline 预览态（不升级、不复原），并在它确属一次性
-- 预览（未改、未 list、别处不可见）时清理掉，避免遗留隐藏 buffer
---@param state table
---@param buf integer?
---@param win integer?
local function drop_preview_buf(state, buf, win)
  clear_bufferline_preview(win, buf, false)
  if buf and vim.api.nvim_buf_is_valid(buf)
     and not vim.bo[buf].modified
     and not vim.bo[buf].buflisted
     and not is_visible_elsewhere(buf, state.win) then
    pcall(vim.api.nvim_buf_delete, buf, { force = false })
  end
end

-- 丢弃当前预览：不升级、不复原。用于「没有主窗 / 在别处（分屏）打开」的场景
---@param state table
function M.discard(state)
  drop_preview_buf(state, M._preview[state], M._preview_win[state])
  reset_preview_state(state)
end

-- 结算一次「在 win 里显式打开文件」：win 当前显示的 buffer 即提交目标
-- 必须在 win 已经切到目标文件「之后」调用——这样：
--   ① 指向其他文件的陈旧预览被丢弃且不会被 render 复原（win 已不显示它）；
--   ② 已从分组删除（removed）的 buffer 不会因「顺手 promote 上一个预览」而复活
---@param state table
---@param win integer
function M.commit(state, win)
  if not vim.api.nvim_win_is_valid(win) then
    return M.discard(state)
  end

  local committed = vim.api.nvim_win_get_buf(win)
  local pv = M._preview[state]

  -- 陈旧预览（指向另一个 buffer）→ 丢弃，绝不升级
  if pv and pv ~= committed then
    drop_preview_buf(state, pv, M._preview_win[state])
  end

  -- 提交目标：纳入所在窗口的 bufferline 分组（promote=true 会清掉 removed 标记）
  if vim.api.nvim_buf_is_valid(committed) then
    vim.bo[committed].buflisted = true
    clear_bufferline_preview(win, committed, true)
  end

  reset_preview_state(state)
end

-- path_set 的 key 由 crud.cleanup_deleted_bufs 用 Fs.realpath 解析为真实路径并去尾斜杠；
-- 这里把预览 buffer name 同样 normalize + 去尾斜杠后比对，口径一致才不会漏命中
---@param state table
---@param path_set table<string, boolean>
function M.clear_if_deleted(state, path_set)
  local buf = M._preview[state]
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local raw = vim.b[buf].vv_explorer_binary_path or vim.api.nvim_buf_get_name(buf)
  if raw == '' then return end
  local name = Fs.realpath(raw):gsub('/+$', '')
  if path_set[name] then
    clear_bufferline_preview(M._preview_win[state], buf, false)
    reset_preview_state(state)
  end
end

---@param state table
function M.attach(state)
  local aug = vim.api.nvim_create_augroup('vv-explorer.preview.' .. state.buf, { clear = true })

  local function do_preview()
    if state._skip_preview then return end
    if vim.api.nvim_get_current_win() ~= state.win then return end
    local node = require('vv-explorer.actions').node_under_cursor(state)
    if not node or node.is_dir then return end
    M.preview_file(state, node.path)
  end

  local debounce_ms = state.opts and state.opts.preview_debounce_ms or 0
  local callback
  if debounce_ms > 0 then
    local cancel
    callback, cancel = require('vv-utils.timer').debounce(do_preview, debounce_ms)
    M._cancel[state] = cancel
  else
    callback = do_preview
  end

  vim.api.nvim_create_autocmd('CursorMoved', {
    group = aug,
    buffer = state.buf,
    callback = callback,
  })

  -- BufModifiedSet 在 0.13 中被移除，原因是它只在 redraw 时对当前 buffer 触发，
  -- 导致 :wa 写入非当前 buffer 时事件延迟/丢失。0.13 改用 OptionSet modified，
  -- 触发更及时且对所有 buffer 一致
  -- 见 https://github.com/neovim/neovim/pull/35610 (merged 2026-04-27, milestone 0.13)
  if vim.fn.exists('##BufModifiedSet') == 1 then
    vim.api.nvim_create_autocmd('BufModifiedSet', {
      group = aug,
      callback = function(args)
        if M._preview[state] == args.buf then
          local ok, modified = pcall(function() return vim.bo[args.buf].modified end)
          if ok and modified then
            vim.bo[args.buf].buflisted = true
            clear_bufferline_preview(M._preview_win[state], args.buf, true)
            reset_preview_state(state)
          end
        end
      end,
    })
  else
    vim.api.nvim_create_autocmd('OptionSet', {
      group = aug,
      pattern = 'modified',
      callback = function(args)
        -- OptionSet 的 args.buf 对 buffer-local 选项（如 modified）指向实际被改变的 buffer，
        -- 相当于 Vimscript 的 expand('<abuf>')，比 nvim_get_current_buf() 更准确
        local buf = (args.buf and args.buf > 0) and args.buf or vim.api.nvim_get_current_buf()
        if M._preview[state] == buf and vim.bo[buf].modified then
          vim.bo[buf].buflisted = true
          clear_bufferline_preview(M._preview_win[state], buf, true)
          reset_preview_state(state)
        end
      end,
    })
  end
end

---@param state table
function M.detach(state)
  pcall(vim.api.nvim_del_augroup_by_name, 'vv-explorer.preview.' .. state.buf)
  clear_bufferline_preview(M._preview_win[state], M._preview[state], false)
  reset_preview_state(state)
  if M._cancel[state] then
    pcall(M._cancel[state])
    M._cancel[state] = nil
  end
end

return M

-- VSCode 风「单击预览」buffer 行为
--   ① 树里光标移到文件 A → 主窗口自动打开 A 作为「动态预览」
--   ② 光标继续移到文件 B → 删 A、打开 B（同一时刻最多一个动态预览）
--   ③ 用户按 <CR>/l 打开文本文件 → 当前预览升级为「固定」（清空追踪）
--   ④ 用户在动态 buffer 里编辑 → 自动升级为固定（不能删用户改了的东西）
--   ⑤ 光标移到目录 → 主窗显示目录属性（见 dir.lua）
--
-- 边界（已处理）：
--   • 主窗口已显示该文件 → 跳过 :edit
--   • 没有可用主窗口（浮窗模式或只有树） → 跳过
--   • 旧预览被另一窗口共用 → 不删
--   • 旧预览处于 modified → 不删
--
-- 模块划分：
--   main_win  哪个窗口是编辑区（与预览无关，actions / init 也直接用）
--   mount     预览追踪、挂载与旧 buffer 清理，含 vv-bufferline 适配
--   info_buf  属性视图的 scratch buffer
--   dir       目录统计的编排与缓存
-- 本文件是公共 facade：文件预览、提交/丢弃结算与面板生命周期

local Dir = require('vv-explorer.preview.dir')
local FilePolicy = require('vv-explorer.file_policy')
local Fs = require('vv-utils.fs')
local InfoBuf = require('vv-explorer.preview.info_buf')
local MainWin = require('vv-explorer.preview.main_win')
local Mount = require('vv-explorer.preview.mount')

local M = {}

local IMAGE_EXTS = { png = true, jpg = true, jpeg = true, gif = true, webp = true, avif = true }

---@param path string
local function is_image(path)
  local ext = path:match('%.(%w+)$')
  return ext and IMAGE_EXTS[ext:lower()] or false
end

-- state -> cancel fn（debounce timer 清理，state gc 后自动释放引用）
M._cancel = setmetatable({}, { __mode = 'k' })

-- 子模块持有的状态与能力经 facade 转发，调用方不必知道内部划分。
-- 转发的是同一个 table 引用，不是拷贝
M._preview = Mount.preview
M._preview_win = Mount.preview_win
M._last_editor_win = MainWin.last_editor_win
M._dir_scope = Dir.scope
M._dir_cache = Dir.cache

M.prepare_main_win = MainWin.prepare_main_win
M.remember_editor_win = MainWin.remember_editor_win
M.setup_editor_history = MainWin.setup_editor_history
M.find_main_win = MainWin.find_main_win

M.preview_dir = Dir.preview
M.scan_dir = Dir.scan
M.cancel_dir_scan = Dir.cancel_scan
M.invalidate_dir_cache = Dir.invalidate_cache

---@param state table
---@param path string
function M.preview_file(state, path)
  if vim.fn.filereadable(path) == 0 then return end
  Dir.cancel_scan(state)

  local abs = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  local info = FilePolicy.binary_info(abs, state.opts.binary)
  local main = MainWin.find_main_win(state.win, state)
  if not main then return end
  if not vim.api.nvim_win_is_valid(main) then return end

  local cur_buf = vim.api.nvim_win_get_buf(main)
  local cur_buf_name = vim.fs.normalize(vim.api.nvim_buf_get_name(cur_buf))
  local cur_binary_path = vim.b[cur_buf].vv_explorer_binary_path
  if info and cur_binary_path == abs then return end
  if not info and cur_buf_name == abs then return end

  local target
  local is_fixed = false
  local was_listed = false
  if info then
    target = InfoBuf.create_binary(info, path, abs)
  else
    -- 用 bufadd + bufload，保留焦点在树窗口；窗口换 buf 不动焦点
    target = vim.fn.bufadd(path)
    if target == 0 then return end
    -- 固定与否是 window-local 语义：同一个 buf 可能在下方 split 是固定的，
    -- 但在上方 split 已被 <leader>bd 从分组移除，此时 explorer preview 不应重新加入
    is_fixed = Mount.is_fixed_for_win(main, target)
    was_listed = vim.bo[target].buflisted
  end

  Mount.mount(state, main, target, {
    cur_buf = cur_buf,
    is_fixed = is_fixed,
    was_listed = was_listed,
    scratch = info ~= nil,
    after_mount = function()
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
    end,
  })
end

-- 丢弃当前预览：不升级、不复原。用于「没有主窗 / 在别处（分屏）打开」的场景
---@param state table
function M.discard(state)
  Dir.cancel_scan(state)
  Mount.drop(state, Mount.preview[state], Mount.preview_win[state])
  Mount.reset(state)
end

-- 结算一次「在 win 里显式打开文件」：win 当前显示的 buffer 即提交目标
-- 必须在 win 已经切到目标文件「之后」调用——这样：
--   ① 指向其他文件的陈旧预览被丢弃且不会被 render 复原（win 已不显示它）；
--   ② 已从分组删除（removed）的 buffer 不会因「顺手 promote 上一个预览」而复活
---@param state table
---@param win integer
function M.commit(state, win)
  Dir.cancel_scan(state)

  if not vim.api.nvim_win_is_valid(win) then
    return M.discard(state)
  end

  local committed = vim.api.nvim_win_get_buf(win)
  local pv = Mount.preview[state]

  -- 陈旧预览（指向另一个 buffer）→ 丢弃，绝不升级
  if pv and pv ~= committed then
    Mount.drop(state, pv, Mount.preview_win[state])
  end

  -- 提交目标：纳入所在窗口的 bufferline 分组（promote=true 会清掉 removed 标记）
  if vim.api.nvim_buf_is_valid(committed) then
    vim.bo[committed].buflisted = true
    Mount.clear_bufferline(win, committed, true)
  end

  Mount.reset(state)
end

-- path_set 的 key 由 crud.cleanup_deleted_bufs 用 Fs.realpath 解析为真实路径并去尾斜杠；
-- 这里把预览 buffer name 同样 normalize + 去尾斜杠后比对，口径一致才不会漏命中
---@param state table
---@param path_set table<string, boolean>
function M.clear_if_deleted(state, path_set)
  Dir.invalidate_cache(state)

  local buf = Mount.preview[state]
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local raw = vim.b[buf].vv_explorer_binary_path
    or vim.b[buf].vv_explorer_dir_path
    or vim.api.nvim_buf_get_name(buf)
  if raw == '' then return end
  local name = Fs.realpath(raw):gsub('/+$', '')
  if path_set[name] then
    Mount.clear_bufferline(Mount.preview_win[state], buf, false)
    Mount.reset(state)
  end
end

-- 用户在动态预览里编辑 → 升级为固定，不能再被预览系统删掉
---@param state table
---@param buf integer
local function promote_on_modify(state, buf)
  vim.bo[buf].buflisted = true
  Mount.clear_bufferline(Mount.preview_win[state], buf, true)
  Mount.reset(state)
end

---@param state table
function M.attach(state)
  local aug = vim.api.nvim_create_augroup('vv-explorer.preview.' .. state.buf, { clear = true })

  local function do_preview()
    if state._skip_preview then return end
    if vim.api.nvim_get_current_win() ~= state.win then return end
    local node = require('vv-explorer.actions').node_under_cursor(state)
    if not node then return end
    if node.is_dir then
      Dir.preview(state, node.path)
    else
      M.preview_file(state, node.path)
    end
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
        if Mount.preview[state] == args.buf then
          local ok, modified = pcall(function() return vim.bo[args.buf].modified end)
          if ok and modified then promote_on_modify(state, args.buf) end
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
        if Mount.preview[state] == buf and vim.bo[buf].modified then
          promote_on_modify(state, buf)
        end
      end,
    })
  end
end

---@param state table
function M.detach(state)
  pcall(vim.api.nvim_del_augroup_by_name, 'vv-explorer.preview.' .. state.buf)
  Mount.clear_bufferline(Mount.preview_win[state], Mount.preview[state], false)
  Mount.reset(state)
  if M._cancel[state] then
    pcall(M._cancel[state])
    M._cancel[state] = nil
  end

  Dir.detach(state)
end

return M

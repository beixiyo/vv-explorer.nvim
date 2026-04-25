-- 树内动作：open/close_node/toggle_hidden/refresh/yank_abs_path/cd_to/cd_up
-- CRUD：create/delete/rename/cut_mark/copy_mark/paste
-- 批量：toggle_select/clear_selection
-- 所有动作都接收 state 参数（由 init.lua 的 keymap wrapper 注入）

local Tree = require('vv-explorer.tree')
local Render = require('vv-explorer.render')
local Preview = require('vv-explorer.preview')
local Filter = require('vv-explorer.filter')
local Prompt = require('vv-explorer.prompt')
local Fs = require('vv-utils.fs')

local M = {}

-- 空 matched 形态：matched 的所有读路径（matched_lnums / render_filter / on_submit）
-- 都假设 abs/rels/positions 是 list；统一空表后无需额外 nil 守卫
local EMPTY_MATCHED = { abs = {}, rels = {}, positions = {} }

-- ============ 选区 / 剪贴板辅助 ============
-- state.selection: { [path] = true }，批量动作的作用集合
-- state.clipboard: { mode = 'cut'|'copy', paths = string[] }，paste 时消费

---@param state table
local function ensure_state_fields(state)
  state.selection = state.selection or {}
  state.clipboard = state.clipboard or nil
end

---@param state table
---@return string[]
local function selected_paths(state)
  local out = {}
  for p in pairs(state.selection or {}) do out[#out + 1] = p end
  table.sort(out)
  return out
end

-- 批量动作的目标：有选区就用选区，否则只作用于光标节点
---@param state table
---@param cursor_node table?
---@return string[] paths
local function targets(state, cursor_node)
  local sel = selected_paths(state)
  if #sel > 0 then return sel end
  if cursor_node and cursor_node ~= state.root then return { cursor_node.path } end
  return {}
end

-- 光标所在节点的目录上下文（文件则取其父）
---@param state table
---@param node table?
---@return string path
local function dir_context(state, node)
  if not node or node == state.root then return state.root.path end
  if node.is_dir then return node.path end
  return vim.fs.dirname(node.path)
end

---@param state table
local function after_fs_change(state)
  -- filter 索引 & 树结构全失效 → 重扫 + 清选区
  Tree.refresh(state.root)
  state.selection = {}
  if state.filter then state.filter.index = nil end
  if state.git and state.git.refresh then state.git.refresh() end
  Render.render(state)
end

---@param state table
---@param path string? 渲染后把光标落到指定路径（若可见）
local function focus_path(state, path)
  if not path or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local lnum = state.path_to_row and state.path_to_row[path]
  if lnum then
    pcall(vim.api.nvim_win_set_cursor, state.win, { lnum, 0 })
  end
end

-- 同步执行的 vim.ui.input 包装（走原生/dressing，取决于用户配置）
---@param opts {prompt:string, default?:string, completion?:string}
---@param cb fun(input:string?)
local function input(opts, cb)
  vim.ui.input(opts, function(val)
    cb(val) -- val 为 nil 表示用户取消
  end)
end

-- 在 explorer 窗内执行 split-like 命令打开 path，并把新窗口 chrome 拉回全局默认。
-- 给 M.open / open_in 在找不到主窗口时做 fallback：从 explorer 窗 split 出来的新窗口
-- 会继承 explorer 的 number=false 等隐藏装饰，必须显式 show_chrome
---@param state table
---@param cmd string  形如 'rightbelow vsplit' / 'split' / 'vsplit' / 'tabedit'
---@param path string
local function open_in_explorer_split(state, cmd, path)
  vim.api.nvim_set_current_win(state.win)
  vim.cmd(cmd .. ' ' .. vim.fn.fnameescape(path))
  require('vv-utils.ui_window').show_chrome(vim.api.nvim_get_current_win())
end

---@param state table
---@return table?
function M.node_under_cursor(state)
  if not vim.api.nvim_win_is_valid(state.win) then return nil end
  local lnum = vim.api.nvim_win_get_cursor(state.win)[1]
  -- 过滤视图（active 且 query 非空）：line 1 就是首个匹配行（没有 root header）
  -- 空 query 时虽然 active=true，但渲染走的是普通树（含 root header），按普通分支处理
  local f = state.filter
  if f and f.active and (f.query or '') ~= '' then
    local row = state.rows and state.rows[lnum]
    return row and row.node or nil
  end
  if lnum == 1 then return state.root end
  local row = state.rows and state.rows[lnum - 1]
  return row and row.node or nil
end

-- filter 模式下点击目录：退出过滤 + 展开到该目录 + 光标落到 dir 行
---@param state table
---@param node table
local function open_dir_from_filter_view(state, node)
  M.clear_filter(state)
  Tree.expand_to(state.root, node.path)
  local dir_node = Tree.find(state.root, node.path)
  if dir_node and dir_node.is_dir then dir_node.open = true end
  Render.render(state)
  focus_path(state, node.path)
end

-- 普通模式下点击目录：切换展开
---@param node table
---@param state table
local function toggle_dir(state, node)
  node.open = not node.open
  if node.open then Tree.ensure_scanned(node) end
  Render.render(state)
end

-- 点击文件：升级预览 → 在主窗口 :edit；无主窗口走 explorer split fallback
---@param state table
---@param node table
local function open_file(state, node)
  Preview.promote(state)
  local main = Preview.find_main_win(state.win)
  if not main then
    -- 没主窗口：只有 explorer 一个窗口（用户先 :only 或 <leader>ba 后只剩树）
    open_in_explorer_split(state, 'rightbelow vsplit', node.path)
    return
  end
  vim.api.nvim_set_current_win(main)
  local prev_buf = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_buf_get_name(0)
  if cur ~= vim.fn.fnamemodify(node.path, ':p') then
    vim.cmd('edit ' .. vim.fn.fnameescape(node.path))
    -- 被 :edit 替换掉的空 [No Name] → wipe（preview off 时主窗替换的唯一入口）
    require('vv-utils.bufdelete').wipe_if_throwaway(prev_buf)
  end
end

---@param state table  打开文件 / 切换目录展开
function M.open(state)
  local node = M.node_under_cursor(state)
  if not node then return end

  if state.filter and state.filter.active and node.is_dir then
    return open_dir_from_filter_view(state, node)
  end
  if node.is_dir then
    return toggle_dir(state, node)
  end
  open_file(state, node)
end

---@param state table  关闭目录 / 跳到父目录
function M.close_node(state)
  local node = M.node_under_cursor(state)
  if not node then return end

  if node.is_dir and node.open then
    node.open = false
    Render.render(state)
    return
  end

  if node.parent and node.parent ~= state.root then
    node.parent.open = false
    Render.render(state)
    focus_path(state, node.parent.path)
  end
end

---@param state table
function M.toggle_hidden(state)
  state.opts.hidden = not state.opts.hidden
  Render.render(state)
  vim.notify('vv-explorer: hidden = ' .. tostring(state.opts.hidden))
end

---@param state table
function M.refresh(state)
  Tree.refresh(state.root)
  if state.filter then
    state.filter.index = nil -- 失效索引，下次 / 重建
  end
  if state.git and state.git.refresh then state.git.refresh() end
  Render.render(state)
end

---@param state table  复制绝对路径到 + 寄存器
function M.yank_abs_path(state)
  local node = M.node_under_cursor(state)
  if not node then return end
  local abs = vim.fn.fnamemodify(node.path, ':p')
  vim.fn.setreg('+', abs)
  vim.notify('Copied: ' .. abs)
end

-- 在主窗口执行打开命令（文件节点专用；目录走 open）
-- cmd 形如 'split' / 'vsplit' / 'tabedit'
---@param state table
---@param cmd string
local function open_in(state, cmd)
  local node = M.node_under_cursor(state)
  if not node or node.is_dir then return end
  Preview.promote(state) -- 不删预览 buffer
  local main = Preview.find_main_win(state.win)
  if main and vim.api.nvim_win_is_valid(main) then
    vim.api.nvim_set_current_win(main)
    vim.cmd(cmd .. ' ' .. vim.fn.fnameescape(node.path))
  else
    open_in_explorer_split(state, cmd, node.path)
  end
end

---@param state table  水平分屏打开文件
function M.open_split(state) open_in(state, 'split') end

---@param state table  垂直分屏打开文件
function M.open_vsplit(state) open_in(state, 'vsplit') end

---@param state table  新 tab 打开文件
function M.open_tab(state) open_in(state, 'tabedit') end

---@param state table  用系统默认程序打开（xdg-open / open / start）
function M.system_open(state)
  local node = M.node_under_cursor(state)
  if not node then return end
  require('vv-utils.sys').open_default(node.path)
end

---@param state table  I：切换 .gitignore 命中的文件是否显示（Phase 2 生效）
function M.toggle_gitignored(state)
  state.opts.git = state.opts.git or {}
  state.opts.git.show_ignored = not state.opts.git.show_ignored
  Render.render(state)
  vim.notify('vv-explorer: show_ignored = ' .. tostring(state.opts.git.show_ignored))
end

---@param state table  ?：打开 mappings 帮助浮窗
function M.help(state)
  require('vv-explorer.help').open(state)
end

---@param state table  把 cwd 切到光标所在目录（不影响 vim cwd，仅树视图）
function M.cd_to(state)
  local node = M.node_under_cursor(state)
  if not node or not node.is_dir then return end
  state.root = Tree.new_root(node.path)
  Render.render(state)
end

---@param state table
function M.cd_up(state)
  local parent = vim.fs.dirname(state.root.path)
  if parent == state.root.path then return end
  state.root = Tree.new_root(parent)
  M.clear_filter(state) -- 切根失效 index
  Render.render(state)
end

---@param state table
local function refilter(state)
  local f = state.filter
  -- 空 query：保持普通树视图（不进过滤渲染），并清掉陈旧 match_count
  if (f.query or '') == '' then
    f.matched = EMPTY_MATCHED
    f.match_count = nil
  elseif not f.index then
    f.matched = EMPTY_MATCHED
  else
    f.matched = Filter.match(f.index, state.root.path, f.query, f.mode)
  end
  Render.render(state) -- 更新 state.filter.match_count（仅过滤渲染会写）
  if f.on_redraw then pcall(f.on_redraw) end
end

-- 把"matched 路径列表"转成"它们在 tree 视图里的行号列表（升序）"
---@param state table
---@return integer[]
local function matched_lnums(state)
  local f = state.filter
  if not f then return {} end
  local lnums = {}
  for _, abs in ipairs(f.matched.abs) do
    local l = state.path_to_row and state.path_to_row[abs]
    if l then lnums[#lnums + 1] = l end
  end
  table.sort(lnums)
  return lnums
end

-- prompt 内 <C-n>/<C-p>：在 tree 窗口里跳到下/上一个 match。焦点不动（仍在 prompt）
---@param state table
---@param dir integer  +1 / -1
local function filter_navigate(state, dir)
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local lnums = matched_lnums(state)
  if #lnums == 0 then return end

  local cur = vim.api.nvim_win_get_cursor(state.win)[1]
  local target
  if dir > 0 then
    for _, l in ipairs(lnums) do
      if l > cur then target = l; break end
    end
    target = target or lnums[1] -- 循环到首
  else
    for i = #lnums, 1, -1 do
      if lnums[i] < cur then target = lnums[i]; break end
    end
    target = target or lnums[#lnums] -- 循环到末
  end

  pcall(vim.api.nvim_win_set_cursor, state.win, { target, 0 })

  -- 焦点不在 tree → CursorMoved autocmd 不会 fire，需手动驱动 preview
  local node = M.node_under_cursor(state)
  if node and not node.is_dir then
    pcall(Preview.preview_file, state, node.path)
  end
end

-- prompt 内 <C-x>/<C-v>：直接以 split / vsplit 打开当前 match
-- 调用前 prompt 已 close。负责：清 filter → 在普通树视图里展开到该路径 → 调 open_in
---@param state table
---@param kind 'split'|'vsplit'
local function filter_open_in(state, kind)
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  vim.api.nvim_set_current_win(state.win)

  local node = M.node_under_cursor(state)
  if not node or node.is_dir then
    M.clear_filter(state)
    return
  end
  local target_path = node.path

  -- 清 filter 后视图回到普通树；展开到 target 让光标找得到行号
  M.clear_filter(state)
  Tree.expand_to(state.root, target_path)
  Render.render(state)
  focus_path(state, target_path)

  if kind == 'split' then
    M.open_split(state)
  elseif kind == 'vsplit' then
    M.open_vsplit(state)
  end
end

---@param state table
---@return VVExplorerPromptOpts
local function make_prompt_callbacks(state)
  local f = state.filter
  return {
    initial = f.query,
    on_change = function(q)
      f.query = q
      refilter(state)
    end,
    on_submit = function(q) -- 保持 filter，把光标落到首个 match
      f.query = q
      refilter(state)
      if vim.api.nvim_win_is_valid(state.win) then
        vim.api.nvim_set_current_win(state.win)
        local first = f.matched.abs[1]
        if first then focus_path(state, first) end
      end
    end,
    on_cancel = function()
      M.clear_filter(state)
      if vim.api.nvim_win_is_valid(state.win) then
        vim.api.nvim_set_current_win(state.win)
      end
    end,
    on_cycle_mode = function()
      f.mode = Filter.next_mode(f.mode)
      refilter(state)
      return f.mode
    end,
    get_mode = function() return f.mode end,
    on_navigate = function(dir) filter_navigate(state, dir) end,
    on_open_in = function(kind) filter_open_in(state, kind) end,
  }
end

-- 首次触发时异步建全树索引；fd 缺失 → 提示 + 退出过滤态
---@param state table
---@return boolean ok  fd 缺失返回 false（caller 应中止）
local function ensure_filter_index(state)
  local f = state.filter
  if f.index or f.index_building then return true end
  f.index_building = true
  local ok = Filter.build_index(state.root.path, { hidden = state.opts.hidden }, function(paths)
    f.index = paths
    f.index_building = false
    if state.filter and state.filter.active then refilter(state) end
  end)
  if not ok then
    f.index_building = false
    M.clear_filter(state)
    return false
  end
  return true
end

---@param state table  按 /：打开浮动输入框，实时过滤
function M.start_filter(state)
  state.filter = state.filter or {
    active = false,
    mode = 'fuzzy',
    query = '',
    index = nil,
    index_building = false,
    matched = EMPTY_MATCHED,
  }
  -- 兼容跨版本升级：旧 state（cross-open 复用 buf）可能没 mode 字段
  state.filter.mode = state.filter.mode or 'fuzzy'
  state.filter.active = true

  if not ensure_filter_index(state) then return end

  -- 立刻渲染一个"indexing…"占位（query 可能为空）
  refilter(state)

  Prompt.open(state, make_prompt_callbacks(state))
end

---@param state table  清除过滤，恢复正常视图
function M.clear_filter(state)
  if not state.filter or not state.filter.active then return end
  state.filter.active = false
  state.filter.query = ''
  state.filter.matched = EMPTY_MATCHED
  -- 保留 index，下次 / 可复用（refresh/cd 时会重建）
  Render.render(state)
end

-- ============ 选区 ============

---@param state table  <Tab>：切换光标节点的选中态（再按一次即取消）
function M.toggle_select(state)
  ensure_state_fields(state)
  local node = M.node_under_cursor(state)
  if not node or node == state.root then return end
  if state.selection[node.path] then
    state.selection[node.path] = nil
  else
    state.selection[node.path] = true
  end
  Render.render(state)
end

---@param state table  清空选区
function M.clear_selection(state)
  ensure_state_fields(state)
  if not next(state.selection) then return end
  state.selection = {}
  Render.render(state)
end

-- <Esc> 的统一行为：filter > selection > 无操作
---@param state table
function M.escape(state)
  if state.filter and state.filter.active then
    M.clear_filter(state)
    return
  end
  if state.selection and next(state.selection) then
    M.clear_selection(state)
  end
end

-- ============ CRUD ============

-- a：新建。尾随 '/' 表示目录（中间目录自动 mkdir -p）
---@param state table
function M.create(state)
  ensure_state_fields(state)
  local node = M.node_under_cursor(state)
  local base = dir_context(state, node)
  local rel_prompt = vim.fn.fnamemodify(base, ':.')
  if rel_prompt == '' then rel_prompt = '.' end

  input({ prompt = 'New (' .. rel_prompt .. '/): ', default = '', completion = 'file' }, function(name)
    if not name or name == '' then return end
    local is_dir = name:sub(-1) == '/'
    local rel = name:gsub('/$', '')
    local target = vim.fs.normalize(base .. '/' .. rel)

    local ok, err = pcall(function()
      if is_dir then
        Fs.mkdir_p(target)
      else
        Fs.create_file(target)
      end
    end)
    if not ok then
      vim.notify('vv-explorer: ' .. tostring(err), vim.log.levels.ERROR)
      return
    end

    after_fs_change(state)
    Tree.expand_to(state.root, target)
    Render.render(state)
    focus_path(state, target)
    vim.notify('Created: ' .. vim.fn.fnamemodify(target, ':.'))
  end)
end

-- d：删除（批量或单个），带确认
---@param state table
function M.delete(state)
  ensure_state_fields(state)
  local node = M.node_under_cursor(state)
  local paths = targets(state, node)
  if #paths == 0 then return end

  local msg
  if #paths == 1 then
    msg = 'Delete ' .. vim.fn.fnamemodify(paths[1], ':.') .. ' ?'
  else
    msg = ('Delete %d items ?'):format(#paths)
  end
  local choice = vim.fn.confirm(msg, '&Yes\n&No', 2)
  if choice ~= 1 then return end

  local failed = {}
  for _, p in ipairs(paths) do
    local ok, err = pcall(Fs.delete, p)
    if not ok then failed[#failed + 1] = tostring(err) end
  end
  if #failed > 0 then
    vim.notify('vv-explorer: delete errors:\n' .. table.concat(failed, '\n'), vim.log.levels.ERROR)
  else
    vim.notify(('Deleted %d item(s)'):format(#paths))
  end
  after_fs_change(state)
end

-- r：重命名（单个；选区非空时仍只处理光标节点）
---@param state table
function M.rename(state)
  ensure_state_fields(state)
  local node = M.node_under_cursor(state)
  if not node or node == state.root then return end
  local old = node.path

  input({ prompt = 'Rename: ', default = node.name }, function(new_name)
    if not new_name or new_name == '' or new_name == node.name then return end
    local new_path = vim.fs.normalize(vim.fs.dirname(old) .. '/' .. new_name)

    local ok, err = pcall(Fs.rename, old, new_path)
    if not ok then
      vim.notify('vv-explorer: ' .. tostring(err), vim.log.levels.ERROR)
      return
    end
    Fs.sync_buffers(old, new_path)
    after_fs_change(state)
    Tree.expand_to(state.root, new_path)
    Render.render(state)
    focus_path(state, new_path)
  end)
end

-- ============ 剪贴板：cut / copy / paste ============

---@param state table  x：把 targets 标记为剪切
function M.cut_mark(state)
  ensure_state_fields(state)
  local node = M.node_under_cursor(state)
  local paths = targets(state, node)
  if #paths == 0 then return end
  state.clipboard = { mode = 'cut', paths = paths }
  vim.notify(('Cut %d item(s)'):format(#paths))
end

---@param state table  c：把 targets 标记为复制
function M.copy_mark(state)
  ensure_state_fields(state)
  local node = M.node_under_cursor(state)
  local paths = targets(state, node)
  if #paths == 0 then return end
  state.clipboard = { mode = 'copy', paths = paths }
  vim.notify(('Copy %d item(s)'):format(#paths))
end

-- p：粘贴到光标目录；同名冲突追加 ' (copy)' 后缀
---@param state table
function M.paste(state)
  ensure_state_fields(state)
  if not state.clipboard or #state.clipboard.paths == 0 then
    vim.notify('vv-explorer: clipboard empty', vim.log.levels.WARN)
    return
  end
  local node = M.node_under_cursor(state)
  local dest_dir = dir_context(state, node)
  local mode = state.clipboard.mode
  local last_dst

  local failed = {}
  for _, src in ipairs(state.clipboard.paths) do
    -- 防止 cut 到自己的子孙里（会导致丢失）
    if mode == 'cut' and (dest_dir == src or dest_dir:sub(1, #src + 1) == src .. '/') then
      failed[#failed + 1] = 'skip: ' .. src .. ' → inside itself'
      goto continue
    end
    local dst = Fs.unique_dest(dest_dir .. '/' .. vim.fs.basename(src))
    local ok, err = pcall(function()
      if mode == 'cut' then
        Fs.rename(src, dst)
        Fs.sync_buffers(src, dst)
      else
        Fs.copy(src, dst)
      end
    end)
    if not ok then
      failed[#failed + 1] = tostring(err)
    else
      last_dst = dst
    end
    ::continue::
  end

  if #failed > 0 then
    vim.notify('vv-explorer: paste errors:\n' .. table.concat(failed, '\n'), vim.log.levels.ERROR)
  end
  if mode == 'cut' then state.clipboard = nil end
  after_fs_change(state)
  if last_dst then
    Tree.expand_to(state.root, last_dst)
    Render.render(state)
    focus_path(state, last_dst)
  end
end

local SCROLL_LINES = 5 -- 每次 <C-e>/<C-y> 在主窗口滚动的行数
local CE_KEY = vim.api.nvim_replace_termcodes('<C-e>', true, false, true)
local CY_KEY = vim.api.nvim_replace_termcodes('<C-y>', true, false, true)

local function scroll_preview(state, keys)
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local target = Preview.find_main_win(state.win)

  if not target or not vim.api.nvim_win_is_valid(target) then return end
  local prev = vim.api.nvim_get_current_win()
  local cmd = 'normal! ' .. SCROLL_LINES .. keys

  if prev == target then
    pcall(vim.cmd, cmd)
    return
  end

  pcall(vim.api.nvim_set_current_win, target)
  pcall(vim.cmd, cmd)

  if vim.api.nvim_win_is_valid(prev) then
    pcall(vim.api.nvim_set_current_win, prev)
  end
end

function M.scroll_preview_down(state) scroll_preview(state, CE_KEY) end
function M.scroll_preview_up(state) scroll_preview(state, CY_KEY) end

return M

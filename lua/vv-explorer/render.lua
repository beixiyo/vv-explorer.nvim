-- 渲染：tree.flatten → buffer 行 + extmark 着色
-- extmark 列偏移用字节计算（Lua # 给字节长度，与 nvim_buf_set_extmark 一致）

local Tree = require('vv-explorer.tree')
local Icons = require('vv-explorer.icons')
local Filter = require('vv-explorer.filter')
local Git = require('vv-explorer.git')
local Diagnostics = require('vv-explorer.diagnostics')

local M = {}
local ns = vim.api.nvim_create_namespace('vv-explorer')

local ui_icons = require('vv-icons').raw.ui
local CB_CUT  = ui_icons.clipboard_cut
local CB_COPY = ui_icons.clipboard_copy

---@param state table
---@return table<string, boolean> set, string? mode
local function clipboard_set(state)
  if not state.clipboard then return {}, nil end
  local set = {}
  for _, p in ipairs(state.clipboard.paths) do set[p] = true end
  return set, state.clipboard.mode
end

-- dim 三层规则：
--   tracked → 永远正常色（用户明确在意的文件，凌驾于 dotfile / ignored 之上）
--   dotfile（node.hidden）或 gitignored → 暗色
-- state.git.is_tracked / is_ignored 由 git 模块提供，未启用则为 nil
---@param state table
---@param path string
---@param hidden boolean
---@return boolean
local function is_dim(state, path, hidden)
  local git = state.git
  if git and git.is_tracked and git.is_tracked(path) then return false end
  if hidden then return true end
  if git and git.is_ignored and git.is_ignored(path) then return true end
  return false
end

-- VSCode 风：纯空格缩进，dir 前画 chevron，file 无箭头（用空格对齐）
-- 关键：arrow / icon 都用 strdisplaywidth 测量，**补齐到固定 2 列**，
-- 才能扛住不同 nerd font / MiniIcons 给的 1-col 或 2-col glyph 混排
local INDENT_STEP = '  '   -- 2 列 / 深度
local ARROW_OPEN  = ui_icons.fold_open.glyph
local ARROW_CLOSE = ui_icons.fold_closed.glyph
local ARROW_SLOT_COLS = 2  -- 箭头槽位固定 2 列
local ICON_SLOT_COLS  = 2  -- 图标槽位固定 2 列

local function pad_to_cols(s, cols)
  local w = vim.fn.strdisplaywidth(s)
  if w >= cols then return s, w end
  return s .. string.rep(' ', cols - w), cols
end

---@param opts {depth:integer, is_dir:boolean, is_open:boolean, has_children:boolean, display_name:string, path:string, match_positions?:integer[], basename_byte_offset?:integer, dim?:boolean, clipboard?:'cut'|'copy', git_symbol?:{glyph:string,hl:string}, diag_symbol?:{glyph:string,hl:string}}
---@return string line, table[] extmarks, integer name_col  extmarks 不含 lnum，调用方负责 row 赋值；name_col 为 name 起始字节偏移
local function build_row_visual(opts)
  local prefix = string.rep(INDENT_STEP, opts.depth)

  local arrow_raw = ''
  if opts.is_dir then
    arrow_raw = opts.is_open and ARROW_OPEN or ARROW_CLOSE
  end
  local arrow_block = pad_to_cols(arrow_raw, ARROW_SLOT_COLS)

  local icon, ihl = Icons.resolve({
    name = opts.display_name,
    path = opts.path,
    is_dir = opts.is_dir,
    open = opts.is_open,
    has_children = opts.has_children,
  })
  local icon_block = pad_to_cols(icon, ICON_SLOT_COLS)

  local name = opts.display_name
  local line = prefix .. arrow_block .. icon_block .. name

  -- dim：dotfile / gitignored → 整行（icon + name）走 VVExplorerDim
  local name_hl = opts.is_dir and 'VVExplorerDir' or 'VVExplorerFile'
  local icon_hl = ihl or 'VVExplorerFile'
  if opts.dim then
    name_hl = 'VVExplorerDim'
    icon_hl = 'VVExplorerDim'
  end

  local extmarks = {}
  local col = #prefix

  if #arrow_raw > 0 then
    extmarks[#extmarks + 1] = {
      col = col,
      opts = { end_col = col + #arrow_raw, hl_group = 'VVExplorerIndent' },
    }
  end
  col = col + #arrow_block

  if #icon > 0 then
    extmarks[#extmarks + 1] = {
      col = col,
      opts = { end_col = col + #icon, hl_group = icon_hl },
    }
  end
  col = col + #icon_block

  extmarks[#extmarks + 1] = {
    col = col,
    opts = { end_col = col + #name, hl_group = name_hl },
  }

  -- 行尾符号：剪贴板标记 + git 状态 + 诊断（inline virt_text，不占真实列）
  local chunks
  if opts.clipboard or opts.git_symbol or opts.diag_symbol then
    chunks = {}
    if opts.clipboard then
      local icon = opts.clipboard == 'cut' and CB_CUT or CB_COPY
      chunks[#chunks + 1] = { ' ', nil }
      chunks[#chunks + 1] = { icon.glyph, icon.hl }
    end
    if opts.git_symbol then
      chunks[#chunks + 1] = { ' ', nil }
      chunks[#chunks + 1] = { opts.git_symbol.glyph, opts.git_symbol.hl }
    end
    if opts.diag_symbol then
      chunks[#chunks + 1] = { ' ', nil }
      chunks[#chunks + 1] = { opts.diag_symbol.glyph, opts.diag_symbol.hl }
    end
  end
  if chunks then
    extmarks[#extmarks + 1] = {
      col = col + #name,
      opts = { virt_text = chunks, virt_text_pos = 'inline' },
    }
  end

  if opts.match_positions then
    local basename_start = opts.basename_byte_offset or 0
    for _, pos in ipairs(opts.match_positions) do
      local bpos = pos - basename_start
      if bpos >= 0 and bpos < #name then
        extmarks[#extmarks + 1] = {
          col = col + bpos,
          opts = { end_col = col + bpos + 1, hl_group = 'VVExplorerMatch' },
        }
      end
    end
  end

  return line, extmarks, col
end

---@param buf integer
---@param lines string[]
---@param extmarks table[]  每项 { row, col, opts }
local function flush(buf, lines, extmarks)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, em in ipairs(extmarks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, em.row, em.col, em.opts)
  end
  vim.bo[buf].modifiable = false
end

---@param state table
function M.render(state)
  if not state or not vim.api.nvim_buf_is_valid(state.buf) then return end

  -- query 非空才进过滤渲染；空 query 保持普通树视图（"打开 / 不立刻筛掉一切"）
  if state.filter and state.filter.active and (state.filter.query or '') ~= '' then
    return M.render_filter(state)
  end

  local rows = Tree.flatten(state.root, {
    hidden = state.opts.hidden,
    group_empty_dirs = state.opts.group_empty_dirs,
    custom_globs = state.opts.filter and state.opts.filter.custom,
    is_ignored = state.git and state.git.is_ignored,
    show_ignored = state.opts.git and state.opts.git.show_ignored,
    is_tracked = state.git and state.git.is_tracked,
  })
  state.rows = rows

  local lines = {}
  local extmarks = {}
  local path_to_row = {}
  local name_cols = {}

  -- 根行
  local root_label = vim.fn.fnamemodify(state.root.path, ':~')
  lines[1] = root_label
  name_cols[1] = 0
  extmarks[#extmarks + 1] = {
    row = 0, col = 0,
    opts = { end_col = #root_label, hl_group = 'VVExplorerRoot' },
  }
  path_to_row[state.root.path] = 1

  local cb_set, cb_mode = clipboard_set(state)

  local git = state.git
  local diag = state.diagnostics
  local renaming_path = state._lsp_renaming_path
  for _, row in ipairs(rows) do
    local node = row.node
    local is_renaming = renaming_path and node.path == renaming_path
    local git_sym = (not is_renaming) and git and git.status_map and Git.symbol_for(git.status_map[node.path])
    local diag_sym = (not is_renaming) and diag and Diagnostics.symbol_for(diag[node.path])
    local line, ems, name_col = build_row_visual({
      depth = row.depth,
      is_dir = node.is_dir,
      is_open = node.open,
      has_children = row.has_children,
      display_name = row.display_name,
      path = node.path,
      dim = is_dim(state, node.path, node.hidden),
      clipboard = cb_set[node.path] and cb_mode or nil,
      git_symbol = git_sym or nil,
      diag_symbol = diag_sym or nil,
    })
    lines[#lines + 1] = line
    local lnum = #lines - 1
    name_cols[#lines] = name_col
    for _, em in ipairs(ems) do
      extmarks[#extmarks + 1] = { row = lnum, col = em.col, opts = em.opts }
    end

    path_to_row[node.path] = lnum + 1
    if #row.group_chain > 1 then
      local p = node.path
      for _ = #row.group_chain, 2, -1 do
        p = vim.fs.dirname(p)
        if not path_to_row[p] then path_to_row[p] = lnum + 1 end
      end
    end
  end

  state.path_to_row = path_to_row
  state.name_cols = name_cols

  -- 选区：整行高亮（不占 signcolumn）
  if state.selection then
    for p in pairs(state.selection) do
      local lnum = path_to_row[p]
      if lnum then
        extmarks[#extmarks + 1] = {
          row = lnum - 1, col = 0,
          opts = { line_hl_group = 'VVExplorerSelected' },
        }
      end
    end
  end

  flush(state.buf, lines, extmarks)

  if state.on_after_render then
    pcall(state.on_after_render, state)
  end
end

-- 把光标移到 state._pending_reveal 指向的行并清除 pending。
--
-- 用 strict 定位（find_row 第三参数）：只在「目标文件自身那一行已渲染」时归位，
-- 绝不回溯到祖先。否则隐藏/被过滤的文件（dotfile 未跟踪、gitignored）会让光标强制
-- 跳到最近的可见祖先目录行——用户并未要求看那一行。
--
-- 定位不到时保留 pending：合法的「暂时不可见」只有一种——「hidden + git tracked」目录
-- 要等 git 的 is_tracked 异步就绪后才进入 flatten，期间整棵子树被过滤。待 git 完成触发
-- 的 render_stable 把目标行渲染出来，本函数再归位。真正被永久隐藏的文件则 strict 恒 miss，
-- 光标始终不动，正合预期。
---@param state table
---@return boolean positioned  成功归位（已清 pending）返回 true
function M.try_reveal_cursor(state)
  local file = state._pending_reveal
  if not file then return false end
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then return false end

  local lnum = require('vv-explorer.actions').find_row(state, file, true)
  if not lnum or lnum == 1 then return false end

  pcall(vim.api.nvim_win_set_cursor, state.win, { lnum, 0 })
  state._pending_reveal = nil
  return true
end

function M.render_stable(state)
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then
    return M.render(state)
  end

  local lnum = vim.api.nvim_win_get_cursor(state.win)[1]
  local prev_path
  local f = state.filter
  if f and f.active and (f.query or '') ~= '' then
    local row = state.rows and state.rows[lnum]
    prev_path = row and row.node and row.node.path
  elseif lnum == 1 then
    prev_path = state.root and state.root.path
  elseif state.rows then
    local row = state.rows[lnum - 1]
    prev_path = row and row.node and row.node.path
  end

  state._skip_preview = true
  M.render(state)

  -- pending reveal 优先于 prev_path 复原：reveal 目标行此前缺失（git 异步未就绪），
  -- 一旦出现就归位；两者意图不同时以用户的 reveal 意图为准
  if not M.try_reveal_cursor(state) and prev_path and state.path_to_row then
    local new_lnum = state.path_to_row[prev_path]
    if new_lnum then
      pcall(vim.api.nvim_win_set_cursor, state.win, { new_lnum, 0 })
    end
  end
  state._skip_preview = nil
end

-- 过滤模式渲染：平铺显示 matches + 祖先链，match 字符高亮
---@param state table
function M.render_filter(state)
  local f = state.filter
  local cwd = state.root.path
  local matched_abs = f.matched.abs
  local visible, visible_is_dir_map = Filter.visible_set(matched_abs, cwd)

  local positions_by_path = {}
  for i = 1, #f.matched.rels do
    positions_by_path[f.matched.abs[i]] = f.matched.positions[i]
  end

  local path_rank = {}
  for rank, abs in ipairs(matched_abs) do
    local p = abs
    while true do
      if not path_rank[p] or rank < path_rank[p] then
        path_rank[p] = rank
      end
      local parent = vim.fs.dirname(p)
      if parent == p or parent == cwd or #parent <= #cwd then break end
      p = parent
    end
  end

  local list = {}
  local path_parts = {}
  for p in pairs(visible) do 
    list[#list + 1] = p 
    local rel = p:sub(#cwd + 2)
    local parts = {}
    local current = cwd
    for part in rel:gmatch('[^/]+') do
      current = current .. '/' .. part
      parts[#parts + 1] = { name = part, path = current }
    end
    path_parts[p] = parts
  end

  table.sort(list, function(a, b)
    local pa = path_parts[a]
    local pb = path_parts[b]
    for i = 1, math.min(#pa, #pb) do
      local ca = pa[i]
      local cb = pb[i]
      if ca.name ~= cb.name then
        local rankA = path_rank[ca.path] or 999999
        local rankB = path_rank[cb.path] or 999999
        if rankA ~= rankB then
          return rankA < rankB
        end
        return ca.name < cb.name
      end
    end
    return #pa < #pb
  end)

  local lines = {}
  local extmarks = {}
  local path_to_row = {}
  local name_cols = {}
  local pseudo_rows = {}

  state.filter.match_count = f.matched.total_count
  state.filter.display_count = #matched_abs

  local cb_set, cb_mode = clipboard_set(state)

  for _, path in ipairs(list) do
    local rel = path:sub(#cwd + 2)
    local depth = 0
    for _ in rel:gmatch('/') do depth = depth + 1 end
    local name = vim.fs.basename(path)
    
    local is_dir
    if visible_is_dir_map[path] then
      is_dir = true
    elseif f.is_dir_map and f.is_dir_map[path] ~= nil then
      is_dir = f.is_dir_map[path]
    else
      is_dir = vim.fn.isdirectory(path) == 1
    end

    local git = state.git
    local diag = state.diagnostics
    local is_renaming = state._lsp_renaming_path and path == state._lsp_renaming_path
    local git_sym = (not is_renaming) and git and git.status_map and Git.symbol_for(git.status_map[path])
    local diag_sym = (not is_renaming) and diag and Diagnostics.symbol_for(diag[path])
    local line, ems, name_col = build_row_visual({
      depth = depth,
      is_dir = is_dir,
      is_open = is_dir,
      has_children = is_dir,
      display_name = name,
      path = path,
      match_positions = positions_by_path[path],
      basename_byte_offset = #rel - #name,
      dim = is_dim(state, path, name:sub(1, 1) == '.'),
      clipboard = cb_set[path] and cb_mode or nil,
      git_symbol = git_sym or nil,
      diag_symbol = diag_sym or nil,
    })
    lines[#lines + 1] = line
    local lnum = #lines - 1
    name_cols[#lines] = name_col
    for _, em in ipairs(ems) do
      extmarks[#extmarks + 1] = { row = lnum, col = em.col, opts = em.opts }
    end

    path_to_row[path] = lnum + 1
    pseudo_rows[#pseudo_rows + 1] = {
      node = {
        path = path, name = name, is_dir = is_dir,
        open = false, parent = nil, type = is_dir and 'directory' or 'file',
      },
      depth = depth,
      display_name = name,
      group_chain = {},
      has_children = false,
    }
  end

  state.rows = pseudo_rows
  state.path_to_row = path_to_row
  state.name_cols = name_cols

  if state.selection then
    for p in pairs(state.selection) do
      local lnum = path_to_row[p]
      if lnum then
        extmarks[#extmarks + 1] = {
          row = lnum - 1, col = 0,
          opts = { line_hl_group = 'VVExplorerSelected' },
        }
      end
    end
  end

  flush(state.buf, lines, extmarks)

  -- 自动滚动到最佳匹配项（fuzzy 模式下 matched.abs[1] 是得分最高的项）。
  -- 仅在「过滤结果刚变化」时执行（由 refilter 置 _want_scroll，一次性消费）：
  -- 否则 <C-n>/<C-p> 导航、或预览触发的诊断/git/fs 增量重渲，都会把光标从用户
  -- 当前所在的 match 强行抢回首个 match，造成光标乱跳。
  local want_scroll = f._want_scroll
  f._want_scroll = nil
  if want_scroll and #matched_abs > 0 and state.win and vim.api.nvim_win_is_valid(state.win) then
    local best = matched_abs[1]
    local target_lnum = path_to_row[best]
    if target_lnum then
      pcall(vim.api.nvim_win_set_cursor, state.win, { target_lnum, 0 })
    end
  end
end

return M

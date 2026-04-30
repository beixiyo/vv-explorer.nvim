-- 渲染：tree.flatten → buffer 行 + extmark 着色
-- extmark 列偏移用字节计算（Lua # 给字节长度，与 nvim_buf_set_extmark 一致）

local Tree = require('vv-explorer.tree')
local Icons = require('vv-explorer.icons')
local Filter = require('vv-explorer.filter')
local Git = require('vv-explorer.git')
local Diagnostics = require('vv-explorer.diagnostics')

local M = {}
local ns = vim.api.nvim_create_namespace('vv-explorer')

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
local ARROW_OPEN  = '' -- nf-fa-chevron_down
local ARROW_CLOSE = '' -- nf-fa-chevron_right
local ARROW_SLOT_COLS = 2  -- 箭头槽位固定 2 列
local ICON_SLOT_COLS  = 2  -- 图标槽位固定 2 列

local function pad_to_cols(s, cols)
  local w = vim.fn.strdisplaywidth(s)
  if w >= cols then return s, w end
  return s .. string.rep(' ', cols - w), cols
end

---@param opts {depth:integer, is_dir:boolean, is_open:boolean, has_children:boolean, display_name:string, path:string, match_positions?:integer[], basename_byte_offset?:integer, dim?:boolean, git_symbol?:{glyph:string,hl:string}, diag_symbol?:{glyph:string,hl:string}}
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

  -- 行尾符号：git 状态 + 诊断（inline virt_text，不占真实列）
  local chunks
  if opts.git_symbol or opts.diag_symbol then
    chunks = {}
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

  local git = state.git
  local diag = state.diagnostics
  for _, row in ipairs(rows) do
    local node = row.node
    local git_sym = git and git.status_map and Git.symbol_for(git.status_map[node.path])
    local diag_sym = diag and Diagnostics.symbol_for(diag[node.path])
    local line, ems, name_col = build_row_visual({
      depth = row.depth,
      is_dir = node.is_dir,
      is_open = node.open,
      has_children = row.has_children,
      display_name = row.display_name,
      path = node.path,
      dim = is_dim(state, node.path, node.hidden),
      git_symbol = git_sym,
      diag_symbol = diag_sym,
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

-- 过滤模式渲染：平铺显示 matches + 祖先链，match 字符高亮
---@param state table
function M.render_filter(state)
  local f = state.filter
  local cwd = state.root.path
  local matched_abs = f.matched.abs
  local visible = Filter.visible_set(matched_abs, cwd)

  local positions_by_path = {}
  for i = 1, #f.matched.rels do
    positions_by_path[f.matched.abs[i]] = f.matched.positions[i]
  end

  local list = {}
  for p in pairs(visible) do list[#list + 1] = p end
  table.sort(list, function(a, b) return a < b end)

  local lines = {}
  local extmarks = {}
  local path_to_row = {}
  local name_cols = {}
  local pseudo_rows = {}

  state.filter.match_count = #matched_abs

  for _, path in ipairs(list) do
    local rel = path:sub(#cwd + 2)
    local depth = 0
    for _ in rel:gmatch('/') do depth = depth + 1 end
    local name = vim.fs.basename(path)
    local is_dir = vim.fn.isdirectory(path) == 1

    local git = state.git
    local diag = state.diagnostics
    local git_sym = git and git.status_map and Git.symbol_for(git.status_map[path])
    local diag_sym = diag and Diagnostics.symbol_for(diag[path])
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
      git_symbol = git_sym,
      diag_symbol = diag_sym,
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
end

return M

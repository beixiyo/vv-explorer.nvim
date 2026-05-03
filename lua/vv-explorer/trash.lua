-- 回收站：delete 改为 move-to-trash，支持恢复、浏览、清空
-- 数据目录 ~/.local/share/vv-explorer/trash/
-- 每个条目：<timestamp>_<basename> + 同名 .meta.json

local Fs = require('vv-utils.fs')
local hl_mod = require('vv-utils.hl')

local M = {}
local uv = vim.uv or vim.loop

local TRASH_DIR
local config

local function xdg_data()
  return vim.env.XDG_DATA_HOME or (vim.env.HOME .. '/.local/share')
end

local function format_size(bytes)
  if not bytes or bytes < 0 then return '—' end
  if bytes < 1024 then return bytes .. ' B' end
  if bytes < 1024 * 1024 then return string.format('%.1f KB', bytes / 1024) end
  if bytes < 1024 * 1024 * 1024 then return string.format('%.1f MB', bytes / (1024 * 1024)) end
  return string.format('%.1f GB', bytes / (1024 * 1024 * 1024))
end

local function dir_size_sync(path)
  local total = 0
  local handle = uv.fs_scandir(path)
  if not handle then return 0 end
  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then break end
    local full = path .. '/' .. name
    if typ == 'directory' then
      total = total + dir_size_sync(full)
    else
      local stat = uv.fs_stat(full)
      if stat then total = total + stat.size end
    end
  end
  return total
end

local function entry_size(path)
  local stat = uv.fs_stat(path)
  if not stat then return 0 end
  if stat.type == 'directory' then return dir_size_sync(path) end
  return stat.size
end

---@param opts {enabled:boolean, max_items:integer, warn_size_mb:integer, scan_on_open:boolean}
function M.setup(opts)
  config = opts
  TRASH_DIR = xdg_data() .. '/vv-explorer/trash'
  if config.enabled then Fs.mkdir_p(TRASH_DIR) end

  hl_mod.register('vv-explorer.trash.hl', {
    VVTrashTitle  = { link = 'Title' },
    VVTrashName   = { fg = '#c0caf5', bold = true },
    VVTrashPath   = { link = 'Comment' },
    VVTrashDate   = { fg = '#7aa2f7' },
    VVTrashSize   = { fg = '#9ece6a' },
    VVTrashEmpty  = { fg = '#565f89', italic = true },
    VVTrashFooter = { fg = '#565f89' },
    VVTrashSep    = { fg = '#3b4261' },
  })
end

function M.enabled()
  return config and config.enabled
end

local function enforce_max_items()
  if not config or not config.max_items then return end
  local entries = M.list()
  if #entries <= config.max_items then return end
  for i = config.max_items + 1, #entries do
    pcall(Fs.delete, entries[i].trash_path)
    pcall(Fs.delete, entries[i].meta_path)
  end
end

---@param paths string[]
---@return {trashed:string[], failed:string[]}
function M.trash(paths)
  local trashed, failed = {}, {}
  for _, path in ipairs(paths) do
    local ts = string.format('%010d', os.time())
    local base = vim.fs.basename(path)
    local trash_name = ts .. '_' .. base
    local dest = TRASH_DIR .. '/' .. trash_name

    -- 同秒同名冲突
    local counter = 0
    while Fs.exists(dest) or Fs.exists(dest .. '.meta.json') do
      counter = counter + 1
      trash_name = ts .. '_' .. counter .. '_' .. base
      dest = TRASH_DIR .. '/' .. trash_name
    end

    local size = entry_size(path)
    local ok, err = pcall(Fs.rename, path, dest)
    if not ok then
      failed[#failed + 1] = tostring(err)
    else
      local meta = vim.json.encode({
        original_path = path,
        trashed_at = os.time(),
        size_bytes = size,
      })
      pcall(Fs.write_all, dest .. '.meta.json', meta)
      trashed[#trashed + 1] = path
    end
  end

  if #trashed > 0 then
    vim.schedule(function() enforce_max_items() end)
  end
  return { trashed = trashed, failed = failed }
end


---@return {trash_name:string, trash_path:string, meta_path:string, original_path:string, trashed_at:integer, size_bytes:integer, basename:string}[]
function M.list()
  local handle = uv.fs_scandir(TRASH_DIR)
  if not handle then return {} end

  local entries = {}
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then break end
    if name:sub(-10) == '.meta.json' then goto continue end

    local trash_path = TRASH_DIR .. '/' .. name
    local meta_path = trash_path .. '.meta.json'
    local meta = {}

    local raw = Fs.read_all(meta_path)
    if raw and raw ~= '' then
      local ok, parsed = pcall(vim.json.decode, raw)
      if ok then meta = parsed end
    end

    entries[#entries + 1] = {
      trash_name = name,
      trash_path = trash_path,
      meta_path = meta_path,
      original_path = meta.original_path or '(unknown)',
      trashed_at = meta.trashed_at or 0,
      size_bytes = meta.size_bytes or 0,
      basename = (meta.original_path and vim.fs.basename(meta.original_path)) or name,
    }
    ::continue::
  end

  table.sort(entries, function(a, b) return a.trashed_at > b.trashed_at end)
  return entries
end

---@param entry table
---@return string restored_path
function M.restore(entry)
  local dest = entry.original_path
  Fs.mkdir_p(vim.fs.dirname(dest))
  if Fs.exists(dest) then dest = Fs.unique_dest(dest) end
  Fs.rename(entry.trash_path, dest)
  pcall(Fs.delete, entry.meta_path)
  return dest
end

---@param entry table
function M.delete_entry(entry)
  Fs.delete(entry.trash_path)
  pcall(Fs.delete, entry.meta_path)
end

function M.empty()
  local entries = M.list()
  for _, e in ipairs(entries) do
    pcall(Fs.delete, e.trash_path)
    pcall(Fs.delete, e.meta_path)
  end
end

---@param callback fun(bytes:integer)
function M.scan_size(callback)
  if not TRASH_DIR then return end
  vim.system(
    { 'du', '-sb', TRASH_DIR },
    { text = true },
    vim.schedule_wrap(function(r)
      local bytes = 0
      if r.code == 0 and r.stdout then
        bytes = tonumber(r.stdout:match('^(%d+)')) or 0
      end
      callback(bytes)
    end)
  )
end

-- ============ 回收站面板 ============

local ns = vim.api.nvim_create_namespace('vv-explorer.trash')

local function resolve_icon(basename)
  local mi = _G.MiniIcons
  if mi then
    local g, h = mi.get('file', basename)
    if g then return g, h end
  end
  return '', 'VVTrashName'
end

---@param state table?
function M.open_panel(state)
  local entries = M.list()

  local lines = {}
  local extmarks = {}
  local entry_by_lnum = {}
  local name_cols = {}

  -- 标题
  local title = '  Trash (' .. #entries .. ' items)'
  lines[#lines + 1] = title
  extmarks[#extmarks + 1] = { row = 0, col = 0, opts = { end_col = #title, hl_group = 'VVTrashTitle' } }

  local sep = string.rep('─', 56)
  lines[#lines + 1] = sep
  extmarks[#extmarks + 1] = { row = 1, col = 0, opts = { end_col = #sep, hl_group = 'VVTrashSep' } }

  if #entries == 0 then
    local empty = '  Trash is empty'
    lines[#lines + 1] = empty
    extmarks[#extmarks + 1] = { row = 2, col = 0, opts = { end_col = #empty, hl_group = 'VVTrashEmpty' } }
  else
    for i, e in ipairs(entries) do
      local icon, icon_hl = resolve_icon(e.basename)
      local date = os.date('%m-%d %H:%M', e.trashed_at)
      local size = format_size(e.size_bytes)
      local short_path = vim.fn.fnamemodify(e.original_path, ':~:h')

      local prefix = '  '
      local col = #prefix
      local line_parts = { prefix, icon, ' ', e.basename }
      local name_end = col + #icon + 1 + #e.basename

      -- 右侧信息
      local info = '  ' .. short_path .. '  ' .. date .. '  ' .. size
      line_parts[#line_parts + 1] = info
      local line = table.concat(line_parts)
      lines[#lines + 1] = line

      local row = #lines - 1
      entry_by_lnum[#lines] = i
      name_cols[#lines] = col + #icon + 1

      -- icon
      extmarks[#extmarks + 1] = { row = row, col = col, opts = { end_col = col + #icon, hl_group = icon_hl } }
      col = col + #icon + 1
      -- name
      extmarks[#extmarks + 1] = { row = row, col = col, opts = { end_col = col + #e.basename, hl_group = 'VVTrashName' } }
      -- path
      local path_start = name_end + 2
      extmarks[#extmarks + 1] = { row = row, col = path_start, opts = { end_col = path_start + #short_path, hl_group = 'VVTrashPath' } }
      -- date
      local date_start = path_start + #short_path + 2
      extmarks[#extmarks + 1] = { row = row, col = date_start, opts = { end_col = date_start + #date, hl_group = 'VVTrashDate' } }
      -- size
      local size_start = date_start + #date + 2
      extmarks[#extmarks + 1] = { row = row, col = size_start, opts = { end_col = size_start + #size, hl_group = 'VVTrashSize' } }
    end
  end

  -- 底栏
  lines[#lines + 1] = ''
  local footer = '  r/Enter restore  d delete  D clean all  q close'
  lines[#lines + 1] = footer
  extmarks[#extmarks + 1] = {
    row = #lines - 1, col = 0,
    opts = { end_col = #footer, hl_group = 'VVTrashFooter' },
  }

  -- 创建 buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, em in ipairs(extmarks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, em.row, em.col, em.opts)
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'

  -- 浮窗
  local width = math.min(80, vim.o.columns - 4)
  local height = math.min(#lines + 2, vim.o.lines - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' 󰆴 Trash ',
    title_pos = 'center',
  })
  require('vv-utils.ui_window').hide_chrome(win)

  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = buf,
    callback = function()
      if not vim.api.nvim_win_is_valid(win) then return end
      local cursor = vim.api.nvim_win_get_cursor(win)
      local target = name_cols[cursor[1]]
      if target and cursor[2] ~= target then
        vim.api.nvim_win_set_cursor(win, { cursor[1], target })
      end
    end,
  })

  -- 异步更新总大小到标题
  M.scan_size(function(bytes)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local new_title = '  Trash (' .. #entries .. ' items · ' .. format_size(bytes) .. ')'
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { new_title })
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, 1)
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, 0, 0, { end_col = #new_title, hl_group = 'VVTrashTitle' })
    vim.bo[buf].modifiable = false
  end)

  local function close() pcall(vim.api.nvim_win_close, win, true) end

  local function get_entry()
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local idx = entry_by_lnum[lnum]
    return idx and entries[idx] or nil
  end

  local function refresh()
    close()
    M.open_panel(state)
  end

  local map_opts = { buffer = buf, nowait = true, silent = true }

  vim.keymap.set('n', 'q', close, vim.tbl_extend('force', map_opts, { desc = 'vv-explorer: close trash' }))
  vim.keymap.set('n', '<Esc>', close, vim.tbl_extend('force', map_opts, { desc = 'vv-explorer: close trash' }))

  vim.keymap.set('n', 'r', function()
    local e = get_entry()
    if not e then return end
    local dest = M.restore(e)
    vim.notify('Restored: ' .. vim.fn.fnamemodify(dest, ':.'))
    refresh()
  end, vim.tbl_extend('force', map_opts, { desc = 'vv-explorer: restore from trash' }))

  vim.keymap.set('n', '<CR>', function()
    local e = get_entry()
    if not e then return end
    local dest = M.restore(e)
    vim.notify('Restored: ' .. vim.fn.fnamemodify(dest, ':.'))
    refresh()
  end, vim.tbl_extend('force', map_opts, { desc = 'vv-explorer: restore from trash' }))

  vim.keymap.set('n', 'd', function()
    local e = get_entry()
    if not e then return end
    local choice = vim.fn.confirm('Permanently delete ' .. e.basename .. ' ?', '&Yes\n&No', 2)
    if choice ~= 1 then return end
    M.delete_entry(e)
    vim.notify('Permanently deleted: ' .. e.basename)
    refresh()
  end, vim.tbl_extend('force', map_opts, { desc = 'vv-explorer: permanently delete' }))

  vim.keymap.set('n', 'D', function()
    local choice = vim.fn.confirm('Empty entire trash? This cannot be undone.', '&Yes\n&No', 2)
    if choice ~= 1 then return end
    M.empty()
    vim.notify('Trash emptied')
    refresh()
  end, vim.tbl_extend('force', map_opts, { desc = 'vv-explorer: empty trash' }))

  -- 光标初始位置：第一个条目的文件名列
  if #entries > 0 then
    pcall(vim.api.nvim_win_set_cursor, win, { 3, name_cols[3] or 0 })
  end
end

return M

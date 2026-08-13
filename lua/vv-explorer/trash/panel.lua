-- 回收站浮动面板

local M = {}

local Keys = require('vv-utils.keys')
local Confirm = require('vv-utils.confirm')
local UIWindow = require('vv-utils.ui_window')

local uv = vim.uv or vim.loop

local namespace = vim.api.nvim_create_namespace('vv-explorer.trash')

local function stat_snapshot(path)
  local ok, stat = pcall(uv.fs_lstat, path)
  if not ok or not stat then return nil end

  local mtime = stat.mtime or {}
  return {
    dev = stat.dev,
    ino = stat.ino,
    type = stat.type,
    mode = stat.mode,
    size = stat.size,
    mtime_sec = mtime.sec,
    mtime_nsec = mtime.nsec,
  }
end

local function same_stat(first, second)
  if not first or not second then return first == second end

  return first.dev == second.dev
    and first.ino == second.ino
    and first.type == second.type
    and first.mode == second.mode
    and first.size == second.size
    and first.mtime_sec == second.mtime_sec
    and first.mtime_nsec == second.mtime_nsec
end

local entry_fields = {
  'trash_name',
  'trash_path',
  'meta_path',
  'original_path',
  'trashed_at',
  'size_bytes',
  'basename',
}

local function entry_snapshot(entry)
  return {
    entry = vim.deepcopy(entry),
    trash_stat = stat_snapshot(entry.trash_path),
    meta_stat = stat_snapshot(entry.meta_path),
  }
end

local function same_entry(first, second)
  for _, field in ipairs(entry_fields) do
    if first[field] ~= second[field] then return false end
  end
  return true
end

local function same_entry_snapshot(snapshot, entry)
  return same_entry(snapshot.entry, entry)
    and same_stat(snapshot.trash_stat, stat_snapshot(entry.trash_path))
    and same_stat(snapshot.meta_stat, stat_snapshot(entry.meta_path))
end

local function find_live_entry(store, snapshot)
  for _, entry in ipairs(store:list()) do
    if same_entry_snapshot(snapshot, entry) then return entry end
  end
end

local function find_live_entries(store, snapshots)
  local entries = store:list()
  if #entries ~= #snapshots then return nil end

  local found = {}
  for _, snapshot in ipairs(snapshots) do
    local match
    for index, entry in ipairs(entries) do
      if not found[index] and same_entry_snapshot(snapshot, entry) then
        found[index] = true
        match = entry
        break
      end
    end
    if not match then return nil end
  end

  local live = {}
  for index, entry in ipairs(entries) do
    if found[index] then live[#live + 1] = entry end
  end
  return live
end

local function format_size(bytes)
  if not bytes or bytes < 0 then return '—' end
  if bytes < 1024 then return bytes .. ' B' end
  if bytes < 1024 * 1024 then return string.format('%.1f KB', bytes / 1024) end
  if bytes < 1024 * 1024 * 1024 then return string.format('%.1f MB', bytes / (1024 * 1024)) end
  return string.format('%.1f GB', bytes / (1024 * 1024 * 1024))
end

local footer = {
  { ' ' .. Keys.display('<CR>') .. '/r ', 'VVTrashFooterKey' },
  { 'Restore  ', 'VVTrashFooter' },
  { 'd ', 'VVTrashFooterKey' },
  { 'Delete  ', 'VVTrashFooter' },
  { Keys.display('<S-D>') .. ' ', 'VVTrashFooterKey' },
  { 'Empty  ', 'VVTrashFooter' },
  { 'q ', 'VVTrashFooterKey' },
  { 'Close ', 'VVTrashFooter' },
}

local function panel_title(count, bytes)
  local summary = tostring(count) .. (count == 1 and ' item' or ' items')
  if bytes then summary = summary .. ' · ' .. format_size(bytes) end
  return {
    { ' 󰆴 Trash ', 'VVTrashTitle' },
    { '· ' .. summary .. ' ', 'VVTrashFooter' },
  }
end

local function resolve_icon(basename)
  local mini_icons = _G.MiniIcons
  if mini_icons then
    local glyph, highlight = mini_icons.get('file', basename)
    if glyph then return glyph, highlight end
  end
  return '', 'VVTrashName'
end

function M.setup()
  require('vv-utils.hl').register('vv-explorer.trash.hl', {
    VVTrashTitle = { link = 'Title' },
    VVTrashName = { fg = '#c0caf5', bold = true },
    VVTrashPath = { link = 'Comment' },
    VVTrashDate = { fg = '#7aa2f7' },
    VVTrashSize = { fg = '#9ece6a' },
    VVTrashEmpty = { fg = '#565f89', italic = true },
    VVTrashFooter = { fg = '#565f89' },
    VVTrashFooterKey = { link = 'Special' },
  })
end

---@param store VVExplorerTrashStore
---@param state table?
function M.open(store, state)
  local entries = store:list()
  local lines = {}
  local extmarks = {}
  local entry_by_line = {}
  local name_columns = {}

  if #entries == 0 then
    local empty = '  Trash is empty'
    lines[#lines + 1] = empty
    extmarks[#extmarks + 1] = {
      row = 0,
      col = 0,
      opts = { end_col = #empty, hl_group = 'VVTrashEmpty' },
    }
  else
    for index, entry in ipairs(entries) do
      local icon, icon_highlight = resolve_icon(entry.basename)
      local date = os.date('%m-%d %H:%M', entry.trashed_at)
      local size = format_size(entry.size_bytes)
      local short_path = vim.fn.fnamemodify(entry.original_path, ':~:h')
      local prefix = '  '
      local column = #prefix
      local name_end = column + #icon + 1 + #entry.basename
      local info = '  ' .. short_path .. '  ' .. date .. '  ' .. size
      lines[#lines + 1] = table.concat({ prefix, icon, ' ', entry.basename, info })

      local row = #lines - 1
      entry_by_line[#lines] = index
      name_columns[#lines] = column + #icon + 1
      extmarks[#extmarks + 1] = {
        row = row,
        col = column,
        opts = { end_col = column + #icon, hl_group = icon_highlight },
      }

      column = column + #icon + 1
      extmarks[#extmarks + 1] = {
        row = row,
        col = column,
        opts = { end_col = column + #entry.basename, hl_group = 'VVTrashName' },
      }

      local path_start = name_end + 2
      extmarks[#extmarks + 1] = {
        row = row,
        col = path_start,
        opts = { end_col = path_start + #short_path, hl_group = 'VVTrashPath' },
      }

      local date_start = path_start + #short_path + 2
      extmarks[#extmarks + 1] = {
        row = row,
        col = date_start,
        opts = { end_col = date_start + #date, hl_group = 'VVTrashDate' },
      }

      local size_start = date_start + #date + 2
      extmarks[#extmarks + 1] = {
        row = row,
        col = size_start,
        opts = { end_col = size_start + #size, hl_group = 'VVTrashSize' },
      }
    end
  end

  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  for _, extmark in ipairs(extmarks) do
    pcall(vim.api.nvim_buf_set_extmark, buffer, namespace, extmark.row, extmark.col, extmark.opts)
  end
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].bufhidden = 'wipe'

  local view = UIWindow.open_float(buffer, {
    width = 80,
    height = #lines,
    border = 'rounded',
    title = panel_title(#entries),
    title_pos = 'center',
    footer = footer,
    footer_pos = 'center',
    chrome = { cursorline = #entries > 0 },
  })
  local window = view.win

  local confirm_handle
  local confirm_watch_ids = {}

  local function clear_confirmation()
    for _, id in ipairs(confirm_watch_ids) do
      pcall(vim.api.nvim_del_autocmd, id)
    end
    confirm_watch_ids = {}
    confirm_handle = nil
  end

  local function cancel_confirmation()
    if not confirm_handle then return end
    local handle = confirm_handle
    clear_confirmation()
    handle.close()
  end

  local function open_confirmation(opts)
    cancel_confirmation()

    local handle
    local finished = false
    local on_confirm = opts.on_confirm
    local on_cancel = opts.on_cancel
    opts.on_confirm = function()
      finished = true
      clear_confirmation()
      if on_confirm then on_confirm() end
    end
    opts.on_cancel = function()
      finished = true
      clear_confirmation()
      if on_cancel then on_cancel() end
    end

    handle = Confirm.open(opts)
    if not handle then return end
    if finished then
      handle.close()
      return handle
    end
    confirm_handle = handle

    local function cancel_if_pending()
      if confirm_handle ~= handle then return end
      cancel_confirmation()
    end

    confirm_watch_ids[#confirm_watch_ids + 1] = vim.api.nvim_create_autocmd('WinClosed', {
      pattern = tostring(window),
      once = true,
      callback = cancel_if_pending,
    })
    confirm_watch_ids[#confirm_watch_ids + 1] = vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = buffer,
      once = true,
      callback = cancel_if_pending,
    })
    return handle
  end

  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = buffer,
    callback = function()
      if not vim.api.nvim_win_is_valid(window) then return end

      local cursor = vim.api.nvim_win_get_cursor(window)
      local target = name_columns[cursor[1]]

      if target and cursor[2] ~= target then
        vim.api.nvim_win_set_cursor(window, { cursor[1], target })
      end
    end,
  })

  local size_scan = store:scan_size(function(bytes)
    if not vim.api.nvim_win_is_valid(window) then return end
    vim.api.nvim_win_set_config(window, {
      title = panel_title(#entries, bytes),
      title_pos = 'center',
    })
  end)

  -- 面板可以被 q / <Esc> / :q / 关窗等多条路径关掉，只在 close() 里取消会漏；
  -- buffer 是 bufhidden=wipe，BufWipeout 覆盖全部路径
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buffer,
    once = true,
    callback = function()
      cancel_confirmation()
      size_scan.cancel()
    end,
    desc = 'vv-explorer: cancel trash size scan',
  })

  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(window),
    once = true,
    callback = cancel_confirmation,
    desc = 'vv-explorer: cancel trash confirmation',
  })

  local function close()
    view.close()
  end

  local function current_entry()
    local line = vim.api.nvim_win_get_cursor(window)[1]
    local index = entry_by_line[line]
    return index and entries[index] or nil
  end

  local function refresh()
    close()
    M.open(store, state)
  end

  local mapping_options = { buffer = buffer, nowait = true, silent = true }
  vim.keymap.set('n', 'q', close, vim.tbl_extend('force', mapping_options, {
    desc = 'vv-explorer: close trash',
  }))
  vim.keymap.set('n', '<Esc>', close, vim.tbl_extend('force', mapping_options, {
    desc = 'vv-explorer: close trash',
  }))

  local function restore()
    local entry = current_entry()
    if not entry then return end
    local ok, destination = pcall(store.restore, store, entry)
    if not ok then
      vim.notify(tostring(destination), vim.log.levels.WARN)
      return
    end
    vim.notify('Restored: ' .. vim.fn.fnamemodify(destination, ':.'))
    refresh()
  end

  vim.keymap.set('n', 'r', restore, vim.tbl_extend('force', mapping_options, {
    desc = 'vv-explorer: restore from trash',
  }))
  vim.keymap.set('n', '<CR>', restore, vim.tbl_extend('force', mapping_options, {
    desc = 'vv-explorer: restore from trash',
  }))

  vim.keymap.set('n', 'd', function()
    local entry = current_entry()
    if not entry then return end

    local snapshot = entry_snapshot(entry)
    open_confirmation({
      title = 'Permanently delete?',
      details = { { label = 'File', value = entry.basename } },
      severity = 'danger',
      confirm_label = 'Delete',
      on_confirm = function()
        local live = find_live_entry(store, snapshot)
        if not live then
          vim.notify('vv-explorer: permanent delete cancelled: trash entry changed while confirmation was open', vim.log.levels.WARN)
          return
        end

        local ok, err = pcall(store.delete_entry, store, live)
        if not ok then
          vim.notify('vv-explorer: permanent delete failed: ' .. tostring(err), vim.log.levels.ERROR)
          return
        end
        vim.notify('Permanently deleted: ' .. live.basename)
        refresh()
      end,
    })
  end, vim.tbl_extend('force', mapping_options, {
    desc = 'vv-explorer: permanently delete',
  }))

  vim.keymap.set('n', 'D', function()
    local snapshots = vim.tbl_map(entry_snapshot, entries)
    open_confirmation({
      title = 'Empty entire trash?',
      message = 'This cannot be undone.',
      severity = 'danger',
      confirm_label = 'Empty',
      on_confirm = function()
        local live_entries = find_live_entries(store, snapshots)
        if not live_entries then
          vim.notify('vv-explorer: empty trash cancelled: trash entries changed while confirmation was open', vim.log.levels.WARN)
          return
        end

        local failed = {}
        for _, entry in ipairs(live_entries) do
          local ok, err = pcall(store.delete_entry, store, entry)
          if not ok then failed[#failed + 1] = tostring(err) end
        end
        if #failed > 0 then
          vim.notify('vv-explorer: empty trash errors:\n' .. table.concat(failed, '\n'), vim.log.levels.ERROR)
        end
        vim.notify('Trash emptied')
        refresh()
      end,
    })
  end, vim.tbl_extend('force', mapping_options, {
    desc = 'vv-explorer: empty trash',
  }))

  if #entries > 0 then
    pcall(vim.api.nvim_win_set_cursor, window, { 1, name_columns[1] or 0 })
  end
end

return M

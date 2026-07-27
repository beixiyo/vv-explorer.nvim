-- 回收站浮动面板

local M = {}

local namespace = vim.api.nvim_create_namespace('vv-explorer.trash')

local function format_size(bytes)
  if not bytes or bytes < 0 then return '—' end
  if bytes < 1024 then return bytes .. ' B' end
  if bytes < 1024 * 1024 then return string.format('%.1f KB', bytes / 1024) end
  if bytes < 1024 * 1024 * 1024 then return string.format('%.1f MB', bytes / (1024 * 1024)) end
  return string.format('%.1f GB', bytes / (1024 * 1024 * 1024))
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
    VVTrashSep = { fg = '#3b4261' },
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

  local title = '  Trash (' .. #entries .. ' items)'
  lines[#lines + 1] = title
  extmarks[#extmarks + 1] = {
    row = 0,
    col = 0,
    opts = { end_col = #title, hl_group = 'VVTrashTitle' },
  }

  local separator = string.rep('─', 56)
  lines[#lines + 1] = separator
  extmarks[#extmarks + 1] = {
    row = 1,
    col = 0,
    opts = { end_col = #separator, hl_group = 'VVTrashSep' },
  }

  if #entries == 0 then
    local empty = '  Trash is empty'
    lines[#lines + 1] = empty
    extmarks[#extmarks + 1] = {
      row = 2,
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

  lines[#lines + 1] = ''
  local footer = '  Restore r/↵  Delete d  Clean all ⇧D  Close q'
  lines[#lines + 1] = footer
  extmarks[#extmarks + 1] = {
    row = #lines - 1,
    col = 0,
    opts = { end_col = #footer, hl_group = 'VVTrashFooter' },
  }

  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  for _, extmark in ipairs(extmarks) do
    pcall(vim.api.nvim_buf_set_extmark, buffer, namespace, extmark.row, extmark.col, extmark.opts)
  end
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].bufhidden = 'wipe'

  local width = math.min(80, vim.o.columns - 4)
  local height = math.min(#lines + 2, vim.o.lines - 4)
  local window = assert(vim.api.nvim_open_win(buffer, true, {
    relative = 'editor',
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' 󰆴 Trash ',
    title_pos = 'center',
  }))
  require('vv-utils.ui_window').hide_chrome(window)

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

  store:scan_size(function(bytes)
    if not vim.api.nvim_buf_is_valid(buffer) then return end
    local updated_title = '  Trash (' .. #entries .. ' items · ' .. format_size(bytes) .. ')'
    vim.bo[buffer].modifiable = true
    vim.api.nvim_buf_set_lines(buffer, 0, 1, false, { updated_title })
    vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, 1)
    pcall(vim.api.nvim_buf_set_extmark, buffer, namespace, 0, 0, {
      end_col = #updated_title,
      hl_group = 'VVTrashTitle',
    })
    vim.bo[buffer].modifiable = false
  end)

  local function close()
    pcall(vim.api.nvim_win_close, window, true)
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
    local choice = vim.fn.confirm('Permanently delete ' .. entry.basename .. ' ?', '&Yes\n&No', 2)
    if choice ~= 1 then return end
    store:delete_entry(entry)
    vim.notify('Permanently deleted: ' .. entry.basename)
    refresh()
  end, vim.tbl_extend('force', mapping_options, {
    desc = 'vv-explorer: permanently delete',
  }))

  vim.keymap.set('n', 'D', function()
    local choice = vim.fn.confirm('Empty entire trash? This cannot be undone.', '&Yes\n&No', 2)
    if choice ~= 1 then return end
    store:empty()
    vim.notify('Trash emptied')
    refresh()
  end, vim.tbl_extend('force', mapping_options, {
    desc = 'vv-explorer: empty trash',
  }))

  if #entries > 0 then
    pcall(vim.api.nvim_win_set_cursor, window, { 3, name_columns[3] or 0 })
  end
end

return M

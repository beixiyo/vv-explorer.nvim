-- ? 键浮窗：委托给 vv-utils.help_panel
-- action 分类/图标、title 等 vv-explorer 特有的数据在这里维护
-- filter prompt 的快捷键通过 extra_rows 注入（它们绑在浮窗 buf 上，不在 source_buf 的 keymap 里）

local HelpPanel = require('vv-utils.help_panel')
local VVIcons = require('vv-icons')
local Icons = VVIcons.ns
local RawIcons = VVIcons.raw

local GitIcons = Icons.git
local UIIcons = Icons.ui

local M = {}

-- action → { category, icon }；未登记自动归入 'Other'
local ACTIONS = {
  open              = { cat = 'Navigate',  icon = UIIcons.folder_open },
  close_node        = { cat = 'Navigate',  icon = UIIcons.folder },
  cd_to             = { cat = 'Navigate',  icon = UIIcons.folder_open },
  cd_up             = { cat = 'Navigate',  icon = UIIcons.arrow_up },
  toggle_hidden     = { cat = 'View',      icon = '' },
  toggle_gitignored = { cat = 'View',      icon = GitIcons.git_status },
  refresh           = { cat = 'View',      icon = '' },
  scan_directory    = { cat = 'View',      icon = '' },
  help              = { cat = 'View',      icon = UIIcons.keymaps },
  open_split        = { cat = 'Open as',   icon = UIIcons.split_horizontal },
  open_vsplit       = { cat = 'Open as',   icon = UIIcons.split_vertical },
  system_open       = { cat = 'Open as',   icon = UIIcons.window },
  execute           = { cat = 'Open as',   icon = '󰐊' },
  yank_abs_path     = { cat = 'Yank',      icon = UIIcons.copy },
  create            = { cat = 'Modify',    icon = UIIcons.new_file },
  delete            = { cat = 'Modify',    icon = '' },
  rename            = { cat = 'Modify',    icon = UIIcons.rename },
  copy_mark         = { cat = 'Clipboard', icon = UIIcons.clipboard_copy },
  cut_mark          = { cat = 'Clipboard', icon = UIIcons.clipboard_cut },
  paste             = { cat = 'Clipboard', icon = '' },
  trash_panel       = { cat = 'Modify',    icon = '󰆴' },
  toggle_select     = { cat = 'Select',    icon = UIIcons.list },
  escape            = { cat = 'Select',    icon = UIIcons.quit },
  __close           = { cat = 'Select',    icon = UIIcons.quit },
  __quit            = { cat = 'Select',    icon = UIIcons.quit },
  start_filter      = { cat = 'Filter',    icon = UIIcons.find_text },
}

-- glyph 走扁平 namespace，颜色走同一 vv-icons entry 的语义高亮；没有共享 entry 的
-- execute / trash 继续使用 help_panel 默认色，不在业务层硬编码颜色
local ACTION_ICON_ENTRIES = {
  open = RawIcons.ui.folder_open,
  close_node = RawIcons.ui.folder,
  cd_to = RawIcons.ui.folder_open,
  cd_up = RawIcons.ui.arrow_up,
  toggle_gitignored = RawIcons.git.git_status,
  help = RawIcons.ui.keymaps,
  open_split = RawIcons.ui.split_horizontal,
  open_vsplit = RawIcons.ui.split_vertical,
  system_open = RawIcons.ui.window,
  yank_abs_path = RawIcons.ui.copy,
  create = RawIcons.ui.new_file,
  rename = RawIcons.ui.rename,
  copy_mark = RawIcons.ui.clipboard_copy,
  cut_mark = RawIcons.ui.clipboard_cut,
  toggle_select = RawIcons.ui.list,
  escape = RawIcons.ui.quit,
  __close = RawIcons.ui.quit,
  __quit = RawIcons.ui.quit,
  start_filter = RawIcons.ui.find_text,
}

for action, entry in pairs(ACTION_ICON_ENTRIES) do ACTIONS[action].icon_hl = entry.hl end
ACTIONS.toggle_gitignored.icon_hl = RawIcons.git.git_removed.hl

local CATEGORIES = {
  'Navigate', 'View', 'Open as', 'Yank',
  'Modify', 'Clipboard', 'Select', 'Filter',
  'Filter prompt',
}

-- filter prompt 内的键位（绑在浮窗 buf 上，help_panel 反读不到 source_buf 拿不到，
-- 走 extra_rows 静态注入）
local FILTER_PROMPT_ROWS = {
  { cat = 'Filter prompt', lhs = '<S-Tab>', action = 'cycle search mode (fuzzy/glob/regex)', icon = UIIcons.regex },
  { cat = 'Filter prompt', lhs = '<C-n>',   action = 'next match',                            icon = UIIcons.next },
  { cat = 'Filter prompt', lhs = '<C-p>',   action = 'prev match',                            icon = UIIcons.prev },
  { cat = 'Filter prompt', lhs = '<C-x>',   action = 'open match in horizontal split',        icon = UIIcons.split_horizontal },
  { cat = 'Filter prompt', lhs = '<C-v>',   action = 'open match in vertical split',          icon = UIIcons.split_vertical },
  { cat = 'Filter prompt', lhs = '<CR>',    action = 'submit (jump to first match)',          icon = UIIcons.arrow_right },
  { cat = 'Filter prompt', lhs = '<Esc>',   action = 'cancel filter',                         icon = UIIcons.quit },
  { cat = 'Filter prompt', lhs = 'q',       action = 'cancel filter',                         icon = UIIcons.quit },
}

local FILTER_ICON_ENTRIES = {
  RawIcons.ui.regex,
  RawIcons.ui.next,
  RawIcons.ui.prev,
  RawIcons.ui.split_horizontal,
  RawIcons.ui.split_vertical,
  RawIcons.ui.arrow_right,
  RawIcons.ui.quit,
  RawIcons.ui.quit,
}

for index, entry in ipairs(FILTER_ICON_ENTRIES) do FILTER_PROMPT_ROWS[index].icon_hl = entry.hl end

---@param state table
function M.open(state)
  HelpPanel.open({
    source_buf  = state.buf,
    desc_prefix = 'vv-explorer: ',
    actions     = ACTIONS,
    categories  = CATEGORIES,
    title       = 'vv-explorer keymaps',
    title_icon  = UIIcons.explorer,
    title_icon_hl = RawIcons.ui.explorer.hl,
    filetype    = 'vv-explorer-help',
    extra_rows  = FILTER_PROMPT_ROWS,
  })
end

return M

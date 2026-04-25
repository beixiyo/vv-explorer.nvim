-- ? 键浮窗：委托给 vv-utils.help_panel
-- action 分类/图标、title 等 vv-explorer 特有的数据在这里维护
-- filter prompt 的快捷键通过 extra_rows 注入（它们绑在浮窗 buf 上，不在 source_buf 的 keymap 里）

local HelpPanel = require('vv-utils.help_panel')

local M = {}

-- action → { category, icon }；未登记自动归入 'Other'
local ACTIONS = {
  open              = { cat = 'Navigate',  icon = '' },
  close_node        = { cat = 'Navigate',  icon = '' },
  cd_to             = { cat = 'Navigate',  icon = '' },
  cd_up             = { cat = 'Navigate',  icon = '' },
  toggle_hidden     = { cat = 'View',      icon = '' },
  toggle_gitignored = { cat = 'View',      icon = '' },
  refresh           = { cat = 'View',      icon = '' },
  help              = { cat = 'View',      icon = '' },
  open_split        = { cat = 'Open as',   icon = '' },
  open_vsplit       = { cat = 'Open as',   icon = '' },
  open_tab          = { cat = 'Open as',   icon = '󰓩' },
  system_open       = { cat = 'Open as',   icon = '' },
  yank_abs_path     = { cat = 'Yank',      icon = '' },
  create            = { cat = 'Modify',    icon = '' },
  delete            = { cat = 'Modify',    icon = '' },
  rename            = { cat = 'Modify',    icon = '' },
  copy_mark         = { cat = 'Clipboard', icon = '' },
  cut_mark          = { cat = 'Clipboard', icon = '' },
  paste             = { cat = 'Clipboard', icon = '' },
  toggle_select     = { cat = 'Select',    icon = '' },
  escape            = { cat = 'Select',    icon = '' },
  __close           = { cat = 'Select',    icon = '' },
  __quit            = { cat = 'Select',    icon = '' },
  start_filter      = { cat = 'Filter',    icon = '' },
}

local CATEGORIES = {
  'Navigate', 'View', 'Open as', 'Yank',
  'Modify', 'Clipboard', 'Select', 'Filter',
  'Filter prompt',
}

-- filter prompt 内的键位（绑在浮窗 buf 上，help_panel 反读不到 source_buf 拿不到，
-- 走 extra_rows 静态注入）
local FILTER_PROMPT_ROWS = {
  { cat = 'Filter prompt', lhs = '<S-Tab>', action = 'cycle search mode (fuzzy/glob/regex)', icon = '' },
  { cat = 'Filter prompt', lhs = '<C-n>',   action = 'next match',                            icon = '' },
  { cat = 'Filter prompt', lhs = '<C-p>',   action = 'prev match',                            icon = '' },
  { cat = 'Filter prompt', lhs = '<C-x>',   action = 'open match in horizontal split',        icon = '' },
  { cat = 'Filter prompt', lhs = '<C-v>',   action = 'open match in vertical split',          icon = '' },
  { cat = 'Filter prompt', lhs = '<CR>',    action = 'submit (jump to first match)',          icon = '' },
  { cat = 'Filter prompt', lhs = '<Esc>',   action = 'cancel filter',                         icon = '' },
  { cat = 'Filter prompt', lhs = 'q',       action = 'cancel filter',                         icon = '' },
}

---@param state table
function M.open(state)
  HelpPanel.open({
    source_buf  = state.buf,
    desc_prefix = 'vv-explorer: ',
    actions     = ACTIONS,
    categories  = CATEGORIES,
    title       = 'vv-explorer keymaps',
    title_icon  = '',
    filetype    = 'vv-explorer-help',
    extra_rows  = FILTER_PROMPT_ROWS,
  })
end

return M

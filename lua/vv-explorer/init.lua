-- vv-explorer.nvim public facade
--
-- Public API:
--   require('vv-explorer').setup(opts)
--   require('vv-explorer').open({ cwd?, focus? })
--   require('vv-explorer').close()
--   require('vv-explorer').suspend()
--   require('vv-explorer').toggle({ cwd? })
--   require('vv-explorer').reveal({ file? })
--   require('vv-explorer').focus()
--   require('vv-explorer').get_node_path()

local Config = require('vv-explorer.config')
local Icons = require('vv-explorer.icons')
local Panel = require('vv-explorer.panel')
local Preview = require('vv-explorer.preview')

local M = {}

local function register_highlights()
  require('vv-utils.git').register_hl()

  require('vv-utils.hl').register('vv-explorer.hl', {
    VVExplorerIndent = { link = 'Comment' },
    VVExplorerDir = { link = 'Directory' },
    VVExplorerFile = { link = 'Normal' },
    VVExplorerRoot = { link = 'Title' },
    VVExplorerSelected = { link = 'Visual' },
    VVExplorerDropTarget = { bg = '#264f78' },
    VVExplorerDim = { link = 'Comment' },
    VVExplorerMatch = { bg = '#193d4c', bold = true },
    VVExplorerFilterModeFuzzy = { fg = '#7dcfff', bold = true },
    VVExplorerFilterModeGlob = { fg = '#e0af68', bold = true },
    VVExplorerFilterModeRegex = { fg = '#ff6ac1', bold = true },
  })
end

local function register_commands()
  vim.api.nvim_create_user_command('VVExplorerToggle', Panel.toggle, { force = true })
  vim.api.nvim_create_user_command('VVExplorerOpen', Panel.open, { force = true })
  vim.api.nvim_create_user_command('VVExplorerClose', Panel.close, { force = true })
  vim.api.nvim_create_user_command('VVExplorerReveal', Panel.reveal, { force = true })
  vim.api.nvim_create_user_command('VVExplorerFocus', Panel.focus, { force = true })
  vim.api.nvim_create_user_command('VVExplorerTrash', Panel.open_trash, {
    force = true,
    desc = 'vv-explorer: open trash panel',
  })
  vim.api.nvim_create_user_command('VVExplorerExecute', Panel.execute, {
    force = true,
    desc = 'vv-explorer: execute file under cursor',
  })
end

---@param mappings VVExplorerGlobalMappings|false
local function register_global_mappings(mappings)
  if not mappings then return end
  if mappings.toggle then
    vim.keymap.set('n', mappings.toggle, '<cmd>VVExplorerToggle<cr>', {
      desc = 'vv-explorer: toggle',
      silent = true,
    })
  end
  if mappings.reveal then
    vim.keymap.set('n', mappings.reveal, '<cmd>VVExplorerReveal<cr>', {
      desc = 'vv-explorer: reveal current file',
      silent = true,
    })
  end
end

---@param opts VVExplorerConfig?
function M.setup(opts)
  local config = Config.resolve(opts)

  Icons.compile(config.icon_rules)
  register_highlights()
  Preview.setup_editor_history()
  register_commands()
  register_global_mappings(config.global_mappings)
  Panel.setup(config)
end

M.is_open = Panel.is_open
M.open = Panel.open
M.close = Panel.close
M.suspend = Panel.suspend
M.toggle = Panel.toggle
M.reveal = Panel.reveal
M.focus = Panel.focus
M.get_node_path = Panel.get_node_path

return M

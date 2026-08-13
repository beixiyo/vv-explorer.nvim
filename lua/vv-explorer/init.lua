-- vv-explorer.nvim 公共 facade
--
-- 公共 API：
--   require('vv-explorer').setup(opts)
--   require('vv-explorer').open({ cwd?, focus? })
--   require('vv-explorer').close()
--   require('vv-explorer').suspend({ focus? })
--   require('vv-explorer').toggle({ cwd? })
--   require('vv-explorer').reveal({ file? })
--   require('vv-explorer').focus()
--   require('vv-explorer').get_node_path()
--   require('vv-explorer').get_target_paths()

local Config = require('vv-explorer.config')
local Icons = require('vv-explorer.icons')
local Panel = require('vv-explorer.panel')
local MainWin = require('vv-explorer.preview.main_win')

local M = {}

local owned_global_mappings = {}

---@param lhs string
---@return table?
local function get_global_mapping(lhs)
  local target = vim.fn.keytrans(vim.keycode(lhs))
  for _, mapping in ipairs(vim.api.nvim_get_keymap('n')) do
    if vim.fn.keytrans(vim.keycode(mapping.lhs)) == target then return mapping end
  end
end

---@param lhs string
---@param mapping table?
local function restore_global_mapping(lhs, mapping)
  if not mapping then
    pcall(vim.api.nvim_del_keymap, 'n', lhs)
    return
  end

  local opts = {
    noremap = mapping.noremap == 1,
    silent = mapping.silent == 1,
    expr = mapping.expr == 1,
    nowait = mapping.nowait == 1,
    script = mapping.script == 1,
    desc = mapping.desc,
    replace_keycodes = mapping.replace_keycodes == 1,
  }
  if mapping.callback then opts.callback = mapping.callback end
  vim.api.nvim_set_keymap('n', lhs, mapping.rhs or '', opts)
end

local function clear_global_mappings()
  for lhs, owned in pairs(owned_global_mappings) do
    local current = get_global_mapping(lhs)
    if current
        and current.callback == owned.callback
        and current.desc == owned.desc
    then
      restore_global_mapping(lhs, owned.previous)
    end
  end
  owned_global_mappings = {}
end

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
    VVExplorerExecuteTitle = { link = 'Title' },
    VVExplorerExecuteLabel = { link = 'Comment' },
    VVExplorerExecutePath = { link = 'Directory' },
    VVExplorerExecuteCommand = { link = 'String' },
    VVExplorerExecuteRun = { link = 'DiagnosticOk', bold = true },
    VVExplorerExecuteCancel = { link = 'Comment' },
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
  clear_global_mappings()
  if not mappings then return end

  local definitions = {
    {
      lhs = mappings.toggle,
      callback = function() Panel.toggle() end,
      desc = 'vv-explorer: toggle',
    },
    {
      lhs = mappings.reveal,
      callback = function() Panel.reveal() end,
      desc = 'vv-explorer: reveal current file',
    },
  }

  for _, definition in ipairs(definitions) do
    if definition.lhs then
      local previous = owned_global_mappings[definition.lhs]
          and owned_global_mappings[definition.lhs].previous
          or get_global_mapping(definition.lhs)
      vim.keymap.set('n', definition.lhs, definition.callback, {
        desc = definition.desc,
        silent = true,
      })

      owned_global_mappings[definition.lhs] = {
        callback = definition.callback,
        desc = definition.desc,
        previous = previous,
      }
    end
  end
end

---@param opts VVExplorerConfig?
function M.setup(opts)
  local config = Config.resolve(opts)

  Icons.compile(config.icon_rules)
  register_highlights()
  MainWin.setup_editor_history()
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
M.get_target_paths = Panel.get_target_paths

return M

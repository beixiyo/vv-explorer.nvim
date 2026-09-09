-- 粘贴冲突对话框：声明英文内容与固定动作，文件操作由调用方决定

local Modal = require('vv-utils.modal')

local M = {}

---@param plan VVExplorerTransferPlan
---@param opts {on_select:fun(policy:'overwrite'|'increment'), on_cancel?:fun()}
---@return VVModalHandle
function M.open(plan, opts)
  local destinations = {}
  for _, entry in ipairs(plan.entries) do
    if entry.conflict then destinations[#destinations + 1] = entry.destination end
  end

  local body = {
    {
      text = #destinations == 1
          and 'The destination already exists.'
          or ('%d destinations already exist.'):format(#destinations),
    },
    '',
  }
  local visible = math.min(#destinations, 10)
  for index = 1, visible do
    body[#body + 1] = {
      chunks = {
        { 'Destination  ', 'Comment' },
        { vim.fn.fnamemodify(destinations[index], ':~'), 'Directory' },
      },
    }
  end
  if #destinations > visible then
    body[#body + 1] = { text = ('... and %d more'):format(#destinations - visible), hl = 'Comment' }
  end
  body[#body + 1] = ''
  body[#body + 1] = {
    text = 'Overwrite replaces each existing item completely.',
    hl = 'DiagnosticWarn',
  }

  return Modal.open({
    title = 'Paste Conflict',
    body = body,
    actions = {
      {
        id = 'overwrite',
        label = #destinations == 1 and 'Overwrite' or 'Overwrite All',
        keys = '<C-o>',
        hl = 'DiagnosticError',
      },
      {
        id = 'increment',
        label = 'Keep Both',
        keys = '<C-k>',
        hl = 'DiagnosticOk',
      },
    },
    cancel = {
      label = 'Cancel',
      keys = { 'q', '<Esc>' },
    },
    on_select = opts.on_select,
    on_cancel = opts.on_cancel,
  })
end

return M

-- Explorer 执行确认适配：UI 由 vv-utils.exec.confirm 统一提供

local Confirm = require('vv-utils.exec.confirm')

local M = {}

---@param path string
---@param cwd string?
---@param command string[]
---@param on_confirm fun()
---@param opts? { target?: 'file'|'project', on_cancel?: fun() }
function M.open(path, cwd, command, on_confirm, opts)
  return Confirm.open({
    path = path,
    cwd = cwd,
    cmd = command,
    target = opts and opts.target or 'project',
    on_confirm = on_confirm,
    on_cancel = opts and opts.on_cancel,
    notify_prefix = 'vv-explorer',
  })
end

return M

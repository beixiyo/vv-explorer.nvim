-- 独立事务夹具，只初始化源和目标，不执行传输。
return function()
  -- 文件传输集成：递增保留、完整覆盖、快照复验与 cut 语义


  local Transfer = require('vv-explorer.actions.transfer')

  -- 夹具路径必须与生产 realpath 一致。
  local temporary = vim.fn.tempname()
  assert(vim.fn.mkdir(temporary, 'p') == 1)
  temporary = assert(vim.uv.fs_realpath(temporary))
  local sources = temporary .. '/sources'
  local destination = temporary .. '/destination'
  assert(vim.fn.mkdir(sources .. '/widget', 'p') == 1)
  assert(vim.fn.mkdir(destination .. '/widget', 'p') == 1)
  vim.fn.writefile({ 'new' }, sources .. '/widget/shared.txt')
  vim.fn.writefile({ 'source-only' }, sources .. '/widget/source-only.txt')
  vim.fn.writefile({ 'old' }, destination .. '/widget/shared.txt')
  vim.fn.writefile({ 'destination-only' }, destination .. '/widget/destination-only.txt')

  local Fs = require('vv-utils.fs')
  local function read_tree(path)
    local entries = {}
    local function visit(directory, relative)
      local scan = assert(vim.uv.fs_scandir(directory))
      while true do
        local name = vim.uv.fs_scandir_next(scan)
        if not name then break end
        local full = vim.fs.joinpath(directory, name)
        local key = relative == '' and name or relative .. '/' .. name
        local kind = assert(vim.uv.fs_lstat(full)).type
        if kind == 'directory' then
          entries[key] = { kind = kind }
          visit(full, key)
        elseif kind == 'link' then
          entries[key] = { kind = kind, target = assert(vim.uv.fs_readlink(full)) }
        else
          local file = assert(io.open(full, 'rb'))
          entries[key] = { kind = kind, bytes = file:read('*a') }
          assert(file:close())
        end
      end
    end
    visit(path, '')
    return entries
  end
  return { read_tree = read_tree, Transfer = Transfer, Fs = Fs, temporary = temporary, sources = sources, destination = destination }
end

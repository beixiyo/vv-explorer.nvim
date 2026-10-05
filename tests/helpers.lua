-- 每个具名场景使用全新 Neovim；父 hook 无论断言成功与否都回收进程与 /tmp 夹具
local M = {}

function M.setup_child()
  local timers, processes, async_errors = {}, {}, {}
  local sequence = 0
  vim.fn.tempname = function()
    sequence = sequence + 1
    return vim.env.VV_TEST_TMP .. '/fixture-' .. sequence
  end
  local function guarded(callback)
    return function(...)
      local ok, err = pcall(callback, ...)
      if not ok then
        async_errors[#async_errors + 1] = tostring(err)
      end
    end
  end
  local schedule = vim.schedule
  vim.schedule = function(callback)
    schedule(guarded(callback))
  end
  vim.schedule_wrap = function(callback)
    return function(...)
      local args, count = { ... }, select('#', ...)
      vim.schedule(function() callback(unpack(args, 1, count)) end)
    end
  end
  local new_timer = vim.uv.new_timer
  vim.uv.new_timer = function()
    local timer = new_timer()
    timers[#timers + 1] = timer
    return timer
  end
  local system = vim.system
  vim.system = function(...)
    local process = system(...)
    processes[#processes + 1] = process
    return process
  end
  M.async_errors = async_errors
  M.allowed_errmsg = {}
  M.cleanup = function()
    -- 清理某个 owning 模块失败也不能阻止其他资源释放；清理错误仍令 case 失败
    local cleanup_errors = {}
    local function release(fn)
      local ok, err = pcall(fn)
      if not ok then
        cleanup_errors[#cleanup_errors + 1] = tostring(err)
      end
    end
    for _, name in ipairs({ 'vv-explorer', 'vv-flow', 'vv-task-panel', 'vv-translate' }) do
      local plugin = package.loaded[name]
      if type(plugin) == 'table' then
        if plugin.close then
          release(plugin.close)
        end
        if plugin.disable then
          release(plugin.disable)
        end
      end
    end
    for _, process in ipairs(processes) do
      release(function()
        if not process:is_closing() then
          process:kill(9);
          process:wait(5000)
        end
      end)
    end
    for _, timer in ipairs(timers) do
      release(function()
        if timer and not timer:is_closing() then
          timer:stop();
          timer:close()
        end
      end)
    end
    assert(#cleanup_errors == 0, '资源释放失败：' .. vim.inspect(cleanup_errors))
  end
end

function M.new_set()
  local MiniTest = require('mini.test')
  local child = MiniTest.new_child_neovim()
  local root
  local T = MiniTest.new_set({
    hooks = {
      pre_case = function()
        -- 共享 scratch 已含 macOS 临时根，短 case 名避免 RPC socket 超过系统上限
        root = assert(vim.uv.fs_mkdtemp(assert(vim.env.TMPDIR) .. '/cXXXXXX'))
        root = assert(vim.uv.fs_realpath(root))
        -- mini.test 固定版 start 不接收 env/cwd；只在启动期间修改父进程，失败也立即还原
        local environment = { HOME = root .. '/home', TMPDIR = root .. '/tmp', VV_TEST_TMP = root }
        for _, kind in ipairs({ 'CONFIG', 'DATA', 'STATE', 'CACHE' }) do
          environment['XDG_' .. kind .. '_HOME'] = root .. '/' .. kind:lower()
        end
        if vim.env.VV_TEST_TOOLCHAIN_BIN then
          environment.PATH = vim.env.VV_TEST_TOOLCHAIN_BIN .. ':' .. vim.env.PATH
        end
        local previous, cwd, tempname = {}, vim.fn.getcwd(), vim.fn.tempname
        for key, value in pairs(environment) do
          previous[key] = vim.env[key]
          vim.env[key] = value
        end
        vim.fn.mkdir(environment.HOME, 'p')
        vim.fn.mkdir(environment.TMPDIR, 'p')
        local started, start_error = pcall(function()
          vim.cmd.cd(vim.fn.fnameescape(root))
          vim.fn.tempname = function()
            return root .. '/child.sock'
          end
          child.start({ '-u', 'NONE', '-i', 'NONE', '-n' }, { nvim_executable = vim.v.progpath })
        end)
        vim.fn.tempname = tempname
        vim.cmd.cd(vim.fn.fnameescape(cwd))
        for key in pairs(environment) do
          vim.env[key] = previous[key]
        end
        assert(started, start_error)
        child.lua([=[
        assert(vim.fn.getcwd() == vim.env.VV_TEST_TMP, '子进程 cwd 必须位于本 case 夹具目录')
        assert(vim.env.HOME == vim.env.VV_TEST_TMP .. '/home', '子进程 HOME 必须隔离')
        vim.opt.packpath = ''
        dofile(vim.env.VV_UTILS .. '/dev/test/runtime.lua').apply()
        vim.opt.runtimepath:prepend(vim.env.VV_TEST_REPO)
        vim.opt.runtimepath:prepend(vim.env.VV_UTILS)
        for _, name in ipairs({ 'VV_ICONS', 'VV_BUFFERLINE' }) do
          vim.opt.runtimepath:append(assert(vim.env[name]))
        end
        Helpers = dofile(vim.env.VV_TEST_REPO .. '/tests/helpers.lua')
        Helpers.setup_child()
      ]=])
        child.v.errmsg = ''
      end,
      post_case = function()
        local ok, err = pcall(function()
          child.lua('Helpers.cleanup()')
          local errors = child.lua_get('Helpers.async_errors')
          assert(#errors == 0, '异步回调抛错：' .. vim.inspect(errors))
          local message = child.v.errmsg
          local allowed = child.lua_get('Helpers.allowed_errmsg')
          assert(message == '' or vim.tbl_contains(allowed, message), '未预期的 Neovim 错误：' .. vim.inspect({ message = message, allowed = allowed }))
        end)
        local stopped, stop_error = pcall(child.stop)
        if root then
          -- 夹具会制造不可写目录；父进程恢复权限，不依赖用例尾部清理
          local result = vim.system({ 'chmod', '-R', 'u+rwX', root }):wait()
          local removed = vim.fn.delete(root, 'rf')
          assert(result.code == 0 and removed == 0, '夹具权限恢复或删除失败：' .. root)
        end
        assert(stopped, stop_error)
        assert(ok, err)
      end,
    },
  })
  return T, child
end

return M

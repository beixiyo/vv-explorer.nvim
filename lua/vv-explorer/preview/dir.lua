-- 目录属性预览：浅层信息同步给出，总大小与文件数交给分片递归异步补算
--
-- 递归统计的成本与目录下的 inode 总数成正比，因此它必须满足三件事：
--   ① 不阻塞主窗：走 vv-utils.fs.scan_dir 的分片扫描，单片占用受 budget_ms 限制
--   ② 光标一移开就物理取消：经 vv-utils.async scope 的 latest-wins 传导到 scan handle
--   ③ 跑完的结果进缓存，直到文件系统发生变化（由 watch 调 invalidate_cache 作废）

local Fs = require('vv-utils.fs')
local InfoBuf = require('vv-explorer.preview.info_buf')
local MainWin = require('vv-explorer.preview.main_win')
local Mount = require('vv-explorer.preview.mount')

local M = {}

-- state -> vv-utils.async scope，负责目录统计的 latest-wins 与物理取消
M.scope = setmetatable({}, { __mode = 'k' })

-- state -> { [abs] = VVFsDirScanResult }。只缓存跑完的结果，取消掉的部分结果不进缓存
M.cache = setmetatable({}, { __mode = 'k' })

---@param state table
---@return table scope
local function ensure_scope(state)
  local scope = M.scope[state]
  if not scope or scope:is_disposed() then
    scope = require('vv-utils.async').scope({ cancel_previous = true })
    M.scope[state] = scope
  end
  return scope
end

-- 取消在途的目录统计。光标一旦移开，继续遍历只是白烧 IO；scope 的 cancel 会把
-- 物理取消传导到 scan handle，而不是只让结果失效
---@param state table
function M.cancel_scan(state)
  local scope = M.scope[state]
  if scope and not scope:is_disposed() then scope:cancel() end
end

-- 文件系统一有变化就整体作废，不逐条比对 mtime：递归统计天然会被子孙层级的改动
-- 影响，只看目录自身的 mtime 判断不出来
---@param state table
function M.invalidate_cache(state)
  M.cache[state] = nil
end

---@param state table
---@param abs string
---@param buf integer
---@param shallow VVFsDirShallow
---@param display_path string
---@param config VVExplorerDirectoryPreviewConfig
local function start_scan(state, abs, buf, shallow, display_path, config)
  local request = ensure_scope(state):begin({ key = 'dir-scan', mode = 'latest' })

  -- 异步结果只能写回它自己创建的那个 buffer。buffer 被 wipe 后 id 会被复用，
  -- 因此除了 valid 还要比对 buffer 上记录的目录
  local function render(scan)
    if not vim.api.nvim_buf_is_valid(buf) then return false end
    if vim.b[buf].vv_explorer_dir_path ~= abs then return false end
    InfoBuf.write(buf, Fs.dir_info_lines(shallow, {
      display_path = display_path,
      scan = scan,
    }))
    return true
  end

  local handle = Fs.scan_dir(abs, {
    max_entries = config.max_entries,
    budget_ms = config.budget_ms,
    on_progress = function(scan)
      if not request:is_current() then return end
      -- 目标已经不在了（预览被换掉但取消还没传导到），主动停掉剩余遍历
      if not render(scan) then request:cancel() end
    end,
    on_done = function(scan)
      if not request:finish() then return end
      if not render(scan) then return end

      local cache = M.cache[state] or {}
      cache[abs] = scan
      M.cache[state] = cache
    end,
  })

  request:set_cancel(function() handle.cancel() end)
end

---@param state table
---@param path string
function M.preview(state, path)
  local config = state.opts.directory_preview
  if not config or not config.enabled then return end

  local abs = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  local main = MainWin.find_main_win(state.win, state)
  if not main then return end
  if not vim.api.nvim_win_is_valid(main) then return end

  -- 光标在同一个目录内上下移动会反复触发 CursorMoved；重建 buffer 会打断自己的
  -- 在途统计，让大目录永远算不完
  local cur_buf = vim.api.nvim_win_get_buf(main)
  if vim.b[cur_buf].vv_explorer_dir_path == abs then return end

  M.cancel_scan(state)

  local shallow = Fs.inspect_dir(abs)
  if not shallow.exists then return end

  local cached = (M.cache[state] or {})[abs]
  local buf = InfoBuf.create()
  vim.b[buf].vv_explorer_dir_info = true
  vim.b[buf].vv_explorer_dir_path = abs
  InfoBuf.write(buf, Fs.dir_info_lines(shallow, { display_path = path, scan = cached }))

  local mounted = Mount.mount(state, main, buf, {
    cur_buf = cur_buf,
    is_fixed = false,
    was_listed = false,
    scratch = true,
  })
  if not mounted then return end

  if cached or not config.recursive or not shallow.readable then return end
  start_scan(state, abs, buf, shallow, path, config)
end

-- 面板销毁：scope 永久关闭（不再复用），缓存随之释放
---@param state table
function M.detach(state)
  local scope = M.scope[state]
  if scope and not scope:is_disposed() then scope:dispose() end
  M.scope[state] = nil
  M.cache[state] = nil
end

return M

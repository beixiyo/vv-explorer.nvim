-- 永久删除的在途任务：多个目标顺序分片异步删除，删除期间被删项图标槽显示 loading
--
-- 同步递归删除大目录会冻结 UI，这里逐个目标调用 vv-utils.fs.delete_async（单个目标内部按时间片让出）
--
-- 边界：
--   • 顺序删除，首个失败立即停止，后续目标不再删除；已删除部分不回滚
--   • 结束时（成功或失败）先调 on_done 让调用方刷新，再停帧：帧持续到刷新把项从树上移除
--   • cancel 停止在途删除并停帧，不调用 on_done，之后不再回写 UI
--   • 同一 state 可有多个互不重叠的在途任务；重叠检查由调用方在发起前用 overlapping() 完成

local Fs = require('vv-utils.fs')
local Loading = require('vv-utils.loading')
local Render = require('vv-explorer.render')

local M = {}

local LOADING_DELAY_MS = 150

---@param path string
---@param ancestor string
---@return boolean
local function is_within(path, ancestor)
  return path == ancestor or path:sub(1, #ancestor + 1) == ancestor .. '/'
end

--- 与在途删除重叠（相同、祖先或后代）的第一个目标
---@param state table
---@param paths string[] 绝对规范路径
---@return string? path
function M.overlapping(state, paths)
  for job in pairs(state._delete_jobs or {}) do
    for _, busy in ipairs(job.paths) do
      for _, path in ipairs(paths) do
        if is_within(path, busy) or is_within(busy, path) then return path end
      end
    end
  end
end

--- 开始顺序删除；返回的 job 可 cancel
---@param state table
---@param opts VVExplorerPermanentDeleteOptions
---@return VVExplorerPermanentDeleteJob
function M.start(state, opts)
  local paths = opts.paths
  local deleted = {} ---@type string[]
  local handle ---@type VVFsDeleteAsyncHandle?
  local loading ---@type vv-utils.loading.Handle?
  local job ---@type VVExplorerPermanentDeleteJob

  state._delete_jobs = state._delete_jobs or {}

  local function release()
    state._delete_jobs[job] = nil
    handle = nil
    if loading then loading:stop() end
    loading = nil
  end

  job = {
    paths = paths,
    cancel = function()
      if not state._delete_jobs[job] then return end
      if handle then handle.cancel() end
      release()
      if opts.on_cancel then opts.on_cancel({ deleted = deleted }) end
    end,
  }
  state._delete_jobs[job] = true

  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    -- 每帧重新定位：删除期间 watch 会重画树，可见行随之变化
    loading = Loading.mark({
      buf = state.buf,
      get_pos = function()
        local positions = {}
        for _, path in ipairs(paths) do
          positions[#positions + 1] = Render.icon_slot_pos(state, path)
        end
        return positions
      end,
      pos = 'overlay',
      width = Render.ICON_SLOT_COLS,
      delay_ms = LOADING_DELAY_MS,
    })
  end

  ---@param err? string
  local function finish(err)
    if not state._delete_jobs[job] then return end
    state._delete_jobs[job] = nil
    handle = nil
    -- 先让调用方刷新（项从树上消失），再停帧；on_done 抛错也必须停帧
    local ok, callback_err = pcall(opts.on_done, { deleted = deleted, err = err })
    release()
    if not ok then error(callback_err) end
  end

  local function step(index)
    local path = paths[index]
    if not path then return finish() end

    handle = Fs.delete_async(path, {
      on_done = function(ok, err)
        if not state._delete_jobs[job] then return end
        if not ok then return finish(tostring(err)) end
        deleted[#deleted + 1] = path
        step(index + 1)
      end,
    })
  end

  step(1)
  return job
end

--- 取消 state 上全部在途删除（面板关闭 / buffer wipe），幂等
---@param state table
function M.cancel_all(state)
  local jobs = vim.tbl_keys(state._delete_jobs or {})
  for _, job in ipairs(jobs) do job.cancel() end
end

return M

---@class VVExplorerPermanentDeleteResult
---@field deleted string[] 已完整删除的目标，按删除顺序
---@field err? string 首个失败的错误信息；nil 表示全部成功

---@class VVExplorerPermanentDeleteOptions
---@field paths string[] 绝对规范路径，按顺序删除
---@field on_done fun(result: VVExplorerPermanentDeleteResult) 全部完成或首个失败时调用一次，此时帧仍在
---@field on_cancel? fun(result: { deleted: string[] }) 被 cancel 时调用一次，不得回写 explorer UI

---@class VVExplorerPermanentDeleteJob
---@field paths string[]
---@field cancel fun() 停止在途删除并停帧，幂等

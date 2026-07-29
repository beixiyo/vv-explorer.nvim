-- vv-explorer.prompt — 底部过滤输入框
--
-- 骨架已下沉到 vv-utils.prompt（与 vv-flow 共用同一套双行浮窗 + 光标锁 + 防抖 +
-- mode badge + spinner + close 句柄）。本文件只做 vv-explorer 特有的适配：
--   · state.win → anchor_win
--   · on_submit（explorer 命名） → on_accept（prompt 统一命名）
--   · mode badge 显示走 Filter.display（fuzzy/glob/regex）
--   · 状态文案 N matches / showing X of Y 从 state.filter 读
--   · 自适应防抖：索引规模大时按 count/100 放大 wait（小目录恒 30ms）
--   · spinner 从「反向读 state.filter.searching」改为「push 模型」——
--     输入即 set_busy(true,'searching…')，indexing 由 actions 在构建期间 set_busy

local Prompt = require('vv-utils.prompt')
local Completion = require('vv-explorer.completion')
local Filter = require('vv-explorer.filter')

local M = {}

-- 自适应防抖 ms：索引 < threshold 用 30ms；否则 min(max_ms, floor(count/100))
---@param state table
---@return fun(): integer
local function make_debounce(state)
  return function()
    local fo = (state.opts and state.opts.filter) or {}
    local threshold = fo.debounce_threshold or 5000
    local max_ms = fo.debounce_max_ms or 600
    local count = (state.filter and state.filter.index and #state.filter.index) or 0
    if count >= threshold then return math.min(max_ms, math.floor(count / 100)) end
    return 30
  end
end

-- 非 busy 状态文案：'N matches' / 'showing X of Y'（busy 时 prompt 自己画 spinner，忽略本函数）
---@param state table
---@return fun(): string
local function make_status(state)
  return function()
    local f = state.filter
    if not f or (f.query or '') == '' or f.match_count == nil then return '' end
    if f.display_count and f.display_count < f.match_count then
      return string.format('showing %d of %d', f.display_count, f.match_count)
    end
    return string.format('%d match%s', f.match_count, f.match_count == 1 and '' or 'es')
  end
end

-- 打开过滤输入框
---@param state table                vv-explorer state（用 state.win 作锚、state.filter 读状态）
---@param opts VVExplorerPromptOpts   actions/filter.lua 的语义回调
---@return VVPromptHandle?            actions 存进 state.filter.prompt，关闭/刷新/spinner 都走它
function M.open(state, opts)
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then return end

  local handle
  handle = Prompt.open(state.win, {
    initial       = opts.initial,
    filetype      = 'vv-explorer-filter',
    completion    = Completion.descriptor(state),
    mode_display  = Filter.display,
    get_mode      = opts.get_mode,
    on_cycle_mode = opts.on_cycle_mode,
    get_status    = make_status(state),
    debounce      = make_debounce(state),
    spinner       = {},  -- 启用 busy spinner（push 模型，由 on_input / actions 驱动）
    on_input      = function(q)
      -- 每次按键即时反馈：非空即进入 searching（防抖后 refilter 会 set_busy(false)）
      if (q or '') ~= '' and handle then
        state.filter.searching = true
        handle.set_busy(true, 'searching…')
      end
    end,
    on_change     = opts.on_change,
    on_accept     = opts.on_submit,   -- 命名统一：explorer on_submit == prompt on_accept
    on_cancel     = opts.on_cancel,
    on_navigate   = opts.on_navigate,
    on_open_in    = opts.on_open_in,
  })
  return handle
end

return M

---@class VVExplorerPromptOpts
---@field initial?       string
---@field on_change      fun(query: string)
---@field on_submit      fun(query: string)
---@field on_cancel      fun()
---@field on_cycle_mode? fun(): string
---@field on_navigate?   fun(dir: integer)
---@field on_open_in?    fun(kind: 'split'|'vsplit')
---@field get_mode?      fun(): string

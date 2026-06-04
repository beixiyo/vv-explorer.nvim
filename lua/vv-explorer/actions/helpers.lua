-- actions 子模块间共享的辅助函数

local Render = require('vv-explorer.render')
local Tree = require('vv-explorer.tree')
local Fs = require('vv-utils.fs')

local H = {}

-- 把一个「真实路径形」的 file 映射回「树内可达」的符号链接形路径，供 Tree.expand_to 使用。
--
-- 场景：用户经符号链接目录打开文件（`linkdir/bar.txt`），`nvim_buf_get_name` 返回解析形
-- （`/external/realdir/bar.txt`，可能完全在 root 之外）。直接 `expand_to(root, 解析形)` 因
-- 不在 root 下而失败，导致 reveal 无法展开、光标停在 root。此函数遍历已知树节点，找出某个
-- 节点真实路径恰为 file 真实路径前缀者，用「该节点的树内路径 + 剩余段」拼出树内路径。
--
-- 仅扫描已 scan 的节点（懒加载下顶层目录已在 root.children 里），命中即按需深入。
---@param state table
---@param file string
---@return string in_tree_path  无法映射时回退 normalize(file)
function H.to_tree_path(state, file)
  local root = state.root
  if not root then return vim.fs.normalize(file) end

  local file_real = Fs.realpath(file)
  local root_real = Fs.realpath(root.path)

  -- 已在 root 之下（普通路径）→ 直接用规范化形，走 expand_to 原逻辑
  local norm = vim.fs.normalize(file)
  if norm == root.path or norm:sub(1, #root.path + 1) == root.path .. '/' then
    return norm
  end
  if file_real == root_real or file_real:sub(1, #root_real + 1) == root_real .. '/' then
    -- 真实路径在 root 之下：用真实路径（expand_to 会自行 normalize）
    return file_real
  end

  -- 真实路径在 root 之外：找出树内某节点其真实路径是 file_real 的前缀
  local best
  local function visit(node)
    if not node.is_dir then return end
    local nr = Fs.realpath(node.path)
    if nr == file_real or file_real:sub(1, #nr + 1) == nr .. '/' then
      -- 选最长前缀（最深匹配），拼接剩余段后构造树内路径
      if not best or #Fs.realpath(best.path) < #nr then best = node end
    end
    for _, c in pairs(node.children or {}) do visit(c) end
  end
  visit(root)

  if best then
    local nr = Fs.realpath(best.path)
    local rest = file_real:sub(#nr + 1) -- 以 / 开头或为空
    return vim.fs.normalize(best.path .. rest)
  end

  return norm
end

-- 展开树使 file 可见（容忍符号链接解析形 file），返回是否成功
---@param state table
---@param file string
---@return boolean
function H.expand_to_file(state, file)
  if not state.root then return false end
  return Tree.expand_to(state.root, H.to_tree_path(state, file))
end

-- 在 state.path_to_row 中为 file 找到目标行号（用于 reveal / follow_file 定位光标）。
--
-- 难点：`path_to_row` 的 key 是树节点路径（`vim.fs.normalize`，**不解析符号链接**），
-- 而 follow/reveal 传入的 file 多来自 `nvim_buf_get_name`（Vim 已把符号链接**解析**成
-- 真实路径）。symlink 场景下两者字符串不等 → 直查 miss → 光标爬到错误祖先行。
--
-- 策略（先快后慢，无 symlink 时零额外开销）：
--   1. 直查 normalize(file)；命中即返回（覆盖绝大多数普通路径）。
--   2. miss → 把 file 解析为真实路径，并把每个 path_to_row key 也解析为真实路径后比对
--      （含「最深可达祖先」回溯：reveal target 可能被 group_empty_dirs 合并到上层）。
--      仅在直查失败时才做这趟解析扫描，不拖累常规渲染/移动。
---@param state table
---@param file string
---@return integer? lnum
function H.find_row(state, file)
  local map = state.path_to_row
  if not map then return nil end

  -- 1) 快路径：普通路径两侧口径一致，直接命中
  local p = vim.fs.normalize(file)
  while p ~= '' do
    local l = map[p]
    if l then return l end
    local parent = vim.fs.dirname(p)
    if parent == p then break end
    p = parent
  end

  -- 2) 慢路径：symlink 解析后在真实路径空间比对
  -- 预解析所有 key 的真实路径（一次扫描），再用 file 真实路径逐级祖先回溯命中
  local real_to_row = {}
  for key, l in pairs(map) do
    local rk = Fs.realpath(key)
    -- 多个 symlink 指向同一真实路径时，保留较短 key（更接近根，定位更稳定）
    if not real_to_row[rk] or #key < #real_to_row[rk].key then
      real_to_row[rk] = { lnum = l, key = key }
    end
  end

  local rp = Fs.realpath(file)
  while rp ~= '' do
    local hit = real_to_row[rp]
    if hit then return hit.lnum end
    local parent = vim.fs.dirname(rp)
    if parent == rp then break end
    rp = parent
  end

  return nil
end

H.EMPTY_MATCHED = { abs = {}, rels = {}, positions = {}, total_count = 0 }

-- 统一失效过滤索引：清空全树索引及其派生缓存，并复位「正在构建」标志。
--
-- 凡是会改变「可见文件集合」的操作（切根 cd_to/cd_up、增删改、切 hidden/gitignored、
-- refresh）都必须调它，否则旧索引（旧 root 的绝对路径 / 旧配置的路径集）会被
-- ensure_filter_index / refilter 复用，导致用「新 root + 旧 rels」拼出磁盘上不存在
-- 的错误绝对路径。集中一处清，避免每个入口各写一遍、漏字段。
--
-- index_building 一并复位为 false：否则某次构建中途切根，残留 true 会让
-- ensure_filter_index 误判「仍在 building」而永不重建（卡 building）。
---@param state table
function H.invalidate_filter_index(state)
  local f = state.filter
  if not f then return end
  f.index = nil
  f.index_rels = nil
  f.index_root = nil
  f.is_dir_map = nil
  f.index_building = false
end

---@param path string
---@param opts VVExplorerConfig
---@return boolean
function H.is_binary(path, opts)
  local cfg = opts.binary
  if not cfg or not cfg.intercept then return false end
  local ext = path:match('%.([%w_]+)$')
  return ext and cfg.extensions[ext:lower()] or false
end

---@param state table
function H.ensure_state_fields(state)
  state.selection = state.selection or {}
  state.clipboard = state.clipboard or nil
end

---@param state table
---@return string[]
function H.selected_paths(state)
  local out = {}
  for p in pairs(state.selection or {}) do out[#out + 1] = p end
  table.sort(out)
  return out
end

---@param state table
---@param path string?
function H.focus_path(state, path)
  if not path or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local lnum = state.path_to_row and state.path_to_row[path]
  if lnum then
    pcall(vim.api.nvim_win_set_cursor, state.win, { lnum, 0 })
  end
end

-- 把 buffer 行号映射到树节点。过滤模式与普通模式行↔节点偏移不同（普通模式行 1 为 root，
-- rows 从行 2 起；过滤模式无 root 行，rows 从行 1 起），与 render / render_filter 对齐。
---@param state table
---@param lnum integer  1-based buffer 行号
---@return table?
function H.node_at_line(state, lnum)
  local f = state.filter
  if f and f.active and (f.query or '') ~= '' then
    local row = state.rows and state.rows[lnum]
    return row and row.node or nil
  end
  if lnum == 1 then return state.root end
  local row = state.rows and state.rows[lnum - 1]
  return row and row.node or nil
end

---@param state table
---@return table?
function H.node_under_cursor(state)
  if not vim.api.nvim_win_is_valid(state.win) then return nil end
  local lnum = vim.api.nvim_win_get_cursor(state.win)[1]
  return H.node_at_line(state, lnum)
end

-- 在 explorer 窗内执行 split-like 命令打开 path，并把新窗口 chrome 拉回全局默认
---@param state table
---@param cmd string
---@param path string
function H.open_in_explorer_split(state, cmd, path)
  vim.api.nvim_set_current_win(state.win)
  vim.cmd(cmd .. ' ' .. vim.fn.fnameescape(path))
  require('vv-utils.ui_window').show_chrome(vim.api.nvim_get_current_win())
end

---@param state table
function H.render(state) Render.render(state) end

return H

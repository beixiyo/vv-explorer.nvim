-- 全树索引 + matchfuzzy 过滤
-- fd 异步拿全树路径（尊重 .gitignore），fallback libuv 递归
-- match 用 vim.fn.matchfuzzypos（Vim C 实现，fzf 风格打分 + 字符位置）

local M = {}

---@param cwd string
---@param opts {hidden?:boolean}
---@param on_done fun(paths: string[])  异步回调，paths 是绝对路径列表
---@return boolean ok  fd 不存在时返回 false，不会调 on_done
function M.build_index(cwd, opts, on_done)
  if vim.fn.executable('fd') ~= 1 then
    vim.notify(
      "vv-explorer: filter requires 'fd' (not found in $PATH).\n" ..
      "Install: https://github.com/sharkdp/fd#installation\n" ..
      "  macOS:  brew install fd\n" ..
      "  Linux:  apt install fd-find  |  pacman -S fd\n" ..
      "  cargo:  cargo install fd-find",
      vim.log.levels.WARN,
      { title = 'vv-explorer' }
    )
    return false
  end

  local cmd = { 'fd', '--type', 'f', '--type', 'd' }
  if opts and opts.hidden then cmd[#cmd + 1] = '--hidden' end
  cmd[#cmd + 1] = '--exclude'
  cmd[#cmd + 1] = '.git'
  cmd[#cmd + 1] = '.'
  cmd[#cmd + 1] = cwd

  vim.system(
    cmd,
    { text = true },
    vim.schedule_wrap(function(r)
      local paths = {}
      if r.code == 0 and r.stdout then
        for line in r.stdout:gmatch('[^\n]+') do
          if line:sub(-1) == '/' then line = line:sub(1, -2) end
          paths[#paths + 1] = line
        end
      end
      on_done(paths)
    end)
  )
  return true
end

---@param index string[] 绝对路径列表
---@param cwd string     根目录（会从匹配字符串里剥掉做打分）
---@param query string
---@return {abs:string[], rels:string[], positions:integer[][]}  abs 为绝对路径；positions[i] 为 rels[i] 里 0-indexed 匹配字符下标
function M.match(index, cwd, query)
  if query == '' or #index == 0 then
    return { abs = {}, rels = {}, positions = {} }
  end

  -- 用相对路径匹配（绝对路径前缀会拉低分数准确度）
  local rels = {}
  local prefix_len = #cwd + 2 -- cwd + '/'
  for i, p in ipairs(index) do
    rels[i] = p:sub(prefix_len)
  end

  -- matchfuzzypos 返回 { matched_list, positions_list, scores_list }（单个 list，含 3 项）
  local ok, result = pcall(vim.fn.matchfuzzypos, rels, query)
  if not ok or type(result) ~= 'table' then
    return { abs = {}, rels = {}, positions = {} }
  end
  local matched = result[1] or {}
  local positions = result[2] or {}
  if #matched == 0 then
    return { abs = {}, rels = {}, positions = {} }
  end

  local abs = {}
  for i, rel in ipairs(matched) do
    abs[i] = cwd .. '/' .. rel
  end
  return { abs = abs, rels = matched, positions = positions }
end

---@param matched_abs string[]
---@param cwd string
---@return table<string, boolean>  matches + 所有祖先的路径集合
function M.visible_set(matched_abs, cwd)
  local visible = {}
  for _, abs in ipairs(matched_abs) do
    local p = abs
    while true do
      visible[p] = true
      local parent = vim.fs.dirname(p)
      if parent == p or parent == cwd or #parent <= #cwd then break end
      p = parent
    end
  end
  return visible
end

return M

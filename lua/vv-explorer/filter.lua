-- 全树索引 + 多模式过滤
-- fd 异步拿全树路径（尊重 .gitignore），fallback libuv 递归
--
-- 三种模式（在 prompt 内 <S-Tab> 循环切换）：
--   fuzzy → vim.fn.matchfuzzypos（fzf 风打分 + 字符位置高亮）
--   glob  → vim.glob.to_lpeg（shell glob 语法，无位置高亮）
--   regex → Lua pattern（string.find，无位置高亮）

local M = {}

M.MODES = { 'fuzzy', 'glob', 'regex' }

-- 模式显示元数据：图标 + 标签 + 高亮组（高亮组在 init.lua 注册）
-- prompt 渲染 mode badge 时通过 M.display(mode) 取，集中维护避免与 MODES 双源不同步
local MODE_DISPLAY = {
  fuzzy = { icon = '', label = 'Fuzzy', hl = 'VVExplorerFilterModeFuzzy' },
  glob  = { icon = '',  label = 'Glob',  hl = 'VVExplorerFilterModeGlob' },
  regex = { icon = '󰑑', label = 'Regex', hl = 'VVExplorerFilterModeRegex' },
}

---@param mode string
---@return {icon:string, label:string, hl:string}
function M.display(mode)
  return MODE_DISPLAY[mode] or { icon = '?', label = mode or '?', hl = 'Comment' }
end

---@param mode string
---@return string
function M.next_mode(mode)
  for i, m in ipairs(M.MODES) do
    if m == mode then return M.MODES[(i % #M.MODES) + 1] end
  end
  return M.MODES[1]
end

---@param cwd string
---@param opts {hidden?:boolean, show_ignored?:boolean, custom?:string[]}
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
  if opts and opts.show_ignored then cmd[#cmd + 1] = '--no-ignore' end
  cmd[#cmd + 1] = '--exclude'
  cmd[#cmd + 1] = '.git'
  if opts and opts.custom then
    for _, glob in ipairs(opts.custom) do
      cmd[#cmd + 1] = '--exclude'
      cmd[#cmd + 1] = glob
    end
  end
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

-- 准备 rels（相对路径列表）。绝对路径前缀会拉低打分准确度
---@param index string[]
---@param cwd string
---@return string[] rels
local function build_rels(index, cwd)
  local rels = {}
  local prefix_len = #cwd + 2 -- cwd + '/'
  for i, p in ipairs(index) do
    rels[i] = p:sub(prefix_len)
  end
  return rels
end

---@param rels string[]
---@param query string
---@return {matched:string[], positions:integer[][]}
local function match_fuzzy(rels, query)
  local ok, result = pcall(vim.fn.matchfuzzypos, rels, query)
  if not ok or type(result) ~= 'table' then
    return { matched = {}, positions = {} }
  end
  return { matched = result[1] or {}, positions = result[2] or {} }
end

---@param rels string[]
---@param query string
---@return {matched:string[], positions:integer[][]}
local function match_glob(rels, query)
  -- VSCode 风：query 不含 '/' 时自动跨段匹配
  --   纯文本 "foo"  → "**/*foo*"      （basename 含 foo）
  --   通配符 "*.lua" → "**/*.lua"      （任意层级下的 .lua）
  --   含 "/" 时原样：用户已自己指定路径
  local q = query
  local has_wild = q:find('[%*%?%[]') ~= nil
  local has_slash = q:find('/') ~= nil
  if not has_slash then
    q = has_wild and ('**/' .. q) or ('**/*' .. q .. '*')
  end
  local ok, lpeg_pat = pcall(vim.glob.to_lpeg, q)
  if not ok then return { matched = {}, positions = {} } end

  local matched = {}
  for _, rel in ipairs(rels) do
    if vim.lpeg and vim.lpeg.match(lpeg_pat, rel) then
      matched[#matched + 1] = rel
    end
  end
  -- 简单字典序排序（无打分概念）
  table.sort(matched)
  local positions = {}
  for i = 1, #matched do positions[i] = {} end
  return { matched = matched, positions = positions }
end

---@param rels string[]
---@param query string
---@return {matched:string[], positions:integer[][]}
local function match_regex(rels, query)
  -- Lua pattern：错误的 pattern 不应崩溃
  local ok = pcall(string.find, '', query)
  if not ok then return { matched = {}, positions = {} } end

  local matched = {}
  for _, rel in ipairs(rels) do
    local ok2, s = pcall(string.find, rel, query)
    if ok2 and s then matched[#matched + 1] = rel end
  end
  table.sort(matched)
  local positions = {}
  for i = 1, #matched do positions[i] = {} end
  return { matched = matched, positions = positions }
end

---@param index string[] 绝对路径列表
---@param cwd string     根目录（会从匹配字符串里剥掉做打分）
---@param query string
---@param mode? 'fuzzy'|'glob'|'regex' 默认 'fuzzy'
---@return {abs:string[], rels:string[], positions:integer[][]}  abs 为绝对路径；positions[i] 为 rels[i] 里 0-indexed 匹配字符下标（仅 fuzzy）
function M.match(index, cwd, query, mode)
  if query == '' or #index == 0 then
    return { abs = {}, rels = {}, positions = {} }
  end

  local rels = build_rels(index, cwd)

  local r
  if mode == 'glob' then
    r = match_glob(rels, query)
  elseif mode == 'regex' then
    r = match_regex(rels, query)
  else
    r = match_fuzzy(rels, query)
  end

  if #r.matched == 0 then
    return { abs = {}, rels = {}, positions = {} }
  end

  local abs = {}
  for i, rel in ipairs(r.matched) do
    abs[i] = cwd .. '/' .. rel
  end
  return { abs = abs, rels = r.matched, positions = r.positions }
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

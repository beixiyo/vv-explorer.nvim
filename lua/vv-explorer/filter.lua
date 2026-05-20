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
  local hidden       = opts and opts.hidden
  local show_ignored = opts and opts.show_ignored
  local custom       = opts and opts.custom or {}

  local git_root = vim.trim(vim.fn.system(
    'git -C ' .. vim.fn.shellescape(cwd) .. ' rev-parse --show-toplevel 2>/dev/null'
  ))
  local in_git = git_root ~= ''

  -- show_ignored=false + inside a git repo → use git ls-files.
  -- fd cannot handle nested git repos: when a subdir has its own .git, fd
  -- switches to that repo's gitignore and ignores the parent repo's rules.
  -- git ls-files is gitignore-aware by design and handles this correctly.
  if in_git and not show_ignored then
    local rel = (git_root ~= cwd) and cwd:sub(#git_root + 2) or ''
    local cmd = {
      'git', '-C', git_root, 'ls-files',
      '--cached', '--others', '--exclude-standard', '--full-name',
    }
    for _, pat in ipairs(custom) do
      cmd[#cmd + 1] = '--exclude=' .. pat
    end
    if rel ~= '' then cmd[#cmd + 1] = '--'; cmd[#cmd + 1] = rel end

    vim.system(cmd, { text = true }, vim.schedule_wrap(function(r)
      local paths, is_dir_map = {}, {}
      if r.code == 0 and r.stdout then
        for line in r.stdout:gmatch('[^\n]+') do
          paths[#paths + 1] = git_root .. '/' .. line
        end
      end
      on_done(paths, is_dir_map)
    end))
    return true
  end

  -- show_ignored=true inside git: two-pass.
  -- Phase 1 = same ls-files set as show_ignored=false.
  -- Phase 2 = scan only gitignored dirs that are nested git repos (.git present).
  -- This prevents catch-all gitignore rules (e.g. '*' in ~/.gitignore) from
  -- pulling in system directories like ~/Library/ that happen to be gitignored.
  if in_git then
    local rel = (git_root ~= cwd) and cwd:sub(#git_root + 2) or ''
    local phase1_cmd = {
      'git', '-C', git_root, 'ls-files',
      '--cached', '--others', '--exclude-standard', '--full-name',
    }
    for _, pat in ipairs(custom) do
      phase1_cmd[#phase1_cmd + 1] = '--exclude=' .. pat
    end
    if rel ~= '' then phase1_cmd[#phase1_cmd + 1] = '--'; phase1_cmd[#phase1_cmd + 1] = rel end

    vim.system(phase1_cmd, { text = true }, vim.schedule_wrap(function(r1)
      local phase1_paths = {}
      if r1.code == 0 and r1.stdout then
        for line in r1.stdout:gmatch('[^\n]+') do
          phase1_paths[#phase1_paths + 1] = git_root .. '/' .. line
        end
      end

      local phase2_cmd = {
        'git', '-C', git_root, 'ls-files',
        '--others', '--ignored', '--exclude-standard', '--directory', '--full-name',
      }
      if rel ~= '' then phase2_cmd[#phase2_cmd + 1] = '--'; phase2_cmd[#phase2_cmd + 1] = rel end

      vim.system(phase2_cmd, { text = true }, vim.schedule_wrap(function(r2)
        local nested_repos = {}
        if r2.code == 0 and r2.stdout then
          for line in r2.stdout:gmatch('[^\n]+') do
            local dir = line:sub(-1) == '/' and line:sub(1, -2) or line
            local abs_dir = git_root .. '/' .. dir
            if vim.uv.fs_stat(abs_dir .. '/.git') then
              nested_repos[#nested_repos + 1] = abs_dir
            end
          end
        end

        if #nested_repos == 0 then
          on_done(phase1_paths, {})
          return
        end

        local all_paths = {}
        for _, p in ipairs(phase1_paths) do all_paths[#all_paths + 1] = p end

        local pending = #nested_repos
        for _, repo_dir in ipairs(nested_repos) do
          vim.system(
            { 'git', '-C', repo_dir, 'ls-files', '--cached', '--others', '--exclude-standard' },
            { text = true },
            vim.schedule_wrap(function(r3)
              if r3.code == 0 and r3.stdout then
                for line in r3.stdout:gmatch('[^\n]+') do
                  all_paths[#all_paths + 1] = repo_dir .. '/' .. line
                end
              end
              pending = pending - 1
              if pending == 0 then on_done(all_paths, {}) end
            end)
          )
        end
      end))
    end))
    return true
  end

  -- Fallback: fd for non-git directories
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
  if hidden then cmd[#cmd + 1] = '--hidden' end
  if show_ignored then cmd[#cmd + 1] = '--no-ignore' end
  cmd[#cmd + 1] = '--exclude'; cmd[#cmd + 1] = '.git'
  for _, pat in ipairs(custom) do
    cmd[#cmd + 1] = '--exclude'; cmd[#cmd + 1] = pat
  end
  cmd[#cmd + 1] = '.'

  vim.system(cmd, { text = true, cwd = cwd }, vim.schedule_wrap(function(r)
    local paths, is_dir_map = {}, {}
    if r.code == 0 and r.stdout then
      for line in r.stdout:gmatch('[^\n]+') do
        local is_dir = line:sub(-1) == '/'
        if is_dir then line = line:sub(1, -2) end
        local abs = cwd .. '/' .. line
        paths[#paths + 1] = abs
        if is_dir then is_dir_map[abs] = true end
      end
    end
    on_done(paths, is_dir_map)
  end))
  return true
end

-- 准备 rels（相对路径列表）。绝对路径前缀会拉低打分准确度
---@param index string[]
---@param cwd string
---@return string[] rels
function M.build_rels(index, cwd)
  local rels = {}
  local prefix_len = #cwd + 2 -- cwd + '/'
  for i, p in ipairs(index) do
    rels[i] = p:sub(prefix_len)
  end
  return rels
end

-- 预过滤：所有 query 字符必须按序出现在 rel 中（fuzzy 匹配的必要条件）
-- 在 matchfuzzypos 前调用，把候选从 10 万量级缩至百级，消除主线程阻塞
local function fast_prefilter(rels, query)
  local ql = query:lower()
  local qchars = {}
  for i = 1, #ql do qchars[i] = ql:sub(i, i) end
  local qlen = #qchars
  local result = {}
  for _, rel in ipairs(rels) do
    local rl = rel:lower()
    local pos = 1
    local ok = true
    for i = 1, qlen do
      local found = rl:find(qchars[i], pos, true)
      if not found then ok = false; break end
      pos = found + 1
    end
    if ok then result[#result + 1] = rel end
  end
  return result
end

-- query 无 '/' → 仅对 basename 做 fuzzy，彻底消除目录噪音。
-- positions 从 basename 空间偏移回完整 rel 空间，高亮仍正确。
-- 同名 basename 用 queue 按原始顺序映射回对应 rel。
local function match_fuzzy_basename(rels, query)
  local c_bn, c_off, c_rel = {}, {}, {}

  local ql = query:lower()
  local qchars = {}
  for i = 1, #ql do qchars[i] = ql:sub(i, i) end
  local qlen = #qchars

  for _, rel in ipairs(rels) do
    local slash = rel:find('/[^/]*$')          -- 1-based index of last '/'
    local bn  = slash and rel:sub(slash + 1) or rel
    local off = slash or 0                     -- 0-based start of basename in rel
    -- prefilter on basename
    local bnl = bn:lower()
    local pos, ok = 1, true
    for j = 1, qlen do
      local found = bnl:find(qchars[j], pos, true)
      if not found then ok = false; break end
      pos = found + 1
    end
    if ok then
      c_bn[#c_bn + 1] = bn
      c_off[#c_off + 1] = off
      c_rel[#c_rel + 1] = rel
    end
  end

  if #c_bn == 0 then return { matched = {}, positions = {} } end

  local ok, result = pcall(vim.fn.matchfuzzypos, c_bn, query)
  if not ok or type(result) ~= 'table' then
    return { matched = {}, positions = {} }
  end

  local matched_bns = result[1] or {}
  local raw_pos     = result[2] or {}

  -- Build per-basename queues: handles duplicate basenames (e.g. multiple index.lua).
  -- matchfuzzypos may return the same basename string N times; pop queues in order.
  local queues = {}
  for i, bn in ipairs(c_bn) do
    if not queues[bn] then queues[bn] = {} end
    queues[bn][#queues[bn] + 1] = { rel = c_rel[i], off = c_off[i] }
  end

  local m, p = {}, {}
  for i, bn in ipairs(matched_bns) do
    local q = queues[bn]
    if q and #q > 0 then
      local entry = table.remove(q, 1)
      m[#m + 1] = entry.rel
      local adj = {}
      for _, pp in ipairs(raw_pos[i] or {}) do
        adj[#adj + 1] = pp + entry.off   -- offset into full rel
      end
      p[#p + 1] = adj
    end
  end

  return { matched = m, positions = p }
end

---@param rels string[]
---@param query string
---@return {matched:string[], positions:integer[][]}
local function match_fuzzy(rels, query)
  -- No '/' → basename-only (场景: "App.tsx", ".gitignore", 模糊文件名)
  if not query:find('/', 1, true) then
    return match_fuzzy_basename(rels, query)
  end

  -- Has '/' → full-path fuzzy (场景: "src/Button", "src/compnts/Button" 跨段/错拼)
  local candidates = fast_prefilter(rels, query)
  local ok, result = pcall(vim.fn.matchfuzzypos, candidates, query)
  if not ok or type(result) ~= 'table' then
    return { matched = {}, positions = {} }
  end

  local matched   = result[1] or {}
  local positions = result[2] or {}

  -- Re-rank: basename matches sort first (fzf --scheme=path behaviour)
  local bn_m, bn_p   = {}, {}
  local path_m, path_p = {}, {}

  for i, rel in ipairs(matched) do
    local slash    = rel:find('/[^/]*$')
    local bn_start = slash or 0
    local pos      = positions[i] or {}
    local in_bn    = true
    for _, pp in ipairs(pos) do
      if pp < bn_start then in_bn = false; break end
    end
    if in_bn then
      bn_m[#bn_m + 1] = rel;   bn_p[#bn_p + 1] = pos
    else
      path_m[#path_m + 1] = rel; path_p[#path_p + 1] = pos
    end
  end

  local m, p = {}, {}
  for i = 1, #bn_m   do m[i]        = bn_m[i];   p[i]        = bn_p[i]   end
  local off = #bn_m
  for i = 1, #path_m do m[off + i]  = path_m[i]; p[off + i]  = path_p[i] end

  return { matched = m, positions = p }
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
  local ok, regex = pcall(vim.regex, query)
  if not ok or not regex then return { matched = {}, positions = {} } end

  local matched = {}
  for _, rel in ipairs(rels) do
    if regex:match_str(rel) then
      matched[#matched + 1] = rel
    end
  end
  table.sort(matched)
  local positions = {}
  for i = 1, #matched do positions[i] = {} end
  return { matched = matched, positions = positions }
end

---@param index string[] 绝对路径列表
---@param rels string[] 相对路径列表
---@param cwd string     根目录（会从匹配字符串里剥掉做打分）
---@param query string
---@param mode? 'fuzzy'|'glob'|'regex' 默认 'fuzzy'
---@param max_results? integer 默认 1000
---@return {abs:string[], rels:string[], positions:integer[][], total_count:integer}  abs 为绝对路径；positions[i] 为 rels[i] 里 0-indexed 匹配字符下标（仅 fuzzy）
function M.match(index, rels, cwd, query, mode, max_results)
  if query == '' or #index == 0 then
    return { abs = {}, rels = {}, positions = {}, total_count = 0 }
  end

  local r
  if mode == 'glob' then
    r = match_glob(rels, query)
  elseif mode == 'regex' then
    r = match_regex(rels, query)
  else
    r = match_fuzzy(rels, query)
  end

  local total = #r.matched
  if total == 0 then
    return { abs = {}, rels = {}, positions = {}, total_count = 0 }
  end

  local limit = max_results or 1000

  -- 限制匹配数量：避免过大的搜索结果导致渲染和 extmark 计算卡死
  -- fuzzy 模式下保留的是打分最高的前 N 项
  if total > limit then
    local nm, np = {}, {}
    for i = 1, limit do
      nm[i] = r.matched[i]
      np[i] = r.positions[i]
    end
    r.matched = nm
    r.positions = np
  end

  local abs = {}
  for i, rel in ipairs(r.matched) do
    abs[i] = cwd .. '/' .. rel
  end
  return { abs = abs, rels = r.matched, positions = r.positions, total_count = total }
end

---@param matched_abs string[]
---@param cwd string
---@return table<string, boolean> visible, table<string, boolean> is_dir_map
function M.visible_set(matched_abs, cwd)
  local visible = {}
  local is_dir_map = {}
  for _, abs in ipairs(matched_abs) do
    local p = abs
    while true do
      visible[p] = true
      local parent = vim.fs.dirname(p)
      if parent == p or parent == cwd or #parent <= #cwd then break end
      is_dir_map[parent] = true
      p = parent
    end
  end
  return visible, is_dir_map
end

return M

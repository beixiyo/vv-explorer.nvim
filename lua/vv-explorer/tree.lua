-- 树数据结构 + libuv 同步扫描 + flatten（含 group_empty_dirs）
-- Node:
--   path/name/type/is_dir/parent/children/open/scanned/hidden

local uv = vim.uv or vim.loop

local M = {}

local function norm(p) return vim.fs.normalize(p) end

local function join(a, b)
  if a:sub(-1) == '/' then return norm(a .. b) end
  return norm(a .. '/' .. b)
end

---@param parent table?
---@param name string
---@param path string
---@param type string
local function make_node(parent, name, path, type)
  return {
    name = name,
    path = norm(path),
    type = type,
    is_dir = type == 'directory' or (type == 'link' and vim.fn.isdirectory(path) == 1),
    parent = parent,
    children = nil,
    open = false,
    scanned = false,
    hidden = name:sub(1, 1) == '.',
  }
end

---@param path string
function M.new_root(path)
  path = norm(path)
  local name = vim.fs.basename(path)
  if name == '' then name = path end
  local root = make_node(nil, name, path, 'directory')
  root.is_dir = true
  root.open = true
  return root
end

---@param node table
function M.scan(node)
  if not node.is_dir then return end
  local fs = uv.fs_scandir(node.path)
  local children = {}
  while fs do
    local name, t = uv.fs_scandir_next(fs)
    if not name then break end
    local p = join(node.path, name)
    if not t then
      local stat = uv.fs_stat(p)
      t = stat and stat.type or 'unknown'
    end
    children[name] = make_node(node, name, p, t)
  end
  node.children = children
  node.scanned = true
end

---@param node table
function M.ensure_scanned(node)
  if node.is_dir and not node.scanned then M.scan(node) end
end

---@param node table
---@param filter? fun(n:table):boolean
local function children_sorted(node, filter)
  if not node.children then return {} end
  local list = {}
  for _, c in pairs(node.children) do
    if not filter or filter(c) then list[#list + 1] = c end
  end
  table.sort(list, function(a, b)
    if a.is_dir ~= b.is_dir then return a.is_dir end
    return a.name:lower() < b.name:lower()
  end)
  return list
end

---@param node table 重新扫描，保留已展开子树的 open 状态
function M.refresh(node)
  if not node.is_dir then return end
  local prev = {}
  if node.children then
    for name, child in pairs(node.children) do
      if child.is_dir and (child.open or child.scanned) then prev[name] = child end
    end
  end
  M.scan(node)
  for name, p in pairs(prev) do
    local cur = node.children[name]
    if cur and cur.is_dir then
      cur.open = p.open
      cur.children = p.children
      cur.scanned = p.scanned
      -- 递归刷新已加载的子目录
      if cur.scanned then M.refresh(cur) end
    end
  end
end

-- 编译 custom filter globs（basename 匹配；失败的 glob 静默忽略）
---@param globs string[]?
---@return fun(name:string):boolean? matcher  返回 nil 表示无自定义过滤
local function compile_custom(globs)
  if not globs or #globs == 0 then return nil end
  local patts = {}
  for _, g in ipairs(globs) do
    local ok, patt = pcall(vim.glob.to_lpeg, g)
    if ok and patt then patts[#patts + 1] = patt end
  end
  if #patts == 0 then return nil end
  return function(name)
    for _, p in ipairs(patts) do
      if p:match(name) then return true end
    end
    return false
  end
end

---@param root table
---@param opts {hidden:boolean, group_empty_dirs:boolean, custom_globs?:string[], is_ignored?:fun(path:string):boolean, show_ignored?:boolean, is_tracked?:fun(path:string):boolean}
---@return table[] rows  { node, depth, display_name, group_chain, has_children }
function M.flatten(root, opts)
  local rows = {}
  local custom = compile_custom(opts.custom_globs)
  local is_ignored = opts.is_ignored
  local show_ignored = opts.show_ignored
  local is_tracked = opts.is_tracked

  local filter = function(n)
    -- dotfile 默认隐藏，但若已被 git 跟踪则放行（含作为 tracked 后代祖先的目录）
    if not opts.hidden and n.hidden and not (is_tracked and is_tracked(n.path)) then
      return false
    end
    if custom and custom(n.name) then return false end
    if is_ignored and not show_ignored and is_ignored(n.path) then return false end
    return true
  end

  local function walk(parent, depth)
    local children = children_sorted(parent, filter)
    for _, child in ipairs(children) do
      -- group_empty_dirs：单一 dir 子节点的链式合并
      local chain = { child.name }
      local tip = child
      local last_subs
      if tip.is_dir then
        M.ensure_scanned(tip)
        last_subs = children_sorted(tip, filter)
        if opts.group_empty_dirs then
          while #last_subs == 1 and last_subs[1].is_dir do
            chain[#chain + 1] = last_subs[1].name
            tip = last_subs[1]
            M.ensure_scanned(tip)
            last_subs = children_sorted(tip, filter)
          end
        end
      end

      local has_children = last_subs and #last_subs > 0 or false

      rows[#rows + 1] = {
        node = tip,
        depth = depth,
        display_name = #chain > 1 and table.concat(chain, '/') or child.name,
        group_chain = chain,
        has_children = has_children,
      }

      if tip.is_dir and tip.open then
        walk(tip, depth + 1)
      end
    end
  end

  M.ensure_scanned(root)
  walk(root, 0)
  return rows
end

---@param root table
---@param target_path string  展开 target 的所有父目录使其可见
---@return boolean ok
function M.expand_to(root, target_path)
  target_path = norm(target_path)
  if target_path ~= root.path and not target_path:find(root.path .. '/', 1, true) then
    return false
  end
  if target_path == root.path then return true end
  local rel = target_path:sub(#root.path + 2)
  local parts = vim.split(rel, '/', { plain = true })
  local node = root
  for i, part in ipairs(parts) do
    M.ensure_scanned(node)
    local child = node.children and node.children[part]
    if not child then return false end
    if i < #parts and child.is_dir then child.open = true end
    node = child
  end
  return true
end

---@param root table
---@param path string
---@return table?
function M.find(root, path)
  path = norm(path)
  if path == root.path then return root end
  if not path:find(root.path .. '/', 1, true) then return nil end
  local rel = path:sub(#root.path + 2)
  local node = root
  for _, part in ipairs(vim.split(rel, '/', { plain = true })) do
    if not node.children then return nil end
    node = node.children[part]
    if not node then return nil end
  end
  return node
end

---@param root table 收集所有处于 open 状态且已扫描的目录路径
function M.open_dirs(root)
  local out = {}
  local function visit(n)
    if n.is_dir and n.open then
      out[#out + 1] = n.path
      for _, c in pairs(n.children or {}) do visit(c) end
    end
  end
  visit(root)
  return out
end

return M

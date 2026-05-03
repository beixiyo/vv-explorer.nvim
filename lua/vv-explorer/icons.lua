-- 图标解析：用户规则 (glob/Lua pattern) > MiniIcons > 默认 fallback
-- glob 用 vim.glob.to_lpeg（Neovim 0.10+ 内置 LPEG）

local M = {}

---@class VVExplorerIconRule
---@field glob? string    vim 风 glob，例 '**/*.test.{ts,tsx}'
---@field pattern? string Lua pattern，例 '^README'
---@field icon string
---@field hl? string
---@field scope? 'file'|'directory'|'any' 默认 any

local rules = {}

local DEFAULT_DIR_CLOSED = { glyph = '', hl = 'VVExplorerDir' }
local DEFAULT_DIR_OPEN   = { glyph = '', hl = 'VVExplorerDir' }
local DEFAULT_DIR_EMPTY  = { glyph = '󰉖', hl = 'VVExplorerDir' }
local DEFAULT_FILE       = { glyph = '', hl = 'VVExplorerFile' }

---@param user_rules VVExplorerIconRule[]?
function M.compile(user_rules)
  rules = {}
  for _, r in ipairs(user_rules or {}) do
    local matcher
    if r.glob then
      local ok, lpeg = pcall(vim.glob.to_lpeg, r.glob)
      if ok and lpeg then
        matcher = function(name, path)
          return lpeg:match(path) ~= nil or lpeg:match(name) ~= nil
        end
      end
    elseif r.pattern then
      local pat = r.pattern
      matcher = function(name, path)
        return name:match(pat) ~= nil or path:match(pat) ~= nil
      end
    end
    if matcher then
      rules[#rules + 1] = {
        match = matcher,
        scope = r.scope or 'any',
        icon = r.icon,
        hl = r.hl,
      }
    end
  end
end

---@param node {name:string, path:string, is_dir:boolean, open:boolean, has_children:boolean}
---@return string glyph, string? hl
function M.resolve(node)
  local scope = node.is_dir and 'directory' or 'file'
  for _, rule in ipairs(rules) do
    if (rule.scope == 'any' or rule.scope == scope) and rule.match(node.name, node.path) then
      return rule.icon, rule.hl
    end
  end

  local mi = _G.MiniIcons
  if node.is_dir then
    if mi then
      local g, h, is_default = mi.get('directory', node.name)
      if not is_default then return g, h end
      local lower = node.name:lower()
      if lower ~= node.name then
        local g2, h2, d2 = mi.get('directory', lower)
        if not d2 then return g2, h2 end
      end
      return g, h
    end
    if not node.has_children then return DEFAULT_DIR_EMPTY.glyph, DEFAULT_DIR_EMPTY.hl end
    local d = node.open and DEFAULT_DIR_OPEN or DEFAULT_DIR_CLOSED
    return d.glyph, d.hl
  end

  if mi then
    local g, h, is_default = mi.get('file', node.name)
    if not is_default then return g, h end
    local lower = node.name:lower()
    if lower ~= node.name then
      local g2, h2, d2 = mi.get('file', lower)
      if not d2 then return g2, h2 end
    end
    return g, h
  end
  return DEFAULT_FILE.glyph, DEFAULT_FILE.hl
end

return M

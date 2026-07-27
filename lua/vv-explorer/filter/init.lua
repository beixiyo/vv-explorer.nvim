-- 全树过滤 facade

local Index = require('vv-explorer.filter.index')
local Matcher = require('vv-explorer.filter.matcher')

local M = {}

M.MODES = Matcher.MODES
M.display = Matcher.display
M.next_mode = Matcher.next_mode
M.build_index = Index.build
M.build_rels = Matcher.build_rels
M.match = Matcher.match
M.visible_set = Matcher.visible_set

return M

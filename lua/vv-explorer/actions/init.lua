-- actions facade：汇集所有子模块，对外 API 不变

local H = require('vv-explorer.actions.helpers')

local M = {}

M.node_under_cursor = H.node_under_cursor
M.node_at_line = H.node_at_line
M.find_row = H.find_row
M.expand_to_file = H.expand_to_file
M.selected_paths = H.selected_paths

require('vv-explorer.actions.navigation').attach(M, H)
require('vv-explorer.actions.filter').attach(M, H)
require('vv-explorer.actions.crud').attach(M, H)

return M

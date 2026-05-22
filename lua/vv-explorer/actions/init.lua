-- actions facade：汇集所有子模块，对外 API 不变

local H = require('vv-explorer.actions.helpers')

local M = {}

M.node_under_cursor = H.node_under_cursor

require('vv-explorer.actions.navigation').attach(M, H)
require('vv-explorer.actions.filter').attach(M, H)
require('vv-explorer.actions.crud').attach(M, H)

return M

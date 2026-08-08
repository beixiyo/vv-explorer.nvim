-- 属性视图的 scratch buffer：二进制文件与目录都用它承载 `label: value` 文本
--
-- 内容由调用方决定（vv-utils.fs 的 file_info_lines / dir_info_lines），本模块只负责
-- buffer 的资源形态与只读约束

local Fs = require('vv-utils.fs')

local M = {}

---@return integer
function M.create()
  local buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = buf })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })
  vim.api.nvim_set_option_value('filetype', 'vv-explorer-info', { buf = buf })

  return buf
end

-- info buffer 常驻 nomodifiable，写入必须成对开关，否则异步进度回写会静默失败
---@param buf integer
---@param lines string[]
function M.write(buf, lines)
  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  vim.api.nvim_set_option_value('readonly', false, { buf = buf })

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  vim.api.nvim_set_option_value('readonly', true, { buf = buf })

  Fs.highlight_file_info(buf)
end

---@param info VVFsFileInfo
---@param display_path string
---@param abs string
---@return integer
function M.create_binary(info, display_path, abs)
  local buf = M.create()
  M.write(buf, Fs.file_info_lines(info, { display_path = display_path }))

  vim.b[buf].vv_explorer_binary_info = true
  vim.b[buf].vv_explorer_binary_path = abs

  return buf
end

return M

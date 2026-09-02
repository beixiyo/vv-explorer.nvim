-- 属性视图的 scratch buffer：二进制文件与目录都用它承载 `label: value` 文本
--
-- 内容由调用方决定（vv-utils.fs 的 file_info_lines / dir_info_lines），本模块只负责
-- buffer 的资源形态与只读约束

local FileHighlight = require('vv-utils.fs.file_info_highlight')
local FileRender = require('vv-utils.fs.file_render')

local M = {}
local namespace = vim.api.nvim_create_namespace('vv-explorer.info-hint')

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
---@param opts? { hint_line?:integer } 一基行号；整行使用弱提示高亮
function M.write(buf, lines, opts)
  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  vim.api.nvim_set_option_value('readonly', false, { buf = buf })

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  vim.api.nvim_set_option_value('readonly', true, { buf = buf })

  FileHighlight.apply(buf)
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  if opts and opts.hint_line then
    local line = lines[opts.hint_line]
    if line then
      vim.api.nvim_buf_set_extmark(buf, namespace, opts.hint_line - 1, 0, {
        end_col = #line,
        hl_group = 'Comment',
      })
    end
  end
end

---@param info VVFsFileInfo
---@param display_path string
---@param abs string
---@return integer
function M.create_binary(info, display_path, abs)
  local buf = M.create()
  M.write(buf, FileRender.lines(info, { display_path = display_path }))

  vim.b[buf].vv_explorer_binary_info = true
  vim.b[buf].vv_explorer_binary_path = abs

  return buf
end

-- 身份标记由本模块统一持有：属性页是「一次性 scratch」而不是用户内容，预览挂载、
-- 面板关闭、删除清理三处都要据此判断，各自裸写 b 变量名会让标记语义散开

---@param buf integer
---@param abs string 目录绝对路径（已 normalize）
function M.mark_dir(buf, abs)
  vim.b[buf].vv_explorer_dir_info = true
  vim.b[buf].vv_explorer_dir_path = abs
end

---@param buf integer
---@return boolean
function M.is_dir_info(buf)
  return vim.b[buf].vv_explorer_dir_info == true
end

-- 目录属性页与二进制属性页共用同一套资源形态（nofile + bufhidden=wipe），
-- 凡是「这不是用户内容」的判断都应该用它，而不是只认目录那一种
---@param buf integer
---@return boolean
function M.is_info(buf)
  return M.is_dir_info(buf) or vim.b[buf].vv_explorer_binary_info == true
end

---@param buf integer
---@return string? abs 目录属性页记录的目录路径；其它 buffer 为 nil
function M.dir_path(buf)
  return vim.b[buf].vv_explorer_dir_path
end

---@param buf integer
---@return string? abs 二进制属性页记录的文件路径；其它 buffer 为 nil
function M.binary_path(buf)
  return vim.b[buf].vv_explorer_binary_path
end

---@param buf integer
---@return string? abs 属性页对应的源路径（目录或二进制文件）；其它 buffer 为 nil
function M.source_path(buf)
  return M.binary_path(buf) or M.dir_path(buf)
end

return M

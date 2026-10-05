-- 场景运行时初始化夹具；不参与 mini.test 收集。
return function()
  -- vv-explorer.nvim 变更验证脚本



  local mapping_state = {}
  local mapping_handle = {
    get = function(_, key, default)
      local value = mapping_state[key]
      return value == nil and default or value
    end,
    set = function(_, key, value)
      mapping_state[key] = value
      return true
    end,
  }
  local mapping_root = vim.fn.tempname()
  vim.fn.mkdir(mapping_root, 'p')
  local mapping_binary = mapping_root .. '/artifact'
  local mapping_file = assert(io.open(mapping_binary, 'wb'))
  mapping_file:write(string.char(
    0xcf, 0xfa, 0xed, 0xfe,
    0x0c, 0x00, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x00, 0x00
  ))
  mapping_file:close()

  local explorer = require('vv-explorer')
  explorer.setup({
    state = mapping_handle,
    persist_open = false,
    cwd = mapping_root,
    preview = false,
    watch = false,
    follow_file = false,
    git = false,
    diagnostics = false,
    trash = false,
    global_mappings = false,
  })
  explorer.open()

  local explorer_buf = vim.api.nvim_get_current_buf()
  assert(vim.bo[explorer_buf].filetype == 'vv-explorer', '映射夹具未打开 explorer buffer')

  local function find_mapping(mode, lhs)
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(explorer_buf, mode)) do
      if mapping.lhs == lhs then return mapping end
    end
  end
  return { explorer = explorer, explorer_buf = explorer_buf, find_mapping = find_mapping, mapping_binary = mapping_binary }
end

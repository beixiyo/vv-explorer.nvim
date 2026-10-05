local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["长路径 loading 覆盖图标槽且保持字符边界，不向不可见路径写帧"] = function()
  child.lua_func(function()
    -- 等待 LSP 时的 loading 落点：真实 render + 真实 vv-utils.loading
    --
    -- 能捕获的失败：
    --   * 帧画在行尾（eol）：长名字的行尾会被窗口截掉，用户看不到 loading
    --   * 用「name_col - 2」当图标槽：图标是多字节 nerd glyph，字节列 -2 落在 glyph 中间，
    --     overlay 盖不住图标、或把名字首字符盖掉
    --   * 根行（无图标槽）或不可见路径仍画帧

    local root = vim.env.VV_TEST_REPO

    local Loading = require('vv-utils.loading')
    local Render = require('vv-explorer.render')
    local Tree = require('vv-explorer.tree')

    local temporary = vim.fn.tempname()
    local long_name = string.rep('very_long_component_', 8) .. 'name.lua'
    vim.fn.mkdir(temporary .. '/nested', 'p')
    vim.fn.writefile({ 'return 1' }, temporary .. '/' .. long_name)
    vim.fn.writefile({ 'x' }, temporary .. '/nested/inner.ts')

    local buf = vim.api.nvim_create_buf(false, true)
    local state = { root = Tree.new_root(temporary), buf = buf, opts = {} }
    Tree.expand_to(state.root, temporary .. '/nested/inner.ts')
    Render.render(state)

    ---@param path string
    ---@return integer row, integer col
    local function overlay_at(path)
      local handle = Loading.mark({
        buf = buf,
        get_pos = function() return Render.icon_slot_pos(state, path) end,
        pos = 'overlay',
        width = Render.ICON_SLOT_COLS,
      })
      local found
      assert(vim.wait(1000, function()
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
          if mark[4].virt_text_pos == 'overlay' then
            found = mark
            return true
          end
        end
        return false
      end, 10), '必须为目标绘制 loading 帧：' .. path)
      handle:stop()

      -- 帧与补齐空格分段上色，宽度按全部分段计算
      local text = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, found[4].virt_text))
      assert(vim.fn.strdisplaywidth(text) == Render.ICON_SLOT_COLS, 'overlay 宽度必须恰好等于图标槽')
      return found[2] + 1, found[3]
    end

    for _, path in ipairs({ temporary .. '/' .. long_name, temporary .. '/nested/inner.ts' }) do
      local row, col = overlay_at(path)
      local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
      local name_col = state.name_cols[row]

      assert(row == state.path_to_row[path], 'overlay 必须位于改名路径所在行')
      assert(col < name_col, 'overlay 必须位于名字前，不得画在行尾')
      -- 字节列必须落在字符边界上，且槽位到名字之间恰好是图标槽的显示宽度
      assert(vim.str_utf_start(line, col + 1) == 0, 'overlay 列必须落在字符边界')
      local width = vim.fn.strdisplaywidth(line:sub(col + 1, name_col))
      assert(width == Render.ICON_SLOT_COLS, ('overlay 必须覆盖图标槽，实际覆盖 %d 列'):format(width))
    end

    assert(Render.icon_slot_pos(state, temporary) == nil, '根目录行必须没有图标槽')
    assert(Render.icon_slot_pos(state, temporary .. '/missing') == nil, '不可见路径必须没有图标槽')

    vim.fn.delete(temporary, 'rf')
  end)
end

return T

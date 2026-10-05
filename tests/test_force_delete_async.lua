local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["永久删除期间事件循环推进、图标槽 loading、失败停止与关闭取消"] = function()
  child.lua_func(function()
    -- D 永久删除走分片异步删除：真实 panel + 真实 render + 真实 vv-utils.loading，只替换确认框
    --
    -- 能捕获的失败：
    --   * 先显示 loading 再同步递归删除：实际目录删除过程中没有多次事件循环交错
    --   * 帧不在被删项的图标槽（画到行尾 / 别的行），或刷新把项移除后帧残留
    --   * 多选删除首个失败后仍继续删除后续目标，或失败后帧不撤
    --   * 删除进行中再次 D 同一路径又弹确认、重复删除
    --   * 面板关闭后在途删除仍继续并回写 explorer buffer

    local uv = vim.uv
    local Render = require('vv-explorer.render')

    local pending_confirm
    require('vv-utils.confirm').open = function(opts)
      pending_confirm = opts
      return { close = function() end }
    end

    local notes = {}
    vim.notify = function(message, level)
      notes[#notes + 1] = { message = message, level = level }
    end

    local ROOT = vim.fs.normalize(vim.fn.tempname())

    ---@param dir string
    ---@param dirs integer
    ---@param files integer
    local function populate(dir, dirs, files)
      for d = 1, dirs do
        vim.fn.mkdir(dir .. '/d' .. d, 'p')
        for f = 1, files do
          uv.fs_close(assert(uv.fs_open(dir .. '/d' .. d .. '/f' .. f, 'w', 420)))
        end
      end
    end

    local BIG = ROOT .. '/big-dir'
    populate(BIG, 40, 500)
    vim.fn.writefile({ 'x' }, ROOT .. '/keep.txt')

    -- 通过公开预算强制真实删除分片；只控制首个大目录，后续失败/关闭仍用真实默认预算
    local Fs = require('vv-utils.fs')
    local delete_async = Fs.delete_async
    local sliced_big = false
    Fs.delete_async = function(path, opts)
      if vim.fs.normalize(path) == BIG then
        sliced_big = true
        opts = vim.tbl_extend('force', {}, opts, { budget_ms = 0 })
      end
      return delete_async(path, opts)
    end

    local explorer = require('vv-explorer')
    local store = {}
    explorer.setup({
      state = {
        get = function(_, key, default)
          if store[key] == nil then return default end
          return store[key]
        end,
        set = function(_, key, value) store[key] = value; return true end,
      },
      persist_open = false,
      cwd = ROOT,
      preview = false,
      watch = false,
      follow_file = false,
      git = false,
      diagnostics = false,
      trash = false,
      global_mappings = false,
    })
    explorer.open()
    local buf = vim.api.nvim_get_current_buf()
    local win = vim.api.nvim_get_current_win()
    assert(vim.bo[buf].filetype == 'vv-explorer', '前置：explorer buffer 应打开')

    local function press(lhs)
      for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
        if mapping.lhs == lhs then return mapping.callback() end
      end
      error('未找到映射：' .. lhs)
    end

    ---@param name string
    ---@return integer? row 1-based
    ---@return integer? name_col 0-based 字节列
    local function row_of(name)
      for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        local col = line:find(name, 1, true)
        if col and row > 1 then return row, col - 1 end
      end
    end

    local function focus(name)
      local row = assert(row_of(name), '前置：树上应有 ' .. name)
      vim.api.nvim_win_set_cursor(win, { row, 0 })
    end

    local function loading_marks()
      local result = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        local chunk = mark[4].virt_text and mark[4].virt_text[1]
        if chunk and chunk[2] == 'VVLoading' then
          result[#result + 1] = { row = mark[2] + 1, col = mark[3], pos = mark[4].virt_text_pos }
        end
      end
      return result
    end

    local function find_note(pattern, level)
      for _, note in ipairs(notes) do
        if note.message:find(pattern) and (level == nil or note.level == level) then return note end
      end
    end

    local function wait(ms) vim.wait(ms, function() return false end, 5) end

    -- 1：大目录删除期间主线程不被独占，帧盖在被删项的图标槽；完成刷新后项与帧一起消失
    focus('big-dir')
    press('D')
    assert(pending_confirm and pending_confirm.title == 'Delete item?', 'D 应弹出永久删除确认')
    wait(200)
    assert(#loading_marks() == 0, '确认前不得显示帧')

    local partial_progress, previous_remaining = 0, 40
    local ticker = assert(uv.new_timer())
    ticker:start(1, 1, vim.schedule_wrap(function()
      local remaining = 0
      for directory = 1, 40 do
        if uv.fs_stat(BIG .. '/d' .. directory) then remaining = remaining + 1 end
      end
      -- 必须观察到多个不同的真实部分删除状态；开始前空转、一次长阻塞后全删不算进展
      if remaining > 0 and remaining < previous_remaining then
        partial_progress = partial_progress + 1
      end
      previous_remaining = remaining
    end))

    local confirm = pending_confirm.on_confirm
    pending_confirm = nil
    confirm()

    local seen_in_slot = false
    local reentry_checked = false
    assert(vim.wait(60000, function()
      if uv.fs_stat(BIG) then
        local marks = loading_marks()
        local row, name_col = row_of('big-dir')
        if #marks == 1 and row and marks[1].row == row and marks[1].pos == 'overlay' then
          local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
          local covered = vim.fn.strdisplaywidth(line:sub(marks[1].col + 1, name_col))
          seen_in_slot = covered == Render.ICON_SLOT_COLS
        end

        -- 删除进行中再次 D 同一路径：提示在途，不再弹确认
        if seen_in_slot and not reentry_checked then
          reentry_checked = true
          focus('big-dir')
          press('D')
        end
      end
      return find_note('^Deleted') ~= nil
    end, 5), '删除完成后应通知 Deleted')
    ticker:stop()
    ticker:close()
    Fs.delete_async = delete_async

    assert(not uv.fs_stat(BIG), '大目录应被删除')
    assert(sliced_big, '前置：首个大目录必须经过公开分片预算')
    assert(partial_progress >= 2, '实际删除过程中必须多次让事件循环观察不同的部分完成状态；先让出再同步长阻塞也应失败')
    assert(uv.fs_stat(ROOT .. '/keep.txt'), '只删除目标路径')
    assert(seen_in_slot, '删除期间帧应以 overlay 恰好盖住 big-dir 的图标槽')
    assert(reentry_checked, '前置：删除期间应完成重入检查')
    assert(pending_confirm == nil, '删除进行中再次 D 同一路径不得再弹确认')
    assert(find_note('delete already in progress', vim.log.levels.WARN), '删除进行中再次 D 应提示在途')
    assert(row_of('big-dir') == nil, '完成后的刷新应把项从树上移除')
    assert(#loading_marks() == 0, '刷新把项移除后帧必须消失')

    -- 2：多选顺序删除，首个失败即报错并停止，帧立即撤掉，后续目标不删，已删部分不回滚
    local BIG_FIRST = ROOT .. '/a-big'
    populate(BIG_FIRST, 40, 500)
    local BAD = ROOT .. '/b-bad'
    local LOCKED = BAD .. '/locked'
    vim.fn.mkdir(LOCKED, 'p')
    vim.fn.writefile({ 'x' }, LOCKED .. '/stuck.txt')
    vim.fn.setfperm(LOCKED, 'r-xr-xr-x')
    local AFTER = ROOT .. '/c-after'
    vim.fn.mkdir(AFTER, 'p')
    vim.fn.writefile({ 'x' }, AFTER .. '/inner.txt')
    press('R')

    notes = {}
    for _, name in ipairs({ 'a-big', 'b-bad', 'c-after' }) do
      focus(name)
      press('<Tab>')
    end
    press('D')
    assert(pending_confirm and pending_confirm.title == 'Delete items?', '多选 D 应确认删除多项')
    confirm = pending_confirm.on_confirm
    pending_confirm = nil
    confirm()

    local seen_all_frames = false
    assert(vim.wait(60000, function()
      if #loading_marks() == 3 then seen_all_frames = true end
      return find_note('delete errors', vim.log.levels.ERROR) ~= nil
    end, 5), '失败应以 ERROR 报告')
    assert(seen_all_frames, '删除期间每个被删项都应显示帧')
    assert(find_note('stuck%.txt', vim.log.levels.ERROR), '错误信息应指出失败的文件')
    assert(#loading_marks() == 0, '失败后帧必须立即撤掉')
    assert(not uv.fs_stat(BIG_FIRST), '失败前已删除的目标不回滚')
    assert(row_of('a-big') == nil, '失败后的刷新应移除已删除的项')
    assert(uv.fs_stat(LOCKED .. '/stuck.txt'), '前置：只读目录中的文件删不掉')
    assert(uv.fs_stat(AFTER .. '/inner.txt'), '首个失败后不得继续删除后续目标')
    assert(not find_note('^Deleted'), '失败时不得通知成功')
    vim.fn.setfperm(LOCKED, 'rwxr-xr-x')

    -- 3：面板关闭取消在途删除，之后不再回写 explorer buffer
    local LATE = ROOT .. '/late-dir'
    populate(LATE, 40, 500)
    press('R')
    notes = {}
    focus('late-dir')
    press('D')
    confirm = pending_confirm.on_confirm
    pending_confirm = nil
    confirm()
    assert(vim.wait(5000, function() return #loading_marks() == 1 end, 5), '前置：删除期间应显示帧')

    vim.cmd('vsplit')
    explorer.close()
    assert(not explorer.is_open(), '前置：面板应已关闭')
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    wait(1500)
    assert(#loading_marks() == 0, '面板关闭后帧必须停止')
    assert(uv.fs_stat(LATE), '面板关闭后在途删除应被取消')
    assert(vim.api.nvim_buf_get_changedtick(buf) == tick, '面板关闭后不得回写 explorer buffer')
    assert(not find_note('^Deleted'), '取消后不得通知删除完成')
    assert(find_note('delete interrupted', vim.log.levels.WARN), '取消应提示删除被中断')

    vim.fn.delete(ROOT, 'rf')
  end)
end

return T

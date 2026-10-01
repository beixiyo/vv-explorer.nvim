-- 单个测试文件的执行外壳：测试文件正常跑完才写完成标记
--
-- headless nvim 在测试中途遇到需要交互的提示（如 W12）或被 :qa 退出时，退出码仍可能是 0，
-- 光看退出码会把「没跑完」误判为 PASS；run.sh 因此还要求标记文件存在
local test_file, marker = arg[1], arg[2]
dofile(test_file)
vim.fn.writefile({ 'done' }, marker)

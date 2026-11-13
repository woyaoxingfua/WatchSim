-- watchsim 入口桥。
-- AstroFace 的真机入口是 main.lua（由固件直接执行）；watchsim 约定表盘入口
-- 返回 {start=}，这里把约定对齐。AOD 表盘是真机上另一个工程，此处不区分
-- aod 参数，两种模式都渲染亮屏界面。
local M = {}

function M.start(_aod)
    dofile((SCRIPT_PATH or "") .. "main.lua")
end

return M

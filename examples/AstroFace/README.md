# AstroFace · 内置示例表盘

小米手环 9 Pro（336×480）星象表盘，作者自研（版权与作者无关第三方，
可安全用作演示与回归测试）。真机入口是 `main.lua`；本目录中的
`face.lua` 只是把真机入口适配到 watchsim 的 `{start=}` 约定。

## 结构

- `main.lua`     入口：状态机 + 渲染调度（亮屏）
- `config.lua`   布局/样式/主题
- `canvas.lua`   软画布：月相/星点/云遮月在对象池矩形上逐格光栅化
- `moon.lua`     月相计算
- `icons.lua` / `icons_dot.lua`  天气图标（点阵墨点版）
- `res_map.lua`  预渲染 PNG 资源映射（汉字/图标/数字，`res/*.png`）
- `res/`         预渲染位图资源

## 版权说明

表盘代码与渲染管线为作者原创。字形由开源字体渲染
（[Ark Pixel](https://github.com/TakWolf/ark-pixel-font)、Cubic 11、
[Galmuri](https://github.com/quiple/galmuri)），位图来自这些字体的
渲染结果，随表盘分发遵循其各自许可证。

## 与真机的差异

- `SCRIPT_PATH` 由 watchsim 以表盘目录注入，与真机固件注入行为一致。
- 数据仍来自 dataman 桩：时间/日期走面板注入，月相由 `dateMonth/Day`
  推算；天气字段未注入时走"新月/静夜"等缺省分支。
- 真机的 AOD 是独立表盘工程，未随示例打包：`MODE 1` 下渲染的仍是
  亮屏界面。

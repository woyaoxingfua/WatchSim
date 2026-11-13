# AstroFace

内置示例表盘：小米手环 9 Pro（336×480）星象表盘，作者本人写的，
仓库拿它做演示和回归测试。真机入口是 `main.lua`，这里的 `face.lua`
只是把它桥接到 watchsim 的 `{start=}` 约定。

文件说明：

- `main.lua` — 入口，状态机和渲染调度
- `config.lua` — 布局/样式/主题
- `canvas.lua` — 软画布：月相/星点/云遮月在对象池矩形上逐格光栅化
- `moon.lua` — 月相计算
- `icons.lua` / `icons_dot.lua` — 天气图标（点阵墨点版）
- `res_map.lua` + `res/` — 预渲染 PNG（汉字/图标/数字）

渲染分工：汉字、天气图标、数字走预渲染 PNG，`lvgl.Image` 只改 src 和
坐标，C 层 blit；月相是连续相位没法预渲染，由软画布每分钟全量重绘。

版权：表盘代码原创。字形来自开源字体（[Ark Pixel](https://github.com/TakWolf/ark-pixel-font)、
Cubic 11、[Galmuri](https://github.com/quiple/galmuri)）的渲染结果，
分发时遵循其各自许可证。

和真机的差异：

- `SCRIPT_PATH` 由 watchsim 注入表盘目录，行为和固件一致。
- 数据来自 dataman 桩：时间/日期走面板注入，月相由日期推算；天气字段
  没注入时走"新月/静夜"等缺省分支。
- 真机 AOD 是另一个表盘工程，没打包进来；`MODE 1` 下渲染的仍是亮屏。

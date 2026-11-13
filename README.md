# WatchSim · 通用 headless Lua 表盘模拟器

在没有手环硬件的情况下，用**真实的 LVGL 引擎离屏渲染**小米手环 Lua 表盘，
并通过浏览器控制面板手动注入数据（时间、日期、电量、步数……），即时预览效果。
整个核心是 headless 的内存渲染，不依赖显示服务器，天然跨平台——任何能跑
C / Python 的主机（含云主机）都能运行，浏览器即可访问。

## 特性

- **真实 LVGL 8.3 离屏渲染**：不是几何近似，而是完整的 LVGL 绘制管线
  （样式、图层、抗锯齿、图片旋转/缩放、动画），输出 336×480 RGBA 帧。
  图片支持 LVGL `.bin` 与 **PNG**（内置 lodepng 解码器）。
- **未改动的表盘直接运行**：`face.lua` 原样加载，只在底层用适配层实现
  `lvgl` / `dataman` 两个模块，表盘代码无感知。
- **内置示例表盘**：`examples/AstroFace`（作者原创的 9 Pro 星象表盘），
  clone 即可渲染，无版权顾虑。
- **数据注入面板**：`dataman` 桩把面板指令转成与真机一致的 8.8 定点回调，
  支持哨兵（INT_MAX）、NaN、有符号值等边界数据，用于验证防御逻辑。
- **亮屏 / AOD 双模式**：复刻真机"AOD 不调度 Lua 动画"、AOD 数据去重等限制。
- **长驻核心 + Web 面板**：C 进程通过 stdio 行协议通信，aiohttp 提供
  WebSocket 控制面板，单连接推送 PNG，浏览器零插件。
- **可重复回归**：一条命令跑通动画、渲染、注入、stdio、WebSocket 全链路。

## 架构与数据流

```
 浏览器 (index.html)
   │  JSON 控制指令            ▲ PNG 帧 (WebSocket)
   ▼                           │
 aiohttp  web/server.py  ──  web/sim_client.py (状态快照/模式重放)
   │
   │  stdio 行协议 (INJECT/MODE/FRAME/...)
   ▼
 sim_server (C, 长驻)
   ├── sim_bridge   Lua 绑定 (full userdata + metatable)
   ├── mi_lvgl.lua / mi_dataman.lua   小米 API 适配
   └── face.lua (未改动的表盘)
            │
            ▼
   真实 LVGL 8.3 ── 自注册 headless display ── 内存 framebuffer (RGBA)
```

## 目录结构

```
watchsim/
├── CMakeLists.txt          构建定义
├── config/lv_conf.h        headless 专用 LVGL 配置
├── patches/
│   └── lvgl-decoder-fullread.patch   LVGL 8.3 真彩文件整图读取修复（见下）
├── tools/
│   └── fetch_deps.sh       拉取依赖并打补丁（首次构建前运行一次）
├── deps/                   第三方依赖（由脚本生成，不入库）
│   ├── lvgl/               LVGL 8.3.11
│   └── lua/                Lua 5.3.6 + 自编译 liblua.a
├── core/                   离屏显示与宿主程序
│   ├── sim_display.c/.h    内存 framebuffer、headless display、tick/pump
│   ├── sim_server.c        长驻核心，stdio 行协议
│   ├── run_face.c          一次性渲染表盘（CLI）
│   ├── diag_pos.c          几何/旋转诊断
│   ├── test_headless.c     离屏渲染冒烟
│   └── test_anim.c         动画推进验证
├── bridge/
│   └── sim_bridge.c/.h     Lua ↔ LVGL C 桥（simcore 原生模块）
├── lua/
│   ├── mi_lvgl.lua         小米风格 lvgl 封装（Object/Image/Anim/flag/event）
│   └── mi_dataman.lua      dataman 桩（订阅/注入/哨兵/NaN/AOD 去重）
├── web/
│   ├── server.py           aiohttp + WebSocket 服务
│   ├── sim_client.py       sim_server 的 Python 客户端封装
│   └── index.html          控制面板前端
├── examples/
│   └── AstroFace/          内置示例表盘（作者原创，含入口桥接与说明）
└── tests/
    ├── inject_basic.lua    示例注入快照
    ├── smoke_server.py     stdio 核心冒烟
    └── run_all_tests.py    全链路回归
```

`deps/` 内容不入库，由 `tools/fetch_deps.sh` 按固定版本拉取并打补丁，
保证任何机器上都能复现同一份构建输入。

## 依赖与构建

主机需要 git、gcc、cmake、ninja/make；Python 3.10+ 与 `aiohttp`、`pillow`、
`numpy`。无需 SDL、无需系统级 LVGL/Lua。

```bash
cd watchsim

# 1. 一次性拉取 LVGL 8.3.11 / Lua 5.3.6 并应用解码器补丁
bash tools/fetch_deps.sh

# 2. Python 依赖（Web 面板与回归测试用）
python3 -m pip install aiohttp pillow numpy

# 3. 构建
cmake -S . -B build/cmake -G Ninja    # 或默认 Make
cmake --build build/cmake -j
```

## 运行

模拟器需要一个**表盘目录**作为输入：包含入口 `face.lua`（真机入口是
`main.lua` 的表盘，由目录内的 `face.lua` 桥接到 sim 约定，见示例）。
仓库自带 `examples/AstroFace`，clone 即可渲染；其他表盘通过环境变量
`WATCHSIM_FACE`、`web/server.py --face-dir` 或 CLI 传参指定。

### Web 控制面板（推荐）

```bash
python3 web/server.py --host 0.0.0.0 --port 8137
# 默认渲染内置示例表盘；换表盘：
#   export WATCHSIM_FACE=/path/to/face_dir  或  --face-dir /path/to/face_dir
# 浏览器打开 http://<主机>:8137/
```

面板提供时间/日期/设备三组滑块与数字输入，切换亮屏/AOD，并可对任意字段
注入哨兵或 NaN。每次改动后自动出帧。

### CLI 一次性渲染

```bash
# 内置示例表盘
./build/cmake/run_face examples/AstroFace examples/AstroFace/ 0 out.raw tests/inject_basic.lua
# 其他表盘（亮屏 + 注入；AOD 把 0 换成 1）
./build/cmake/run_face <face_dir> <face_dir>/ 0 out.raw tests/inject_basic.lua
```

### 回归测试

```bash
python3 tests/run_all_tests.py        # 8/8 PASS（默认渲染内置示例表盘）
```

## stdio 行协议（sim_server）

| 命令 | 说明 |
|------|------|
| `MODE <0|1>` | 重新加载表盘并切换亮屏/AOD，随后重放当前数据快照 |
| `INJECT_INT <key> <int>` | 注入整数（内部按 8.8 编码） |
| `INJECT <key> <raw>` | 注入原始定点值 |
| `SENTINEL <key>` / `NAN <key>` | 注入缺测哨兵 / NaN |
| `TICK <ms>` | 推进虚拟时钟并处理定时器 |
| `DOFILE <path>` | 执行一段 Lua（批量注入/脚本化） |
| `FRAME` | 回 `FRAME <n>` 头 + 645120 字节 RGBA |
| `QUIT` | 退出 |

## 保真度边界（客观说明）

**真实模拟的部分**：LVGL 完整绘制与布局、对象/样式/标志、图片解码与旋转
缩放、`lv_anim` 动画随 tick 推进、AOD 动画抑制与数据去重、8.8 定点与哨兵/
有符号编码。

**为 headless 做的取舍与已知限制**：

- 数据由面板手动注入，而非真实传感器；`dataman` 是行为等价的桩，不是系统服务。
- 帧按需渲染（`lv_timer_ready` 强制刷新），不等待真机的 30 ms 刷新周期；
  虚拟时钟只在 `TICK` 时推进，wall-clock 与真机不完全等速。
- 触摸/设置页交互目前未在面板暴露（面板聚焦数据注入）；`DOFILE` 可脚本化
  间接驱动。
- 表盘内若用到未实现的 LVGL 特性，会在适配层显式报错而非静默忽略。

### 一处必要的 LVGL 解码器修复

LVGL 8.3 对文件型真彩图默认逐行（每行 1px）读取，而旋转需要完整源图，
导致 headless 下旋转指针零像素。补丁 `patches/lvgl-decoder-fullread.patch`
将 `lv_img_decoder.c` 的真彩文件分支改为整图读入内存（与 ALPHA_8BIT 分支
同法），并在 close 时统一释放整图缓冲。该改动只影响文件读取方式，
不改变绘制结果。`tools/fetch_deps.sh` 会在拉取 LVGL 后自动应用该补丁。

## 许可证

[MIT](LICENSE)。`deps/` 下拉取的 LVGL（MIT）与 Lua（MIT）遵循其各自许可证，
补丁后源码仍属 MIT 范畴。

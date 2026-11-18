# WatchSim · headless Lua 表盘模拟器

没有手环也能调小米手环的 Lua 表盘：PC 上用真实 LVGL 离屏渲染，
网页面板手动注入时间、日期、电量这些数据，改完立刻出帧。核心是
headless 内存渲染，不依赖显示服务，能跑 C 和 Python 的机器（包括
云主机）都能用，跑起来之后浏览器远程访问。

## 它做了什么

- 出图走完整的 LVGL 8.3 绘制管线，样式、图层、抗锯齿、图片旋转缩放、
  动画都是真的，输出 336×480 RGBA 帧。`.bin` 和 png 资源都能解码。
- 表盘代码原样运行：`lvgl` / `dataman` 两个模块由适配层模拟，真机入口
  是 `main.lua` 的表盘加一个 `face.lua` 薄壳桥接就行，`examples/AstroFace`
  就是这么接进来的。
- 注入数据按真机的 8.8 定点编码，可以给任意字段塞缺测哨兵（INT_MAX）、
  NaN、有符号值，专门用来测表盘的防御逻辑。
- 有些表盘不走 dataman，直接 `io.open("/dev/uorb/sensor_compass0")` 读
  原始传感器节点（指南针地磁、GPS）。这类节点在模拟器里是虚拟的：
  `uorb.open` 返回桩句柄，`read("*a")` 吐最新一帧（小端二进制，帧格式
  同固件），面板"传感器"组或 `SENSOR` 命令注入数据。
- 真机的几个限制也照搬：AOD 不调度 Lua 动画、AOD 数据去重。
- C 核心 `sim_server` 常驻，走 stdio 行协议；aiohttp 服务把帧编成 PNG
  从 WebSocket 推给浏览器。
- 回归测试一条命令，动画、渲染、注入、stdio、WebSocket 五层都覆盖。

## 架构

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

## 目录

```
watchsim/
├── CMakeLists.txt
├── config/lv_conf.h        LVGL headless 配置
├── patches/                LVGL 解码器补丁（见文末说明）
├── tools/fetch_deps.sh     拉依赖 + 打补丁
├── deps/                   脚本生成的第三方依赖，不入库
├── core/                   离屏显示、宿主程序、诊断工具
├── bridge/                 Lua ↔ LVGL C 桥
├── lua/                    mi_lvgl.lua / mi_dataman.lua 适配层
├── web/                    aiohttp 服务 + 面板前端
├── examples/AstroFace/     内置示例表盘（作者原创）
└── tests/                  回归测试
```

`deps/` 不入库，`tools/fetch_deps.sh` 按固定版本（LVGL v8.3.11、
Lua 5.3.6）拉取并打补丁，保证每台机器拿到同一份构建输入。

## 构建

```bash
bash tools/fetch_deps.sh                # 一次即可，含解码器补丁
python3 -m pip install aiohttp pillow numpy   # Python 3.10+
cmake -S . -B build/cmake               # 需要 gcc、cmake、make
cmake --build build/cmake -j
```

不需要 SDL，也不需要系统装过 LVGL/Lua。

## 运行

表盘目录是唯一输入：里面要有入口 `face.lua`。不带参数时，面板和测试
都用内置的 `examples/AstroFace`；换自己的表盘用 `WATCHSIM_FACE` 环境变量
或 `--face-dir`。

```bash
python3 web/server.py --host 0.0.0.0 --port 8137
# 浏览器打开 http://<主机>:8137/
```

面板上有时间/日期/电量/步数的控件，可切亮屏/AOD，任意字段都能注入
哨兵或 NaN，每次改动自动出帧。

命令行直接出一帧：

```bash
./build/cmake/run_face examples/AstroFace examples/AstroFace/ 0 out.raw tests/inject_basic.lua
# 用法：run_face <face_dir> <face_dir>/ <aod 0/1> <out.raw> [inject.lua]
```

回归测试：

```bash
python3 tests/run_all_tests.py
```

## stdio 行协议（sim_server）

| 命令 | 说明 |
|------|------|
| `MODE <0|1>` | 重载表盘并切换亮屏/AOD，重放当前数据快照 |
| `INJECT_INT <key> <int>` | 注入整数（内部按 8.8 编码） |
| `INJECT <key> <raw>` | 注入原始定点值 |
| `SENTINEL <key>` / `NAN <key>` | 注入缺测哨兵 / NaN |
| `TICK <ms>` | 推进虚拟时钟并处理定时器 |
| `SENSOR <node> <field> <float>` | 注入虚拟 uorb 传感器字段（如 `SENSOR compass y 45.0`），随后自动 tick 250ms 让表盘轮询到 |
| `DOFILE <path>` | 执行一段 Lua（批量注入/脚本化） |
| `FRAME` | 回 `FRAME <n>` 头 + 645120 字节 RGBA |
| `QUIT` | 退出 |

## 和真机的差异

绘制与布局、对象/样式/标志、图片解码与旋转缩放、`lv_anim` 随 tick
推进、AOD 动画抑制与数据去重、8.8 定点与哨兵/有符号编码，这些和真机
一致。有出入的地方：

- 数据是手动注入的，`dataman` 是行为等价的桩，不是系统服务；uorb
  传感器节点同样是虚拟的，`read` 返回最新一帧而非真机的采样队列。
- 文本控件 `lvgl.Label` 可用，但字体是内置 montserrat 按字号就近映射，
  不是真机的 MiSans——字形外观有差异，排布与测量行为一致。
- 帧按需渲染（`lv_timer_ready` 强制刷新），不等真机的 30ms 刷新周期；
  虚拟时钟只在 `TICK` 时推进，和真机不等速。
- 触摸/设置页交互没在面板上暴露，需要的话用 `DOFILE` 脚本驱动。
- 表盘用到没实现的 LVGL 特性时，适配层直接报错，不静默跳过。

## 一处 LVGL 补丁

LVGL 8.3 对文件型真彩图默认逐行读取（每次 1px），而旋转需要完整源图，
所以 headless 下旋转图片会渲染出零像素。`patches/lvgl-decoder-fullread.patch`
把真彩文件分支改成整图读入内存（和 ALPHA_8BIT 分支同法），close 时统一
释放。只改了读取方式，绘制结果不变。`fetch_deps.sh` 拉完依赖会自动打上。

## 许可证

MIT，见 [LICENSE](LICENSE)。`deps/` 下的 LVGL、Lua 保持各自的原许可证。

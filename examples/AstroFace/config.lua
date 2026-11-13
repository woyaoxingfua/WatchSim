--[[
AstroFace 全局配置模块（点阵「墨点」版）

说明：
    集中放置所有可调参数，改这一个文件即可调整布局、配色、昼夜判定阈值。
    布局单位一律为逻辑像素（336x480），与 design/index.html 原型一一对应。

    Mi Band 9 Pro 屏幕为 336 x 480 圆角矩形 AMOLED。

样式切换（v1.1）：
    C.STYLE 取值 "default" / "amber" / "minimal"，对应 C.STYLES 中同名的预设。
    改 C.STYLE 一行字符串，整张表盘的配色 + halo + 星点开关整体切换。
    各预设允许覆盖 COLOR 表与 halo/ambient 开关；不在预设里的字段沿用主表。
--]]

---@class Config
local C = {}

-- ============================================================
-- 设备与布局（与原型 render() 逐项对应）
-- ============================================================

C.SCREEN_W = 336
C.SCREEN_H = 480

C.LAYOUT = {
    -- 顶部：公历日期（PNG 3x5 数字，每点 4px -> 字符 12x20，间距 4）
    date_y       = 10,
    date_gap     = 4,

    -- 星期 7 点
    week_y       = 44,
    week_x0      = 120,   -- 首点圆心 X
    week_gap     = 16,    -- 点间距

    -- 主舞台：28x28 点阵格（步进 8px = 224px），白天贴天气 PNG / 夜晚软画布月相
    stage_x      = 56,    -- 舞台左上角
    stage_y      = 48,
    stage_grid   = 28,    -- 格数
    stage_step   = 8,     -- 每格像素
    moon_cx      = 112,   -- 月心（舞台画布内坐标）
    moon_cy      = 112,
    moon_r       = 88,    -- 月面半径（px）

    -- 名称行：天气名 / 月相名（48px 汉字）+ 温度（9x15 数字）
    -- 给名称与时间留出呼吸感；时间行在 star 布局下改用 48px 字。
    name_y       = 284,
    name_gap     = 2,     -- 汉字间距
    name_temp_gap = 14,   -- 汉字与温度的间隔
    temp_bottom  = 317,   -- 温度数字底部（与汉字底对齐）

    -- 汉字时间：两行中式（小时行 / 分钟行），star 布局使用 48px 字。
    -- 让名称、时间和底部边缘之间各保留约 8~30px 的留白。
    time1_y      = 344,
    time2_y      = 398,
    time_gap     = 2,     -- 汉字间距
}

-- ============================================================
-- 三套布局（v1.5+）：长按循环切换原本想做，几何单位一律屏幕坐标
-- 实机问题：米环系统长按 0.7s 进入编辑表盘（固件级），Lua 自定义长按无法截留，
-- 抢系统事件会让表盘"无法编辑"，且 lvgl.tick_get 在 9 Pro 真机不存在导致崩溃。
-- 见 main.lua 启动段。TIME / CYCLE 渲染代码保留，等找到非 0.7s 的切换入口再启用。
-- ============================================================

-- 当前默认布局与切换顺序（布局切换由配套快应用写入配置文件）
C.LAYOUT_STYLE = "star"                        -- "star" / "time" / "cycle"
C.LAYOUT_ORDER = { "star", "time", "cycle" }   -- 长按循环顺序（暂未启用）
C.LONG_PRESS_MS = 800                          -- 长按判定时长（毫秒，暂未启用）

-- 旧版布局持久化入口（当前由快应用配置桥负责）
C.PERSIST = {
    enabled = false,
    path    = "/data/astroface_layout",
}

-- ============================================================
-- 快应用配置桥（v1.6+）：配套快应用 com.astroface.config 用 @system.file
-- 把 key=value 写到 internal://files/astroface_config.txt（映射到
-- /data/quickapp/files/com.astroface.config/astroface_config.txt），
-- 表盘用 io.open 轮询读取（io.open 真机可用，lvgl.fs 未验证不用）。
-- 格式：layout=star / style=amber / v=1，逐行 key=value，非法值忽略。
-- ============================================================
C.CONFIG = {
    enabled    = true,
    path       = "/data/quickapp/files/com.astroface.config/astroface_config.txt",
    poll_ticks = 30,               -- 每 30 次 1s tick 读一次文件（30 秒）
}

-- TIME「时迹」：时间为主角。汉字时间占上半屏 + 24h 进度条 + 小月相。
-- 小月 R=36 用 3px 细网格（否则半月亮呈块状不圆），月心为屏幕坐标。
C.LAYOUT_TIME = {
    time1_y  = 64,     -- 时间第一行（72px 大字）
    time2_y  = 136,    -- 时间第二行（= time1_y + 72）
    time_gap = 2,      -- 汉字间距
    bar_y    = 252,    -- 24h 进度条（40 点，x = 24 + i*5，点径 2）
    bar_n    = 40,
    moon_cx  = 168,    -- 小月心（屏幕坐标）
    moon_cy  = 330,
    moon_r   = 36,
    moon_step = 3,     -- 小月细网格步进（整格填充，够细才不块状）
    name_y   = 390,    -- 名称行
    temp_bottom = 423, -- 温度与 TIME 名称行对齐（不能沿用 star 的 317）
}

-- CYCLE「朔望」：30 点朔望环为主角，环心微缩月相，今日位置高亮。
-- CYCLE 的三组文字统一按 48px 点阵字图排布：名称、距望、时间彼此留出
-- 清晰间隔，第二行时间底部留 2px 安全边距。
C.LAYOUT_CYCLE = {
    ring_cx  = 168,    -- 朔望环心（屏幕坐标）
    ring_cy  = 172,
    ring_r   = 78,     -- 环半径
    moon_r   = 34,     -- 环心小月半径
    moon_step = 3,     -- 小月细网格步进（整格填充）
    name_y   = 270,    -- 名称行
    dist_y   = 324,    -- 距望行（"距望 N 天"）
    time1_y  = 380,    -- 时间第一行（48px 小字）
    time2_y  = 430,    -- 时间第二行（与第一行保持最小间隙）
    time_gap = 2,
}

-- ============================================================
-- 多套样式预设（v1.1+）
-- ============================================================

---@type "default"|"amber"|"minimal"
C.STYLE = "default"

-- 默认色板（与原型 PAL 完全一致），其他样式在此基础上覆盖
local DEFAULT_COLOR = {
    bg = 0x000000,               -- AMOLED 纯黑，不发光最省电

    day = {
        text   = 0xE9EEF6,        -- 主文字
        dim    = 0x57627A,        -- 日期数字
        faint  = 0x1C2331,        -- 星期未激活点
        glow   = 0xFF9D3C,        -- 晴类辉光
        accent = 0xFFC46B,        -- 强调色（进度条已走段/朔望环望点/意境字）
        bar    = 0x7E8CAD,        -- 进度条已走段 / 朔望环普通点
        barOff = 0x161C29,        -- 进度条未走段
    },
    night = {
        text   = 0xDCE4F5,
        dim    = 0x46516B,
        faint  = 0x141A27,
        star   = 0x334061,        -- 星点
        glow   = 0x92ABE8,
        accent = 0x92ABE8,        -- 强调色（冷蓝：意境字/朔望环望点）
        bar    = 0x7E8CAD,        -- 进度条已走段 / 朔望环普通点
        barOff = 0x141A27,        -- 进度条未走段
    },

    -- 月相（软画布调色板索引见 main.lua）
    moon_lit   = 0xEEF3FF,       -- 受光面
    moon_dark  = 0x131927,       -- 暗面（AMOLED 上隐约可见轮廓）
    earthshine = 0x1F2A45,       -- 新月地照：暗面微光
    moon_mare  = 0x92ABE8,       -- 月海（冷蓝）
    cloud_in   = 0x28324E,       -- 云遮月：月面内的云（透月光）
    cloud_out  = 0x1B2438,       -- 云遮月：月面外的云
}

C.STYLES = {
    -- 默认：完全照搬原型审美。冷蓝月海 + 暖橙日辉光。
    default = {
        color = DEFAULT_COLOR,
        halo_enabled        = true,
        ambient_enabled     = true,
        halo_night_color    = nil,   -- nil = 用 night.glow
        halo_day_color      = nil,   -- nil = 用 day.glow
    },

    -- 琥珀夜灯：昼夜辉光统一暖橙，整体温度感更暖，夜灯氛围。
    amber = {
        color = {
            bg = 0x000000,
            day = {
                text   = 0xFAEBD0,        -- 米白
                dim    = 0x7A6650,        -- 暖灰
                faint  = 0x2A1F12,
                glow   = 0xFFB068,        -- 暖琥珀
                accent = 0xFFB068,        -- 强调色（暖琥珀统一）
                bar    = 0x8A6E50,        -- 进度条已走段
                barOff = 0x2A1F12,        -- 进度条未走段
            },
            night = {
                text   = 0xF0DDB8,        -- 暖白
                dim    = 0x6E5A40,
                faint  = 0x1F1810,
                star   = 0x6E5238,
                glow   = 0xFFAE5C,        -- 统一暖琥珀
                accent = 0xFFAE5C,        -- 强调色（暖琥珀统一）
                bar    = 0x8A6E50,        -- 进度条已走段
                barOff = 0x1F1810,        -- 进度条未走段
            },
            moon_lit   = 0xFFEFD0,       -- 暖白月面
            moon_dark  = 0x231811,
            earthshine = 0x3A2A1A,
            moon_mare  = 0xD99868,       -- 暖色月海
            cloud_in   = 0x3D2C1E,
            cloud_out  = 0x261B11,
        },
        halo_enabled        = true,
        ambient_enabled     = true,
        halo_night_color    = nil,
        halo_day_color      = nil,
    },

    -- 极简：去掉 halo 与环境星点，保留月相。信息板风格，续航最优。
    minimal = {
        color = DEFAULT_COLOR,
        halo_enabled        = false,
        ambient_enabled     = false,
        halo_night_color    = nil,
        halo_day_color      = nil,
    },
}

-- 实际生效的色板（applyStyle() 在 main.lua 启动时按 C.STYLE 填入）
C.COLOR = DEFAULT_COLOR

-- ============================================================
-- Halo（光晕环）+ 环境星点（v1.1+）
-- ============================================================

C.HALO = {
    enabled   = true,                -- 整体开关
    night = {
        radius     = 101,            -- 月晕半径
        n          = 8,              -- 稀疏点数
        thickness  = 1,              -- 环粗（px）
        alpha      = 0.5,            -- 由 stage canvas 用调色板颜色近似（单色）
    },
    day = {
        radius     = 122,            -- 太阳辉光半径
        n          = 6,
        thickness  = 1,
        sunny_boost = 0.8,           -- 晴时点更亮（用更亮的调色板槽）
        cloudy_boost = 0.4,          -- 阴/多云用低强度
    },
}

C.AMBIENT = {
    enabled = true,
    count   = 30,                    -- 全屏散落星点数
    seed    = 42,                    -- 伪随机种子（与舞台 STARS 同 seed 保持设计一致）
    pool    = 80,                    -- 第二个软画布对象池容量
}

-- ============================================================
-- 昼夜判定
-- ============================================================

C.DAYNIGHT = {
    use_sun_time   = true,       -- 有日出日落数据优先用；无数据/数据异常按月兜底
    fallback_rise  = 6 * 60,     -- 终极兜底日出（月表越界时用）
    fallback_set   = 18 * 60 + 30, -- 终极兜底日落
    twilight_min   = 0,          -- 日落即入夜（原 20 分钟缓冲导致日落了还显白天）

    -- 按月兜底日出/日落（分钟），中国中部纬度近似值。
    -- 实机 weatherCurrentSunRise/SunSet 主题常不推送（m0tral 全仓库无表盘使用），
    -- 此时按月份估算，比固定 06:00/18:30 全年贴合真实昼夜。
    -- 月份:        1    2    3    4    5    6    7    8    9    10   11   12
    month_rise = { 450, 420, 380, 340, 310, 300, 310, 335, 355, 375, 405, 435 },
    month_set  = { 1035,1070,1095,1125,1150,1165,1160,1135,1100,1060,1030,1020 },
}

-- ============================================================
-- 月相
-- ============================================================

C.MOON = {
    mode = "auto",       -- "astro" / "lunar" / "auto"（优先农历）
    earthshine_max = 4,  -- 受光比例低于该百分比视为"看不见月亮"，启用地照
}

-- 月亮可见性（v1.2）：日落→月出窗口
-- 思路：用月相推算当天"月亮过中天"的本地时刻，
--       月出 = 中天 - 6h，月落 = 中天 + 6h（粗略，忽略月赤纬/视差）。
--       朔时中天 ≈ 正午 12:00；之后每天比太阳晚 50.47 min 过中天。
--       age_days = phase * 29.530588853
--       transit_h = (12 + age * 50.47/60) mod 24
-- 实测误差：±30 min（赤纬大时更差），但对"日落→月出"的过渡判断足够。
-- 完全不依赖 dataman.weatherCurrentMoonRise（米表未推送）。
C.MOON_VISIBILITY = {
    enabled       = true,
    transit_noon  = 12,    -- 朔时中天（小时，本地时间）
    lag_minutes   = 50.47, -- 月亮每天晚过中天的分钟数
    up_hours      = 7,     -- 中天到升/落的 ±小时数（原 6 偏紧，真机实测月亮还在天上但被判已落）
}

-- ============================================================
-- 调试
-- ============================================================

C.DEBUG = {
    enable      = false,
    force_night = nil,   -- true / false / nil
    force_code  = nil,   -- 天气码
    force_moon  = nil,   -- 0.0 - 1.0
    force_moon_up = nil, -- true / false / nil（强制月亮可见性，用于调试日落→月出过渡）
}

return C

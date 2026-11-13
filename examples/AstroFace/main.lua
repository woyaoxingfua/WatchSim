--[[
AstroFace —— Mi Band 9 Pro（DeviceType 367 / 336 x 480）星象表盘
点阵「墨点」版 · 混合渲染方案

渲染分工（性能设计核心）：
    * 汉字 / 天气图标 / 数字  ->  预渲染 PNG（app/lua/res/），lvgl.Image 只改
      src 与坐标，C 层 blit。单字缓存破解组合爆炸（整句缓存需 1440 张）。
    * 月相 / 星点 / 云遮月    ->  软画布逐格光栅化。月相是连续相位，
      无法有限预渲染；28x28 格每分钟一次全量重绘毫无压力。

显示规则（与 design/index.html 原型同源）：
    * 白天：天气图标 PNG + 天气名 + 温度
    * 夜晚 + 劣天气（阴雨雪雷雾霾）：云遮月剪影，名称行显示天气名
      ——下雪的晚上不该假装看得见月亮
    * 夜晚 + 新月（受光 < 4%）：地照微光勾出全盘，名称行"新月"
    * 夜晚 + 其余：月相 + 月海，名称行显示月相名
    * 汉字时间：两行中式读法「十七时 / 二十五分」

数据来源（dataman 主题）：
    时间 timeHour/timeMinute  日期 dateYear/Month/Day/Week + Lunar*
    天气 weatherCurrentWeather/Temperature + SunRise*/SunSet*
--]]

local lvgl = require("lvgl")
local dataman = require("dataman")

local C = require("config")
local Canvas = require("canvas")
local Moon = require("moon")
local iconsDot = require("icons_dot")
local Res = require("res_map")

local DEBUG = C.DEBUG.enable
local printf = DEBUG and print or function(...) end

-- ============================================================
-- 样式应用（启动时按 C.STYLE 选预设，覆盖 C.COLOR / halo / ambient）
-- ============================================================

local function applyStyle()
    local presets = C.STYLES or {}
    local p = presets[C.STYLE] or presets.default or {}
    if type(p.color) == "table" then
        C.COLOR = p.color
    end
    if p.halo_enabled ~= nil then C.HALO.enabled = p.halo_enabled end
    if p.ambient_enabled ~= nil then C.AMBIENT.enabled = p.ambient_enabled end
end
applyStyle()

-- ============================================================
-- 资源路径（SCRIPT_PATH 指向 app/lua/，打包后由固件注入）
-- ============================================================

local BASE = SCRIPT_PATH or ""
if BASE ~= "" and not BASE:match("[/]$") then
    BASE = BASE .. "/"
end

-- PNG 文件四周有 8px 透明辉光边，摆放时坐标要往回退
local PAD = 8
-- 各 PNG 的内容尺寸（点阵边长 x 每点像素）
local HANZI_PX = 24 * 3     -- 72  时间汉字
local NAME_PX  = 24 * 2     -- 48  名称行汉字
local MINI_W, MINI_H = 3 * 3, 5 * 3      -- 9 x 15  温度数字
local DATE_W, DATE_H = 3 * 5, 5 * 5      -- 15 x 25 日期数字（对齐原型步进 5）
local WX_PX    = 28 * 8     -- 224 天气图标
local WX_SMALL_PX = 28 * 3  -- 84 小天气图标（TIME/CYCLE 白天主视觉）

-- 主舞台几何与阈值（原先散落各处的魔法数字，集中此处便于调参）
local STAR_CLEAR_R = 108    -- 舞台星点排除半径（px）：距舞台中心超过它才撒星
local STAR_DIM     = 0.45   -- 舞台星点亮度阈值：低于此值不画，稀疏些更自然
local AMB_STAR_BIG = 0.8    -- 全屏星点亮度阈值：超过的画 2px，否则 1px
local CLOUD_DROP   = 5      -- 云遮月剪影整体下移的格数（让云压住月亮下半）
local CLOUD_R2     = 1.15   -- 云格判定"月面内/外"的半径平方阈值（略大于 1 留过渡）

-- ============================================================
-- 数值解码（dataman 8.8 定点）
-- ============================================================

--- 8.8 定点 → 浮点（温度等连续量）。signed 时做补码还原以支持负温。
local function decodeFixed(v, signed)
    if v == nil then return nil end
    if signed and v > 32767 then v = v - 65536 end
    return v / 256
end

--- 8.8 定点 → 整数（时间/日期/天气码等离散量），v 为 nil 时返回 default。
--- 必须整除（value // 0x100），不能四舍五入：dataman 偶尔的低字节非零
--- 若按 +0.5 取整会把分钟 +1 跳变。
--- 参考：官方 AnalogTime / DigitalTime main.lua 一律 `local h = value // 0x100`。
---@param default any v 为 nil 时的返回值
local function decodeInt(v, default)
    if v == nil then return default end
    return math.floor(v / 256)
end

--- 浮点取整（显示用，如 -3.2° 显示成 -3°）
local function roundInt(v, default)
    if v == nil then return default end
    return math.floor(v + 0.5)
end

-- ============================================================
-- UTF-8 遍历（res_map 的键是汉字；不依赖 utf8 库，gmatch 兜底）
-- ============================================================

local function utf8iter(s)
    return s:gmatch("[\1-\127\194-\255][\128-\191]*")
end

-- ============================================================
-- 汉字时间读法
-- ============================================================

local CN_DIGIT = { "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九" }

---@param n integer 0 - 59
---@param padZero boolean|nil 十位补零（分钟 5 -> 〇五）
local function numCN(n, padZero)
    if n < 10 then
        return (padZero and CN_DIGIT[1] or "") .. CN_DIGIT[n + 1]
    elseif n == 10 then
        return "十"
    elseif n < 20 then
        return "十" .. CN_DIGIT[n - 10 + 1]
    end
    local t = math.floor(n / 10)
    local o = n % 10
    return CN_DIGIT[t + 1] .. "十" .. (o > 0 and CN_DIGIT[o + 1] or "")
end

-- ============================================================
-- 天气名 / 劣天气 / 月相名
-- ============================================================

local WX_NAME = {
    sunny = "晴", partly = "多云", cloudy = "阴", rain = "雨",
    heavyrain = "大雨", thunder = "雷", snow = "雪", fog = "雾", haze = "霾",
}

-- 前向声明：weatherName() 定义在 S 初始化之前，必须提前绑定同一 upvalue
local S

-- 劣天气：夜晚这些天气下看不见月亮，用"云遮月"表达
local BAD_WX = {
    cloudy = true, rain = true, heavyrain = true, thunder = true,
    snow = true, fog = true, haze = true,
}

local function weatherName()
    local code = S.weatherCode or 99
    return WX_NAME[iconsDot.nameForCode(code)] or "阴"
end

-- ============================================================
-- 月相逐格判定（与原型 moonLit / inMare 同公式）
-- ============================================================

local MARES = {
    { -0.32, -0.18, 0.30 }, { 0.22, 0.05, 0.24 },
    { -0.02, 0.34, 0.20 }, { 0.12, -0.38, 0.16 },
}

---@param nx number 归一化 X ∈ [-1,1]
---@param ny number 归一化 Y
---@param phase number 0 新月 / 0.5 满月
---@return boolean
local function moonLit(nx, ny, phase)
    local a = 2 * math.pi * phase
    local c, s = math.cos(a), math.sin(a)
    local edge = c * math.sqrt(math.max(0, 1 - ny * ny))
    if s >= 0 then return nx >= edge end   -- 盈：右侧亮
    return nx <= -edge                     -- 亏：左侧亮
end

local function inMare(nx, ny)
    for i = 1, #MARES do
        local m = MARES[i]
        local dx, dy, r = nx - m[1], ny - m[2], m[3]
        if dx * dx + dy * dy <= r * r then return true end
    end
    return false
end

-- ============================================================
-- 星点（固定伪随机，与原型同 seed 可复现）
-- ============================================================

local STAGE = C.LAYOUT
-- 舞台中心（屏幕坐标）：星点与月晕的对称中心
local STAGE_CX = STAGE.stage_x + STAGE.moon_cx      -- 56 + 112 = 168
local STAGE_CY = STAGE.stage_y + STAGE.moon_cy      -- 48 + 112 = 160
local STARS = {}
do
    local s = 42
    local function rnd()
        s = (s * 1103515245 + 12345) % 2147483648
        return s / 2147483648
    end
    local step = STAGE.stage_step
    while #STARS < 30 do
        local px = math.floor(rnd() * C.SCREEN_W)
        local py = math.floor(rnd() * C.SCREEN_H)
        local dx, dy = px - STAGE_CX, py - STAGE_CY
        if dx * dx + dy * dy > STAR_CLEAR_R * STAR_CLEAR_R then   -- 舞台月面圆外
            local gx = math.floor(px / step) - STAGE.stage_x / step
            local gy = math.floor(py / step) - STAGE.stage_y / step
            if gx >= 0 and gx < STAGE.stage_grid and gy >= 0 and gy < STAGE.stage_grid then
                STARS[#STARS + 1] = { gx, gy, rnd() }
            end
        end
    end
end

-- ============================================================
-- 运行时状态
-- ============================================================

S = {
    hour = 0, min = 0,
    year = 2026, month = 1, day = 1, week = 1,
    lunarMonth = nil, lunarDay = nil,
    weatherCode = nil,
    temp = nil,
    riseH = nil, riseM = 0, setH = nil, setM = 0,

    isNight = false,
    moonUp = true,           -- 月亮当前是否在地平线上（v1.2+：日落→月出窗口判定）
    phase = 0,
    phaseDayKey = nil,

    -- dataman 时间主题推送到达标记。部分固件/精简设备上 timeHour/timeMinute
    -- 可能整场不推送，此时退回 os.date 轮询，避免时间永久冻结在启动时刻。
    timeSynced = false,

    -- 当前布局（"star" / "time" / "cycle"）。默认 star，快应用可切换：
    -- 米环系统长按 0.7s 是固件级编辑表盘，Lua 自定义长按抢事件会导致表盘"无法编辑"
    -- + lvgl.tick_get 真机不存在崩溃。三套渲染代码保留，等找到非 0.7s 切换入口再启用。
    layout = "star",
}

--- 当前布局的几何表。TIME/CYCLE 表里缺失的字段回落到 C.LAYOUT（主表）。
---@return table
local function geom()
    if S.layout == "time" then return C.LAYOUT_TIME end
    if S.layout == "cycle" then return C.LAYOUT_CYCLE end
    return C.LAYOUT
end

-- ============================================================
-- 根容器
-- ============================================================

local rootbase = lvgl.Object(nil, {
    w = lvgl.HOR_RES(),
    h = lvgl.VER_RES(),
    bg_color = C.COLOR.bg,
    bg_opa = lvgl.OPA(100),
    border_width = 0,
})
rootbase:clear_flag(lvgl.FLAG.SCROLLABLE)
rootbase:add_flag(lvgl.FLAG.EVENT_BUBBLE)

local root = lvgl.Object(rootbase, {
    outline_width = 0,
    border_width = 0,
    pad_all = 0,
    bg_opa = 0,
    bg_color = 0,
    align = lvgl.ALIGN.CENTER,
    w = C.SCREEN_W,
    h = C.SCREEN_H,
})
root:clear_flag(lvgl.FLAG.SCROLLABLE)
root:add_flag(lvgl.FLAG.EVENT_BUBBLE)

-- ============================================================
-- Image 对象池：预创建，只改 src / 坐标，不反复建删控件
-- ============================================================

local FLAG_HIDDEN = (lvgl.FLAG and lvgl.FLAG.HIDDEN) or nil

---@param n number 池容量
local function newPool(n)
    local pool = { n = n, cur = 0, items = {} }
    for i = 1, n do
        local ok, obj = pcall(function()
            return lvgl.Image(root, { x = -200, y = -200 })
        end)
        if not ok then
            printf("[AstroFace] Image 控件创建失败")
            obj = nil
        end
        pool.items[i] = { obj = obj, src = nil }
    end
    --- 重置游标（每个绘制函数开头调用）
    function pool:reset() self.cur = 0 end

    --- 摆放一张 PNG（contentX/Y 为内容区左上角，PNG 内容居中于文件）
    function pool:place(path, contentX, contentY)
        self.cur = self.cur + 1
        local it = self.items[self.cur]
        if it == nil or it.obj == nil then return end
        local full = BASE .. path
        if it.src ~= full then
            it.obj:set({ src = full })
            it.src = full
        end
        it.obj:set({ x = contentX - PAD, y = contentY - PAD })
        if FLAG_HIDDEN then it.obj:clear_flag(FLAG_HIDDEN) end
    end

    --- 收尾：隐藏未用到的控件（每个绘制函数结尾调用）
    function pool:finish()
        for i = self.cur + 1, self.n do
            local it = self.items[i]
            if it and it.obj then
                if FLAG_HIDDEN then
                    it.obj:add_flag(FLAG_HIDDEN)
                else
                    it.obj:set({ x = -200, y = -200 })
                end
            end
        end
    end
    return pool
end

-- 池分配：时间 8 / 名称+温度 7 / 日期 5 / 天气图标 1
local poolTime  = newPool(8)
local poolName  = newPool(7)
local poolDate  = newPool(5)
local poolIcon  = newPool(1)

--- 摆一行汉字（时间行，72px）
---@param text string
---@param x integer 内容左起
---@param y integer 内容顶
---@param gap number 字间距
local function placeHanziLarge(pool, text, x, y, gap)
    for ch in utf8iter(text) do
        local p = Res.HANZI[ch]
        if p then pool:place(p, x, y) end
        x = x + HANZI_PX + gap      -- 缺字也占位，避免挤在一起
    end
    return x
end

--- 摆一行名称行汉字（48px，优先小字库，缺字回落大字库）
local function placeHanziName(pool, text, x, y, gap)
    for ch in utf8iter(text) do
        local p = Res.HANZI_NAME[ch] or Res.HANZI[ch]
        if p then pool:place(p, x, y) end
        x = x + NAME_PX + gap
    end
    return x
end

--- 字符数（° 等多字节字符按 1 计）
local function charCount(s)
    local n = 0
    for _ in utf8iter(s) do n = n + 1 end
    return n
end

--- 数字串内容宽度（按字符数，° 占 1 字符）
local function miniWidth(text, w, gap)
    local n = charCount(text)
    return n * w + math.max(0, n - 1) * gap
end

--- 摆一串数字 PNG（温度 accent / 日期 dim）；utf8iter 保证 ° 不被拆字节
local function placeMini(pool, text, map, x, y, w, gap)
    for ch in utf8iter(text) do
        local p = map[ch]
        if p then pool:place(p, x, y) end
        x = x + w + gap
    end
    return x
end

-- ============================================================
-- 星期 7 点（lvgl 圆点控件）
-- ============================================================

local weekDots = {}
for i = 1, 7 do
    weekDots[i] = lvgl.Object(root, {
        x = 0, y = 0, w = 7, h = 7,
        bg_color = C.COLOR.day.faint,
        bg_opa = lvgl.OPA(100),
        radius = 255,
        border_width = 0, outline_width = 0, pad_all = 0,
    })
    weekDots[i]:clear_flag(lvgl.FLAG.SCROLLABLE)
end

local function drawWeek()
    local faint = S.isNight and C.COLOR.night.faint or C.COLOR.day.faint
    local active = S.isNight and C.COLOR.night.text or C.COLOR.day.text
    -- 点序 = 周一..周日；dataman 约定 0=周日、1=周一...6=周六
    for i = 1, 7 do
        local on = (S.week or 0) == (i % 7)
        local d = on and 7 or 4
        weekDots[i]:set({
            x = C.LAYOUT.week_x0 + (i - 1) * C.LAYOUT.week_gap - d / 2,
            y = C.LAYOUT.week_y - d / 2,
            w = d, h = d,
            bg_color = on and active or faint,
        })
    end
end

-- ============================================================
-- 主舞台软画布：夜晚月相 / 星点 / 云遮月
-- ============================================================

local stage = Canvas.new(root, STAGE.stage_x, STAGE.stage_y,
                         STAGE.stage_grid * STAGE.stage_step,
                         STAGE.stage_grid * STAGE.stage_step, 240)

-- 第二个全屏画布：白天太阳辉光 + 夜晚环境星点（在主舞台外圈）
local ambient = Canvas.new(root, 0, 0, C.SCREEN_W, C.SCREEN_H, C.AMBIENT.pool or 80)
-- 星点 / 夜晕 / 日晕 三个独立槽位。
-- v1.2 修复：夜晕与日晕原本共用 P_AMB_HALO，夜晚月晕实际拿到的是 day.glow（暖橙 0xFF9D3C），
-- 而 config.lua 三套预设里的 halo_night_color 从未被任何代码读取（死配置）。
local P_AMB_STAR, P_AMB_HALO_NIGHT, P_AMB_HALO_DAY = 1, 2, 3

local style = (C.STYLES and C.STYLES[C.STYLE]) or {}
local ambPal = {
    [P_AMB_STAR]       = C.COLOR.night.star,
    [P_AMB_HALO_NIGHT] = style.halo_night_color or C.COLOR.night.glow,
    [P_AMB_HALO_DAY]   = style.halo_day_color   or C.COLOR.day.glow,
}

-- 环境星点（固定伪随机；与 STARS 同 seed 但偏移，避免与舞台内星点重合）
local STARS_AMBIENT = {}
do
    local s = (C.AMBIENT.seed or 42) + 7
    local function rnd()
        s = (s * 1103515245 + 12345) % 2147483648
        return s / 2147483648
    end
    local target = C.AMBIENT.count or 30
    while #STARS_AMBIENT < target do
        local px = math.floor(rnd() * C.SCREEN_W)
        local py = math.floor(rnd() * C.SCREEN_H)
        -- 排除主舞台 28x28 框（舞台自己会画星），避开顶部星期/日期区
        local inStage = px >= 56 and px < 280 and py >= 48 and py < 272
        local inTop   = py < 44
        if not inStage and not inTop then
            STARS_AMBIENT[#STARS_AMBIENT + 1] = { px, py, rnd() }
        end
    end
end

-- 第三个全屏画布：TIME/CYCLE 布局的软画布元素（小月相/进度条/朔望环/意境字/距望）。
-- 小月相改整格填充后，最大矩形数 ~110（CYCLE：环 44 + 小月 14 + 距望 49），池 160 留余量。
local overlay = Canvas.new(root, 0, 0, C.SCREEN_W, C.SCREEN_H, 160)

-- 月未升时的两行意境字使用清晰的 48px 预渲染字图，避免软画布小字模
-- 放大后断笔；单独池可保证布局切换时不会和名称/时间池互相覆盖。
local poolPoem = newPool(6)
-- CYCLE 的"距望 N 天"独立使用同一套 48px 点阵汉字；2 个汉字 + 最多 2 位数字 + 结尾汉字。
local poolDist = newPool(5)

-- 舞台调色板索引（stage 画布：大月相 + 意境字）
local P_DARK, P_LIT, P_MARE, P_STAR, P_CLOUD_IN, P_CLOUD_OUT, P_EARTH, P_HALO, P_ACCENT = 1, 2, 3, 4, 5, 6, 7, 8, 9

-- overlay 调色板索引（overlay 画布：小月/进度条/朔望环/距望）
local O_DARK, O_LIT, O_MARE, O_EARTH, O_CLOUD_IN, O_CLOUD_OUT = 1, 2, 3, 4, 5, 6
local O_BAR, O_BAR_OFF, O_ACCENT, O_DIM, O_WHITE = 7, 8, 9, 10, 11

-- 调色板表在启动时静态构建（值取自 C.COLOR 当时值）。快应用切样式后
-- applyStyle() 换了 C.COLOR 指向，必须 rebuildPalettes() 重建才能生效。
local stagePalNight, overlayPalNight, overlayPalDay = {}, {}, {}

local function rebuildPalettes()
    stagePalNight = {
        [P_DARK]     = C.COLOR.moon_dark,
        [P_LIT]      = C.COLOR.moon_lit,
        [P_MARE]     = C.COLOR.moon_mare,
        [P_STAR]     = C.COLOR.night.star,
        [P_CLOUD_IN] = C.COLOR.cloud_in,
        [P_CLOUD_OUT]= C.COLOR.cloud_out,
        [P_EARTH]    = C.COLOR.earthshine,
        [P_HALO]     = C.COLOR.night.glow,
        [P_ACCENT]   = C.COLOR.night.accent,
    }
    overlayPalNight = {
        [O_DARK]     = C.COLOR.moon_dark,
        [O_LIT]      = C.COLOR.moon_lit,
        [O_MARE]     = C.COLOR.moon_mare,
        [O_EARTH]    = C.COLOR.earthshine,
        [O_CLOUD_IN] = C.COLOR.cloud_in,
        [O_CLOUD_OUT]= C.COLOR.cloud_out,
        [O_BAR]      = C.COLOR.night.bar,
        [O_BAR_OFF]  = C.COLOR.night.barOff,
        [O_ACCENT]   = C.COLOR.night.accent,
        [O_DIM]      = C.COLOR.night.dim,
        [O_WHITE]    = 0xFFFFFF,
    }
    overlayPalDay = {
        [O_BAR]      = C.COLOR.day.bar,
        [O_BAR_OFF]  = C.COLOR.day.barOff,
        [O_ACCENT]   = C.COLOR.day.accent,
        [O_DIM]      = C.COLOR.day.dim,
        [O_WHITE]    = 0xFFFFFF,
    }
end
rebuildPalettes()

--- 计算当日月相（同一天只算一次；逻辑来自 moon.lua）
local function currentPhase()
    if C.DEBUG.force_moon ~= nil then return C.DEBUG.force_moon end

    -- 农历主题可能在启动后异步到达；把农历值纳入缓存键，避免先用天文
    -- 近似算过一次后，同一小时内永远不再切换到更准确的农历校准。
    local lunarKey = string.format("%02d%02d", S.lunarMonth or 0, S.lunarDay or 0)
    local key = string.format("%04d%02d%02d%02d:%s",
                              S.year, S.month, S.day, S.hour, lunarKey)
    if S.phaseDayKey == key then return S.phase end

    local p = nil
    local mode = C.MOON.mode
    if mode == "lunar" or mode == "auto" then
        if S.lunarDay and S.lunarDay >= 1 and S.lunarDay <= 30 then
            p = Moon.phaseFromLunarDay(S.lunarDay)
        end
    end
    if p == nil then
        local ok, v = pcall(Moon.phaseFromDate, os.date("!*t"))
        if ok and v then p = v end
    end
    if p == nil then p = 0 end

    S.phase = p
    S.phaseDayKey = key
    return p
end

--- 月亮是否在地平线上（v1.2+，日落→月出过渡用）
--- 粗略算法：由月相推算当天"月亮过中天"时刻，再 ±6h 即升落窗口。
local function isMoonUp()
    if not C.MOON_VISIBILITY.enabled then return true end
    if C.DEBUG.force_moon_up ~= nil then return C.DEBUG.force_moon_up end

    local phase = currentPhase()
    local age = phase * 29.530588853                       -- 月龄（天）
    local transit = (C.MOON_VISIBILITY.transit_noon
                     + age * (C.MOON_VISIBILITY.lag_minutes / 60)) % 24
    local rise = (transit - C.MOON_VISIBILITY.up_hours + 24) % 24
    local sett = (transit + C.MOON_VISIBILITY.up_hours) % 24
    local now = S.hour + S.min / 60

    -- 升落在 [0,24) 的相对关系决定区间是否跨午夜
    if rise < sett then
        return now >= rise and now < sett
    end
    -- 跨午夜：[rise, 24) ∪ [0, sett)
    return now >= rise or now < sett
end

--- 云遮月剪影（通用化，v1.5）：暗云完全盖住月面，只透一点月光。
--- 劣天气夜晚 = "看不见月亮"（云遮月）；月亮未升起时 = "云遮天"（云下无月面）。
--- 通用化：任意画布 / 圆心 / 半径。size = 2r 全盖不露月面。
--- 必须定义在 drawNightStage 之前：Lua 的 local function 是语句级声明，
--- 定义在后面会让 drawNightStage 里的 upvalue 拿到 nil。
---@param canvas Canvas
---@param cx number 云中心 X（画布内坐标）
---@param cy number 云中心 Y
---@param r number 月面半径（云覆盖直径 = 2r）
---@param pin number 云内调色板索引（透月光）
---@param pout number 云外调色板索引（更暗）
local function drawCloudMask(canvas, cx, cy, r, pin, pout)
    local cl = iconsDot.icon("cloudy")
    local size = r * 2
    local pitch = size / iconsDot.SIZE
    local dd = pitch * 0.8
    local half = dd / 2
    for y = 1, #cl do
        for x = 1, #cl[y] do
            if cl[y][x] == 1 then
                local px = cx - size / 2 + (x - 0.5) * pitch
                local py = cy - size / 2 + (y - 0.5) * pitch
                local nx = (px - cx) / r
                local ny = (py - cy) / r
                local v = (nx * nx + ny * ny <= CLOUD_R2) and pin or pout
                canvas:fillCircle(px, py, half, v)
            end
        end
    end
end

--- 意境文字：日落但月未升（古风对仗短句）。
--- 使用与名称行相同的 48px 预渲染字图，字形完整、对比度稳定。
local function drawPoem()
    poolPoem:reset()
    local gap = 4
    local lineW = 3 * NAME_PX + 2 * gap
    local x = STAGE.stage_x
        + math.floor((STAGE.stage_grid * STAGE.stage_step - lineW) / 2 + 0.5)
    local y1 = STAGE.stage_y + 54
    local y2 = y1 + 54
    local function line(text, y)
        local px = x
        for ch in utf8iter(text) do
            local p = Res.POEM[ch] or Res.HANZI_NAME[ch] or Res.HANZI[ch]
            if p then poolPoem:place(p, px, y) end
            px = px + NAME_PX + gap
        end
    end
    line("日已落", y1)
    line("月未升", y2)
    poolPoem:finish()
end

--- 小月相（细网格整格填充，屏幕坐标）。R=36/34 用 8px 粗格会块状不圆，
--- 用 step=3 细格才呈现圆润月牙。整格 fillRect（非圆点）与大月相一致：
--- 相邻同色格在行扫描时合并，矩形数从 ~500 降到 ~14，池容量与内存大幅下降，
--- 且 3px 细格本身已足够圆（半径 12 格）。
---@param canvas Canvas
---@param cx number 月心 X（画布内坐标）
---@param cy number 月心 Y
---@param r number 半径
---@param phase number
---@param step number 网格步进
local function drawSmallMoon(canvas, cx, cy, r, phase, step)
    local earth = Moon.illumination(phase) < C.MOON.earthshine_max
    local gx0 = math.floor((cx - r) / step)
    local gx1 = math.ceil((cx + r) / step)
    local gy0 = math.floor((cy - r) / step)
    local gy1 = math.ceil((cy + r) / step)
    for gy = gy0, gy1 do
        local py = gy * step
        local ny = ((gy + 0.5) * step - cy) / r
        for gx = gx0, gx1 do
            local nx = ((gx + 0.5) * step - cx) / r
            if nx * nx + ny * ny <= 1 then
                local v
                if moonLit(nx, ny, phase) then
                    v = inMare(nx, ny) and O_MARE or O_LIT
                else
                    v = earth and O_EARTH or O_DARK
                end
                canvas:fillRect(gx * step, py, step, step, v)
            end
        end
    end
end

--- 24h 进度条（TIME 布局，40 点）
---@param canvas Canvas
---@param L table 布局几何表
local function drawProgressBar(canvas, L)
    local pct = (S.hour * 60 + S.min) / 1440
    for i = 0, L.bar_n - 1 do
        local on = (i / L.bar_n) < pct
        canvas:fillCircle(24 + i * 5, L.bar_y, 1, on and O_BAR or O_BAR_OFF)
    end
end

--- 朔望环（CYCLE 布局，30 点）+ 今日位置高亮
---@param canvas Canvas
---@param L table 布局几何表
local function drawCycleRing(canvas, L)
    local phase = currentPhase()
    local todayIdx = math.floor(((phase % 1) + 1) % 1 * 30)
    for i = 0, 29 do
        local ang = (i / 30) * 2 * math.pi - math.pi / 2
        local x = L.ring_cx + L.ring_r * math.cos(ang)
        local y = L.ring_cy + L.ring_r * math.sin(ang)
        if i == 15 then
            canvas:fillCircle(x, y, 2.25, O_ACCENT)   -- 望（满月）
        elseif i == 0 then
            canvas:fillCircle(x, y, 1.75, O_DIM)      -- 朔（新月）
        else
            canvas:fillCircle(x, y, 1, O_BAR)
        end
    end
    local tang = (todayIdx / 30) * 2 * math.pi - math.pi / 2
    canvas:fillCircle(L.ring_cx + L.ring_r * math.cos(tang),
                      L.ring_cy + L.ring_r * math.sin(tang), 3, O_WHITE)
end

--- 距满月天数（望 = 月龄 15）
local function distToFull(phase)
    local dayIdx = math.floor(((phase % 1) + 1) % 1 * 30)
    return (15 - dayIdx + 30) % 30
end

--- 距望行："距望 N 天"（accent 色，预渲染 48px 点阵汉字 + 迷你数字）
---@param L table 布局几何表
local function drawDistToFull(L)
    poolDist:reset()
    local d2f = distToFull(currentPhase())
    local digits = tostring(d2f)
    local cnGap = 2
    local blockGap = 8
    local digitGap = 2
    local y = L.dist_y
    local digitW = miniWidth(digits, MINI_W, digitGap)
    local w = 2 * NAME_PX + cnGap + blockGap + digitW + blockGap + NAME_PX
    local px = math.floor((C.SCREEN_W - w) / 2 + 0.5)
    for ch in utf8iter("距望") do
        local p = Res.DIST[ch] or Res.HANZI_NAME[ch] or Res.HANZI[ch]
        if p then poolDist:place(p, px, y) end
        px = px + NAME_PX + cnGap
    end
    px = px + blockGap - cnGap
    -- 数字放在汉字视觉中线附近，并沿用温度数字的清晰 PNG。
    px = placeMini(poolDist, digits, Res.MINI, px, y + 17, MINI_W, digitGap)
    px = px + blockGap
    local p = Res.DIST["天"] or Res.HANZI_NAME["天"] or Res.HANZI["天"]
    if p then poolDist:place(p, px, y) end
    poolDist:finish()
end

--- 夜晚主舞台：星点 + 月相 / 云遮月 / 意境文字
--- v1.5+：劣天气 → 云遮月（全盖不露月）；月未升+晴朗 → 意境文字；
---         其余 → 大月相。
local function drawNightStage()
    stage:clear()

    -- 先清掉上一个场景的意境字，避免月亮/云层切换后文字残留。
    poolPoem:reset()
    poolPoem:finish()
    poolDist:reset()
    poolDist:finish()

    -- 收起白天专用的天气图标池。poolIcon 只有 drawDayStage 会摆放，
    -- 若夜晚不收，昼→夜切换后上一个白天的图标会一直残留在主舞台上。
    poolIcon:reset()
    poolIcon:finish()

    local phase = currentPhase()
    local g = STAGE.stage_grid
    local step = STAGE.stage_step
    local cx, cy, r = STAGE.moon_cx, STAGE.moon_cy, STAGE.moon_r
    local bad = BAD_WX[iconsDot.nameForCode(S.weatherCode or 99)]

    -- 星点（始终画，夜晚背景）
    for i = 1, #STARS do
        local st = STARS[i]
        if st[3] > STAR_DIM then
            -- STARS 存的是格坐标，画布是像素坐标，需按 step 放大
            stage:fillRect(st[1] * step, st[2] * step, step, step, P_STAR)
        end
    end

    if bad then
        -- 劣天气：云完全盖住月面，看不见月亮
        drawCloudMask(stage, cx, cy, r, P_CLOUD_IN, P_CLOUD_OUT)
    elseif S.moonUp then
        -- 月相逐格
        local earth = Moon.illumination(phase) < C.MOON.earthshine_max   -- 新月：地照微光
        for gy = 0, g - 1 do
            local ny = ((gy + 0.5) * step - cy) / r
            local py = gy * step
            for gx = 0, g - 1 do
                local nx = ((gx + 0.5) * step - cx) / r
                if nx * nx + ny * ny <= 1 then
                    local v
                    if moonLit(nx, ny, phase) then
                        v = inMare(nx, ny) and P_MARE or P_LIT
                    else
                        v = earth and P_EARTH or P_DARK
                    end
                    stage:fillRect(gx * step, py, step, step, v)
                end
            end
        end
    else
        -- 月未升 + 晴朗：意境文字（日落月未升）
        drawPoem()
    end

    stage:flush(stagePalNight)
end

--- 白天主舞台：天气图标 PNG 居中贴上
local function drawDayStage()
    -- 白天用 PNG 天气图标，软画布内容作废，池控件全部收起
    stage:hideAll()
    poolPoem:reset()
    poolPoem:finish()
    poolDist:reset()
    poolDist:finish()

    local name = iconsDot.nameForCode(S.weatherCode or 99)
    local contentX = math.floor((C.SCREEN_W - WX_PX) / 2 + 0.5)
    local stageH = STAGE.stage_grid * STAGE.stage_step
    local contentY = STAGE.stage_y + math.floor((stageH - WX_PX) / 2 + 0.5)
    poolIcon:reset()
    poolIcon:place(Res.WX[name], contentX, contentY)
    poolIcon:finish()
end

-- ============================================================
-- Ambient 层：白天太阳辉光 + 夜晚月晕 + 夜晚全屏星点
-- ============================================================

-- 光晕环的圆心直接复用舞台中心 STAGE_CX / STAGE_CY（见文件前部常量区）。
-- 原先这里另写了一套 floor(SCREEN_W/2) 与 stage_grid*step/2 的算法，算出来
-- 是同一个值（168/160）却用两套表达式，将来调布局很容易只改一处导致错位。

--- 在 ambient 画布上画"halo 散点"（设计语言「墨点」核心装饰）
---@param cx number 圆心 X（屏幕坐标）
---@param cy number 圆心 Y
---@param r number 环半径
---@param n number 散点数
---@param v number 调色板索引
---@param dot number 每点边长（px，默认 3 = 3x3 圆点）
local function drawHaloDots(cx, cy, r, n, v, dot)
    dot = dot or 3
    local half = math.floor(dot / 2)
    for i = 0, n - 1 do
        local a = (i / n) * 2 * math.pi + 0.3
        local px = math.floor(cx + r * math.cos(a) + 0.5)
        local py = math.floor(cy + r * math.sin(a) + 0.5)
        ambient:fillRect(px - half, py - half, dot, dot, v)
    end
end

--- 全屏 ambient 元素：夜晚散落星点 + 月晕 / 白天太阳辉光
--- v1.2+：月亮未升时不再画月晕（halo 是月亮的装饰）
local function drawAmbient()
    ambient:clear()
    if S.isNight then
        -- 月晕：8 个散点环绕月面外圈 r=101（月未升时不画）
        if C.HALO.enabled and S.moonUp then
            local haloR = C.HALO.night.radius
            local haloN = C.HALO.night.n or 8
            drawHaloDots(STAGE_CX, STAGE_CY, haloR, haloN, P_AMB_HALO_NIGHT, 3)
        end
        -- 环境星点
        if C.AMBIENT.enabled then
            for i = 1, #STARS_AMBIENT do
                local st = STARS_AMBIENT[i]
                local sz = st[3] > AMB_STAR_BIG and 2 or 1
                ambient:fillRect(st[1], st[2], sz, sz, P_AMB_STAR)
            end
        end
    else
        -- 白天太阳辉光：6 个散点环绕 r=122（仅晴/多云显著）
        if C.HALO.enabled then
            local codeName = iconsDot.nameForCode(S.weatherCode or 99)
            if codeName == "sunny" or codeName == "partly" then
                local haloR = C.HALO.day.radius
                local haloN = C.HALO.day.n or 6
                drawHaloDots(STAGE_CX, STAGE_CY, haloR, haloN, P_AMB_HALO_DAY, 3)
            end
        end
    end
    ambient:flush(ambPal)
end

-- ============================================================
-- 名称行：天气名 / 月相名 + 温度
-- ============================================================

local function nameText()
    if S.isNight then
        local codeName = iconsDot.nameForCode(S.weatherCode or 99)
        if BAD_WX[codeName] then
            return WX_NAME[codeName]           -- 劣天气：报天气不报月相
        end
        if not S.moonUp then
            return WX_NAME[codeName]           -- 月未升：报天气（不要报一个看不见的月相名）
        end
        return Moon.name(currentPhase())
    end
    return weatherName()
end

local function drawName()
    poolName:reset()

    local L = geom()
    local y = L.name_y or C.LAYOUT.name_y
    local gap = L.name_gap or C.LAYOUT.name_gap
    -- CYCLE 信息图式：名称行只报名称不报温度（环心已有月相/距望，温度让位）
    local withTemp = (S.layout ~= "cycle")

    local txt = nameText()
    local nChars = 0
    for _ in utf8iter(txt) do nChars = nChars + 1 end
    local txtW = nChars * NAME_PX + math.max(0, nChars - 1) * gap

    -- 温度串（数据未到时留空）
    local tStr = ""
    if withTemp and S.temp ~= nil then
        local t = roundInt(S.temp, 0)
        tStr = (t < 0 and "-" or "") .. tostring(math.abs(t)) .. "\u{00b0}"
    end
    local tW = (#tStr > 0) and miniWidth(tStr, MINI_W, gap) or 0

    local tempGap = L.name_temp_gap or C.LAYOUT.name_temp_gap
    local tempBottom = L.temp_bottom or C.LAYOUT.temp_bottom
    local total = txtW + (#tStr > 0 and tempGap + tW or 0)
    local x = math.floor((C.SCREEN_W - total) / 2 + 0.5)

    x = placeHanziName(poolName, txt, x, y, gap)
    if #tStr > 0 then
        placeMini(poolName, tStr, Res.MINI, x + tempGap,
                  tempBottom - MINI_H, MINI_W, gap)
    end
    poolName:finish()
end

-- ============================================================
-- 汉字时间：两行中式
-- ============================================================

local function drawTime()
    poolTime:reset()

    local L = geom()
    local gap = L.time_gap or C.LAYOUT.time_gap

    local hTxt = numCN(S.hour, false) .. "时"
    local mTxt = (S.min == 0) and "整" or (numCN(S.min, S.min < 10) .. "分")

    -- STAR/CYCLE 用小字（48px，复用名称行字库）；TIME 保持 72px 大字。
    -- 两条分支各自闭包 line()，避免在函数体内动态选 placeHanzi* 带来的分叉噪音。
    if S.layout == "star" or S.layout == "cycle" then
        local function line(y, txt)
            local n = 0
            for _ in utf8iter(txt) do n = n + 1 end
            local w = n * NAME_PX + math.max(0, n - 1) * gap
            placeHanziName(poolTime, txt,
                           math.floor((C.SCREEN_W - w) / 2 + 0.5), y, gap)
        end
        line(L.time1_y, hTxt)
        line(L.time2_y, mTxt)
    else
        local function line(y, txt)
            local n = 0
            for _ in utf8iter(txt) do n = n + 1 end
            local w = n * HANZI_PX + math.max(0, n - 1) * gap
            placeHanziLarge(poolTime, txt,
                            math.floor((C.SCREEN_W - w) / 2 + 0.5), y, gap)
        end
        line(L.time1_y, hTxt)
        line(L.time2_y, mTxt)
    end
    poolTime:finish()
end

-- ============================================================
-- TIME / CYCLE 布局的 overlay 内容（软画布：小月/云/进度条/朔望环/距望）
-- ============================================================

--- 白天把天气小图标（84px）贴到屏幕坐标 (cx, cy) 中心，用共享的 poolIcon 池。
--- 夜晚必须收起 poolIcon，否则昼→夜切换后上一个白天的图标残留。
local function placeSmallWeather(cx, cy)
    poolIcon:reset()
    if S.isNight then
        poolIcon:finish()
        return
    end
    local name = iconsDot.nameForCode(S.weatherCode or 99)
    poolIcon:place(Res.WX_SMALL[name],
                   math.floor(cx - WX_SMALL_PX / 2 + 0.5),
                   math.floor(cy - WX_SMALL_PX / 2 + 0.5))
    poolIcon:finish()
end

--- 在 overlay 上画"小月 / 小云遮月 / 白天小图标"三选一（TIME 与 CYCLE 共用）。
--- 劣天气→云遮月；月已升→细网格小月；月未升+晴朗→留空（夜空无月，名称行报天气）；
--- 白天→小天气图标（由 placeSmallWeather 处理，本函数只负责夜晚软画布部分）。
---@param canvas Canvas
---@param cx number 小月心 X（屏幕坐标）
---@param cy number 小月心 Y
---@param r number 半径
---@param step number 细网格步进
local function drawSmallHero(canvas, cx, cy, r, step)
    local bad = BAD_WX[iconsDot.nameForCode(S.weatherCode or 99)]
    if not S.isNight then return end   -- 白天走 placeSmallWeather
    if bad then
        drawCloudMask(canvas, cx, cy, r, O_CLOUD_IN, O_CLOUD_OUT)
    elseif S.moonUp then
        drawSmallMoon(canvas, cx, cy, r, currentPhase(), step)
    end
end

--- TIME「时迹」overlay：24h 进度条 + 小月/云/小天气
local function renderTimeOverlay()
    overlay:clear()
    local L = C.LAYOUT_TIME
    drawProgressBar(overlay, L)
    drawSmallHero(overlay, L.moon_cx, L.moon_cy, L.moon_r, L.moon_step)
    placeSmallWeather(L.moon_cx, L.moon_cy)
    overlay:flush(S.isNight and overlayPalNight or overlayPalDay)
end

--- CYCLE「朔望」overlay：30 点朔望环 + 环心小月/云/小天气 + 距望行
local function renderCycleOverlay()
    overlay:clear()
    local L = C.LAYOUT_CYCLE
    drawCycleRing(overlay, L)
    drawSmallHero(overlay, L.ring_cx, L.ring_cy, L.moon_r, L.moon_step)
    placeSmallWeather(L.ring_cx, L.ring_cy)
    drawDistToFull(L)
    overlay:flush(S.isNight and overlayPalNight or overlayPalDay)
end

--- 布局分派：star / time / cycle。每个分支负责收起其它布局的画布，
--- 避免布局切换后旧画布矩形残留。
local function renderLayout()
    if S.layout == "time" then
        stage:hideAll()
        ambient:hideAll()
        poolPoem:reset()
        poolPoem:finish()
        poolDist:reset()
        poolDist:finish()
        drawTime()          -- 72px 大字（上半屏）
        renderTimeOverlay() -- 进度条 + 小月/云/小天气
        drawName()
    elseif S.layout == "cycle" then
        stage:hideAll()
        ambient:hideAll()
        poolPoem:reset()
        poolPoem:finish()
        poolDist:reset()
        poolDist:finish()
        renderCycleOverlay() -- 朔望环 + 环心小月 + 距望
        drawName()
        drawTime()           -- 48px 小字（下半屏）
    else
        overlay:hideAll()
        poolDist:reset()
        poolDist:finish()
        if S.isNight then drawNightStage() else drawDayStage() end
        drawAmbient()
        drawName()
        drawTime()
    end
end

-- ============================================================
-- 日期（PNG 数字）
-- ============================================================

local function drawDate()
    poolDate:reset()
    local dstr = string.format("%02d.%02d", S.month, S.day)
    local w = miniWidth(dstr, DATE_W, C.LAYOUT.date_gap)
    placeMini(poolDate, dstr, Res.DATE,
              math.floor((C.SCREEN_W - w) / 2 + 0.5), C.LAYOUT.date_y,
              DATE_W, C.LAYOUT.date_gap)
    poolDate:finish()
end

-- ============================================================
-- 昼夜判定（优先日出日落，缺失用兜底时刻）
-- ============================================================

local function isNightNow()
    if C.DEBUG.force_night ~= nil then return C.DEBUG.force_night end

    local hm = S.hour * 60 + S.min
    local rise, set

    -- 日出日落数据必须通过合理性校验才采用：
    -- 0-23 时、且日出严格早于日落。实机上这些主题常不推送（恒 nil），
    -- 或解出 0 之类的脏值；脏值一旦采用会让昼夜判断彻底错乱（全天昼/全天夜）。
    local riseH, setH = S.riseH, S.setH
    local riseM, setM = S.riseM or 0, S.setM or 0
    local sunOk = C.DAYNIGHT.use_sun_time
        and type(riseH) == "number" and type(setH) == "number"
        and riseH >= 0 and riseH <= 23 and setH >= 0 and setH <= 23
        and riseM >= 0 and riseM <= 59 and setM >= 0 and setM <= 59
        and riseH * 60 + riseM < setH * 60 + setM

    if sunOk then
        rise = riseH * 60 + riseM
        set = setH * 60 + setM
    else
        -- 无数据/数据异常：按月兜底（1-12 月日出日落近似），越界再退回终极兜底
        local m = S.month or 6
        rise = (C.DAYNIGHT.month_rise and C.DAYNIGHT.month_rise[m])
            or C.DAYNIGHT.fallback_rise
        set = (C.DAYNIGHT.month_set and C.DAYNIGHT.month_set[m])
            or C.DAYNIGHT.fallback_set
    end

    local tw = C.DAYNIGHT.twilight_min or 0
    return (hm < rise - tw) or (hm >= set + tw)
end

-- ============================================================
-- dataman 订阅
-- ============================================================

local nameDirty = false    -- 天气/温度推送后名称行需要刷新

local function sub(topic, fn)
    local ok, err = pcall(function()
        dataman.subscribe(topic, root, function(_, value)
            local ok2, err2 = pcall(fn, value)
            if not ok2 and DEBUG then
                printf("[AstroFace] " .. topic .. " 回调出错: " .. tostring(err2))
            end
        end)
    end)
    if not ok and DEBUG then
        printf("[AstroFace] 订阅失败 " .. topic .. ": " .. tostring(err))
    end
end

sub("timeHour",   function(v) S.hour = decodeInt(v, S.hour); S.timeSynced = true end)
sub("timeMinute", function(v) S.min  = decodeInt(v, S.min);  S.timeSynced = true end)
sub("dateYear",   function(v) S.year  = decodeInt(v, S.year) end)
sub("dateMonth",  function(v) S.month = decodeInt(v, S.month) end)
sub("dateDay",    function(v) S.day   = decodeInt(v, S.day) end)
sub("dateWeek",   function(v) S.week  = decodeInt(v, S.week) end)
sub("dateLunarMonth", function(v) S.lunarMonth = decodeInt(v, 0) end)
sub("dateLunarDay",   function(v) S.lunarDay   = decodeInt(v, 0) end)

sub("weatherCurrentWeather",     function(v) S.weatherCode = decodeInt(v, nil); nameDirty = true end)
sub("weatherCurrentTemperature", function(v) S.temp = decodeFixed(v, true); nameDirty = true end)
sub("weatherCurrentSunRiseHour",   function(v) S.riseH = decodeInt(v, nil) end)
sub("weatherCurrentSunRiseMinute", function(v) S.riseM = decodeInt(v, 0) end)
sub("weatherCurrentSunSetHour",    function(v) S.setH  = decodeInt(v, nil) end)
sub("weatherCurrentSunSetMinute",  function(v) S.setM  = decodeInt(v, 0) end)

-- ============================================================
-- 主更新调度：只做必要的重绘
-- ============================================================

local last = { min = -1, day = -1, night = nil, wx = nil, phaseKey = nil, moonUp = nil }

local function fullRedraw()
    drawDate()
    drawWeek()
    renderLayout()
end

--- dataman 时间主题兜底：从未收到过推送时退回系统时钟轮询。
--- 只判"从未收到"，不判"多久没收到"——timeMinute 本来就是整分钟才推一次，
--- 最长 60 秒无推送属正常，用超时判断会误伤。
local function fallbackTime()
    if S.timeSynced then return end
    local t = os.date("*t")
    S.hour, S.min = t.hour, t.min
    S.year, S.month, S.day = t.year, t.month, t.day
    S.week = (t.wday - 1) % 7
end

-- ============================================================
-- 快应用配置桥（v1.6+）：读配套快应用写的 key=value 配置文件。
-- 快应用（com.astroface.config）用 @system.file 写 internal://files/
-- astroface_config.txt → 真机路径 /data/quickapp/files/com.astroface.config/。
-- 只用 io.open（真机可用，skill §10.1 实证）；没装快应用是常态，读不到静默跳过。
-- ============================================================

local cfgTick = 0                    -- 轮询计数器（每 poll_ticks 次 1s tick 读一次）
local lastCfgLayout, lastCfgStyle = S.layout, C.STYLE

local function loadRemoteConfig()
    if not C.CONFIG.enabled then return end
    if not io or not io.open then return end
    local ok, f = pcall(io.open, C.CONFIG.path, "r")
    if not ok or not f then return end
    local ok2, data = pcall(function() return f:read("*a") end)
    pcall(function() f:close() end)
    if not ok2 or type(data) ~= "string" or #data == 0 then return end

    -- key=value 行解析（不依赖 JSON 库，快应用侧写同样格式）
    local cfg = {}
    for k, v in data:gmatch("([%w_]+)%s*=%s*([%w_]+)") do
        cfg[k] = v
    end

    -- 布局：合法值且与当前不同才切（非法值/重复值一律忽略，不重绘）
    if cfg.layout and cfg.layout ~= lastCfgLayout then
        for _, n in ipairs(C.LAYOUT_ORDER) do
            if n == cfg.layout then
                lastCfgLayout = n
                S.layout = n
                fullRedraw()
                break
            end
        end
    end

    -- 样式：合法值且与当前不同才切。applyStyle 换 C.COLOR 指向后必须
    -- rebuildPalettes() 重建三个静态调色板，否则软画布仍用旧颜色。
    if cfg.style and cfg.style ~= lastCfgStyle then
        if C.STYLES and C.STYLES[cfg.style] then
            lastCfgStyle = cfg.style
            C.STYLE = cfg.style
            applyStyle()
            rebuildPalettes()
            fullRedraw()
        end
    end
end

local function onTick()
    fallbackTime()

    -- 快应用配置轮询（30 秒一次，读不到文件 io.open 返回 nil 开销可忽略）
    cfgTick = cfgTick + 1
    if cfgTick >= (C.CONFIG.poll_ticks or 30) then
        cfgTick = 0
        loadRemoteConfig()
    end

    local night = isNightNow()
    S.isNight = night
    -- 显式刷新月相缓存（副作用：更新 S.phase / S.phaseDayKey），供下方脏检查使用。
    -- 不能指望 isMoonUp() 内部间接调用：它在 MOON_VISIBILITY 关闭或 force_moon_up
    -- 调试开关生效时会提前 return，那样月相变化检测会彻底失效。
    currentPhase()
    local moonUp = isMoonUp()
    S.moonUp = moonUp

    local redrawStage = false
    if night ~= last.night or S.weatherCode ~= last.wx then
        last.night = night
        last.wx = S.weatherCode
        redrawStage = true
    end
    if S.phaseDayKey ~= last.phaseKey then
        last.phaseKey = S.phaseDayKey
        if night then redrawStage = true end
    end
    if moonUp ~= last.moonUp then
        last.moonUp = moonUp
        if night then redrawStage = true end
    end

    if redrawStage then
        renderLayout()
        nameDirty = false
    elseif nameDirty then
        drawName()
        nameDirty = false
    end

    -- 两层正交，不要嵌套：分钟变→重画时间；日期变→重画日期+星期。
    -- 原先 drawWeek 被嵌在 hour 分支里，星期明明该跟 day 走却跟 hour 耦合了。
    -- hour 本身不触发任何重绘（时间行由 drawTime 整体重画），故不再单独跟踪它。
    if S.min ~= last.min then
        last.min = S.min
        drawTime()
    end
    if S.day ~= last.day then
        last.day = S.day
        drawDate()
        drawWeek()
    end
end

-- ============================================================
-- 启动
-- ============================================================

local now = os.date("*t")
S.hour, S.min = now.hour, now.min
S.year, S.month, S.day = now.year, now.month, now.day
S.week = (now.wday - 1) % 7

S.isNight = isNightNow()
S.moonUp = isMoonUp()
last.night = S.isNight
last.wx = S.weatherCode
last.phaseKey = S.phaseDayKey
last.moonUp = S.moonUp
last.min, last.day = S.min, S.day

loadRemoteConfig()   -- 开机读一次快应用配置（布局/样式立即生效）
fullRedraw()

-- 供 PC 模拟器读取当前状态（S/C 都是 local，Python 侧拿不到全局）；
-- 真机上无人调用，无副作用。
function astrofaceState()
    return { layout = S.layout, style = C.STYLE }
end

local timer = lvgl.Timer({
    paused = false,
    period = 1000,
    cb = function() onTick() end,
})

--- 页面切后台停表，省电
function pageOnPause()
    if timer then timer:pause() end
end

--- 页面回前台恢复
function pageOnResume()
    if timer then timer:resume() end
end

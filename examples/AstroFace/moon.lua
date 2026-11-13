--[[
月相模块

两条计算路线：
    1. 天文算法（astro）：以 2000-01-06 18:14 UTC 的朔为基准，
       按 29.530588853 天的朔望月周期推算当前相位。不依赖手表是否推送农历，
       通用性最好。
    2. 农历日（lunar）：直接用 dataman 的 dateLunarDay。
       中国农历本身按朔望月编排，初一必为朔、十五前后必为望，
       对国内用户而言比天文算法更贴合直觉。

config.MOON.mode = "auto" 时优先农历，农历缺失则回落天文。

绘制原理：
    把月面看作被平行光照射的球体。对屏幕上归一化坐标 (x, y)，
    球面法线的 z 分量为 z = sqrt(1 - x^2 - y^2)，光照方向
    L = (sin θ, 0, -cos θ)，其中 θ = 2π·phase。
    受光条件是 x·sinθ - z·cosθ > 0。

    固定某一行 y 求解界线，可解析得到：
        x_t = sign(sinθ) · cosθ · sqrt(1 - y^2)
    - sinθ > 0（phase 在 0 ~ 0.5，上半月）时受光区在 x_t 右侧
    - sinθ < 0（phase 在 0.5 ~ 1，下半月）时受光区在 x_t 左侧

    于是逐行填充一次矩形就能画出真正的椭圆状明暗界线，
    不需要任何月相图片序列。
--]]

local Moon = {}

-- 朔望月周期（天）
local SYNODIC = 29.530588853
-- 参考新月时刻：2000-01-06 18:14 UTC 对应的儒略日
local JD_NEW_MOON = 2451550.26

--- 由公历 UTC 时间计算儒略日
--- 对 1900 - 2100 年有效，足够表盘使用
---@param year integer
---@param month integer 1 - 12
---@param day integer 1 - 31
---@param hour integer 0 - 23
---@param min integer 0 - 59
---@return number 儒略日
function Moon.julianDay(year, month, day, hour, min)
    local y, m = year, month
    if m <= 2 then
        y = y - 1
        m = m + 12
    end
    local A = math.floor(y / 100)
    local B = 2 - A + math.floor(A / 4)
    local jd = math.floor(365.25 * (y + 4716))
        + math.floor(30.6001 * (m + 1))
        + day + B - 1524.5
    -- 加上当天的小数部分
    return jd + ((hour or 0) + (min or 0) / 60) / 24
end

--- Meeus《天文算法》第 49 章的月球相位角公式。
--- 相比纯线性周期模型，它额外修正了月球轨道偏心率带来的摄动，
--- 实测与真实朔望时刻的偏差在 0.02 天（约半小时）以内。
---
--- 注意：Meeus 定义的相位角 i 与常见习惯相反——
--- i = 0 度是满月，i = 180 度是新月，因此最后要做一次半周期平移。
---@param jd number 儒略日
---@return number|nil phase，三角函数不可用时返回 nil
function Moon.phaseMeeus(jd)
    if not math.sin then return nil end

    local T = (jd - 2451545.0) / 36525.0
    local T2, T3, T4 = T * T, T * T * T, T * T * T * T

    -- 月球平距角、太阳平近点角、月球平近点角
    local D  = 297.8501921 + 445267.1114034 * T - 0.0018819 * T2
               + T3 / 545868.0 - T4 / 113065000.0
    local M  = 357.5291092 + 35999.0502909 * T - 0.0001536 * T2
               + T3 / 24490000.0
    local Mp = 134.9633964 + 477198.8675055 * T + 0.0087414 * T2
               + T3 / 69699.0 - T4 / 14712000.0

    local rad = math.rad
    local i = 180.0 - D
        - 6.289 * math.sin(rad(Mp))
        + 2.100 * math.sin(rad(M))
        - 1.274 * math.sin(rad(2 * D - Mp))
        - 0.658 * math.sin(rad(2 * D))
        - 0.214 * math.sin(rad(2 * Mp))
        - 0.110 * math.sin(rad(D))

    i = i % 360.0
    -- Meeus 的 i 与"相位角"（Moon-Sun 视方向角）方向相反：
    -- i = 0   → 满月（视方向角 180°）
    -- i = 180 → 新月（视方向角   0°）
    -- 因此要做 0.5 - i/360 的"翻转+平移"，不能简单 +0.5 平移——
    -- 简单 +0.5 会让上弦算成下弦、亏凸算成盈凸（盈亏方向反）。
    -- 校验：满月 i=0 → 0.5；新月 i=180 → 0；上弦 i=90 → 0.25；下弦 i=270 → 0.75 ✓
    return (0.5 - i / 360.0) % 1.0
end

--- 天文算法计算月相，优先 Meeus 摄动公式，不可用时退回线性周期模型
---@param t table|nil os.date("!*t") 风格的 UTC 时间表，nil 时取当前 UTC
---@return number phase 0.0 = 新月，0.5 = 满月
function Moon.phaseFromDate(t)
    t = t or os.date("!*t")
    local jd = Moon.julianDay(t.year, t.month, t.day, t.hour, t.min)

    local ok, p = pcall(Moon.phaseMeeus, jd)
    if ok and p then return p end

    -- 退回：以 2000-01-06 18:14 UTC 的朔为基准做线性推算，
    -- 精度约 ±0.4 天，肉眼在表盘上无法分辨
    local age = (jd - JD_NEW_MOON) % SYNODIC
    if age < 0 then age = age + SYNODIC end
    return age / SYNODIC
end

--- 由农历日推算月相
--- 农历初一为朔，因此 (day - 1) 就是月龄
---@param lunar_day number 农历日 1 - 30
---@return number phase
function Moon.phaseFromLunarDay(lunar_day)
    local age = lunar_day - 1
    if age < 0 then age = 0 end
    if age > SYNODIC then age = SYNODIC end
    return age / SYNODIC
end

--- 受光比例（百分比整数）
---@param phase number
---@return integer 0 - 100
function Moon.illumination(phase)
    local f = (1 - math.cos(2 * math.pi * phase)) / 2
    return math.floor(f * 100 + 0.5)
end

--- 八相中文名
local PHASE_NAMES = {
    "新月", "娥眉月", "上弦月", "盈凸月",
    "满月", "亏凸月", "下弦月", "残月",
}

--- 月相中文名
---@param phase number
---@return string
function Moon.name(phase)
    local idx = math.floor(phase * 8 + 0.5)
    if idx >= 8 then idx = 0 end
    return PHASE_NAMES[idx + 1]
end

--- 把月相画到软画布上
--- 约定调色板：1 = 暗面，2 = 受光面
---@param canvas table Canvas 实例
---@param cx number 画布内圆心 X
---@param cy number 画布内圆心 Y
---@param r number 月面半径
---@param phase number 0.0 - 1.0
function Moon.draw(canvas, cx, cy, r, phase)
    local DARK, LIT = 1, 2

    -- 先铺整个月面为暗面，保留轮廓，暗夜里也能看清月盘
    canvas:fillCircle(cx, cy, r, DARK)

    local theta = 2 * math.pi * phase
    local s = math.sin(theta)
    local c = math.cos(theta)

    -- 新月附近几乎没有受光区，满月附近几乎没有暗区，直接整盘着色即可
    if math.abs(s) < 1e-6 then
        if c < 0 then
            canvas:fillCircle(cx, cy, r, LIT)
        end
        return
    end

    local ss = (s > 0) and 1 or -1
    local r2 = r * r
    local y0 = math.floor(cy - r)
    local y1 = math.ceil(cy + r)

    for yy = y0, y1 do
        local dy = yy + 0.5 - cy
        local d2 = r2 - dy * dy
        if d2 > 0 then
            local halfW = math.sqrt(d2)
            -- 明暗界线在该行的 X 坐标
            local xt = cx + ss * c * halfW
            local left, right
            if s > 0 then
                -- 上半月：界线右侧受光
                left, right = xt, cx + halfW
            else
                -- 下半月：界线左侧受光
                left, right = cx - halfW, xt
            end
            local xa = math.ceil(left - 0.5)
            local xb = math.floor(right + 0.5) - 1
            if xb >= xa then
                canvas:fillRect(xa, yy, xb - xa + 1, 1, LIT)
            end
        end
    end
end

return Moon

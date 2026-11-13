--[[
软画布（Software Canvas）

设计目标：
    表盘上的天气图标与月相全部由代码在内存中光栅化生成，不依赖任何图片资源，
    从而把表盘体积压到几十 KB 级别（传统图片表盘通常在 300KB - 1MB）。

工作原理：
    1. 维护一块 w x h 的调色板索引缓冲区（每像素 1 字节，0 表示透明）。
    2. 提供 fillRect / fillCircle / ring / line / tri 等几何图元，把形状写进缓冲区。
    3. flush 时按行扫描缓冲区，把连续的同色像素合并成横向色段，
       再与上一行做贪心垂直合并，得到尽量少的矩形。
    4. 这些矩形复用事先创建好的 lvgl.Object 对象池，只改 x/y/w/h/颜色，
       避免频繁创建销毁控件。

为什么是矩形而不是逐像素：
    一块 96 x 96 的画布有 9216 个像素，逐个建控件会拖垮渲染。
    按行合并后通常只需 60 - 120 个矩形，实机刷新无压力。
--]]

local lvgl = require("lvgl")

local Canvas = {}
Canvas.__index = Canvas

-- LVGL 各版本对 FLAG.HIDDEN 的暴露情况不一致，取不到时退回用零尺寸隐藏，
-- 保证在任何固件上都不会因为常量缺失而报错。
local FLAG_HIDDEN = (lvgl.FLAG and lvgl.FLAG.HIDDEN) or nil

--- 创建一个新的软画布
---@param parent userdata 父容器
---@param x integer 画布左上角在父容器中的 X
---@param y integer 画布左上角在父容器中的 Y
---@param w integer 画布宽度
---@param h integer 画布高度
---@param pool_size integer 对象池大小（同时存在的最大矩形数）
---@return table
function Canvas.new(parent, x, y, w, h, pool_size)
    local self = setmetatable({}, Canvas)

    self.x = x
    self.y = y
    self.w = w
    self.h = h
    self.buf = {}
    self.pool = {}
    self.pool_size = pool_size or 160
    self.dirty = true

    -- 缓冲区初始化为全透明（0）
    for i = 1, w * h do
        self.buf[i] = 0
    end

    -- 预建对象池。每个池对象都是一个 1x1 的无边框方块，
    -- 后续只修改几何与颜色，不重新创建。
    for i = 1, self.pool_size do
        local obj = lvgl.Object(parent, {
            x = 0, y = 0, w = 0, h = 0,
            bg_color = 0x000000,
            bg_opa = lvgl.OPA(100),
            border_width = 0,
            outline_width = 0,
            pad_all = 0,
            radius = 0,
        })
        obj:clear_flag(lvgl.FLAG.SCROLLABLE)
        self.pool[i] = obj
    end

    return self
end

--- 清空画布（全部置为透明）
function Canvas:clear()
    local buf = self.buf
    for i = 1, self.w * self.h do
        buf[i] = 0
    end
    self.dirty = true
end

--- 写入单个像素
---@param x integer
---@param y integer
---@param v integer 调色板索引，0 为透明
function Canvas:set(x, y, v)
    if x < 0 or y < 0 or x >= self.w or y >= self.h then return end
    self.buf[y * self.w + x + 1] = v
    self.dirty = true
end

--- 读取单个像素
---@param x integer
---@param y integer
---@return integer
function Canvas:get(x, y)
    if x < 0 or y < 0 or x >= self.w or y >= self.h then return 0 end
    return self.buf[y * self.w + x + 1]
end

--- 填充矩形
---@param x integer 左上角 X
---@param y integer 左上角 Y
---@param w integer 宽度
---@param h integer 高度
---@param v integer 颜色索引
function Canvas:fillRect(x, y, w, h, v)
    if w <= 0 or h <= 0 then return end
    local x0, y0 = x, y
    local x1, y1 = x + w - 1, y + h - 1
    if x0 < 0 then x0 = 0 end
    if y0 < 0 then y0 = 0 end
    if x1 >= self.w then x1 = self.w - 1 end
    if y1 >= self.h then y1 = self.h - 1 end

    local buf, cw = self.buf, self.w
    for yy = y0, y1 do
        local base = yy * cw
        for xx = x0, x1 do
            buf[base + xx + 1] = v
        end
    end
    self.dirty = true
end

--- 填充实心圆（行扫描实现，比逐像素距离判断快）
---@param cx number 圆心 X
---@param cy number 圆心 Y
---@param r number 半径
---@param v integer 颜色索引
function Canvas:fillCircle(cx, cy, r, v)
    if r <= 0 then return end
    local y0 = math.floor(cy - r)
    local y1 = math.ceil(cy + r)
    if y0 < 0 then y0 = 0 end
    if y1 >= self.h then y1 = self.h - 1 end

    local r2 = r * r
    for yy = y0, y1 do
        local dy = yy + 0.5 - cy
        local d2 = r2 - dy * dy
        if d2 >= 0 then
            local dx = math.sqrt(d2)
            local xa = math.floor(cx - dx + 0.5)
            local xb = math.ceil(cx + dx - 0.5)
            if xa < 0 then xa = 0 end
            if xb >= self.w then xb = self.w - 1 end
            local base = yy * self.w
            for xx = xa, xb do
                self.buf[base + xx + 1] = v
            end
        end
    end
    self.dirty = true
end

--- 在软画布上按 0/1 位图画点（墨点风格：step 网格 + dot 圆点留间隙）。
--- 用于软画布字模（意境字/距望）与迷你数字，颜色由调色板索引决定。
---@param rows table rows[y][x] = 0/1（1-based 索引）
---@param x number 内容左上角 X（画布内坐标）
---@param y number 内容左上角 Y
---@param step number 每格像素
---@param dot number 点径（<= step 自动留出"墨点间隙"）
---@param v integer 调色板索引
---@return number 位图宽度（cols * step）
function Canvas:bitmap(rows, x, y, step, dot, v)
    if not rows or #rows == 0 then return 0 end
    local cols = #rows[1]
    local half = dot / 2
    for gy = 1, #rows do
        local py = y + (gy - 0.5) * step
        local row = rows[gy]
        for gx = 1, cols do
            if row[gx] == 1 then
                self:fillCircle(x + (gx - 0.5) * step, py, half, v)
            end
        end
    end
    return cols * step
end

--- 绘制圆环（空心圆）
---@param cx number 圆心 X
---@param cy number 圆心 Y
---@param r number 半径（环的中心线半径）
---@param t number 环线粗细（像素）
---@param v integer 颜色索引
function Canvas:ring(cx, cy, r, t, v)
    if r <= 0 or t <= 0 then return end
    local inner = r - t / 2
    local outer = r + t / 2
    local inner2 = inner * inner
    local outer2 = outer * outer

    local y0 = math.floor(cy - outer)
    local y1 = math.ceil(cy + outer)
    if y0 < 0 then y0 = 0 end
    if y1 >= self.h then y1 = self.h - 1 end

    for yy = y0, y1 do
        local dy = yy + 0.5 - cy
        local dy2 = dy * dy
        local od2 = outer2 - dy2
        if od2 > 0 then
            local odx = math.sqrt(od2)
            local id2 = inner2 - dy2
            local idx = (id2 > 0) and math.sqrt(id2) or 0
            -- 左右两侧各填充一段
            local lxa = math.floor(cx - odx + 0.5)
            local lxb = math.ceil(cx - idx - 0.5)
            local rxa = math.floor(cx + idx + 0.5)
            local rxb = math.ceil(cx + odx - 0.5)
            local base = yy * self.w

            if lxa < 0 then lxa = 0 end
            if rxb >= self.w then rxb = self.w - 1 end
            for xx = lxa, lxb do
                if xx >= 0 and xx < self.w then self.buf[base + xx + 1] = v end
            end
            for xx = rxa, rxb do
                if xx >= 0 and xx < self.w then self.buf[base + xx + 1] = v end
            end
        end
    end
    self.dirty = true
end

--- 绘制线段（Bresenham + 方形笔头，thickness 为笔宽）
---@param x0 number 起点 X
---@param y0 number 起点 Y
---@param x1 number 终点 X
---@param y1 number 终点 Y
---@param thickness number 线宽
---@param v integer 颜色索引
function Canvas:line(x0, y0, x1, y1, thickness, v)
    local t = thickness or 1
    local dx = x1 - x0
    local dy = y1 - y0
    local steps = math.max(math.abs(dx), math.abs(dy))
    if steps < 1 then steps = 1 end

    local sx = dx / steps
    local sy = dy / steps
    local half = (t - 1) / 2

    for i = 0, steps do
        local px = x0 + sx * i
        local py = y0 + sy * i
        if t <= 1 then
            self:set(math.floor(px + 0.5), math.floor(py + 0.5), v)
        else
            local rx = math.floor(px - half + 0.5)
            local ry = math.floor(py - half + 0.5)
            self:fillRect(rx, ry, t, t, v)
        end
    end
    self.dirty = true
end

--- 填充三角形（扫描线算法）
---@param x0 number
---@param y0 number
---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@param v integer 颜色索引
function Canvas:tri(x0, y0, x1, y1, x2, y2, v)
    -- 按 Y 排序，保证 y0 <= y1 <= y2
    if y0 > y1 then x0, y0, x1, y1 = x1, y1, x0, y0 end
    if y1 > y2 then x1, y1, x2, y2 = x2, y2, x1, y1 end
    if y0 > y1 then x0, y0, x1, y1 = x1, y1, x0, y0 end

    local ys = math.floor(y0 + 0.5)
    local ye = math.ceil(y2 - 0.5)
    if ys < 0 then ys = 0 end
    if ye >= self.h then ye = self.h - 1 end

    for yy = ys, ye do
        local yc = yy + 0.5
        -- 求该扫描线与三条边的交点 X，取最小和最大构成区间
        local lo, hi
        local function edge(ax, ay, bx, by)
            if (ay <= yc and by > yc) or (by <= yc and ay > yc) then
                local t = (yc - ay) / (by - ay)
                local x = ax + (bx - ax) * t
                if lo == nil or x < lo then lo = x end
                if hi == nil or x > hi then hi = x end
            end
        end
        edge(x0, y0, x1, y1)
        edge(x1, y1, x2, y2)
        edge(x2, y2, x0, y0)

        if lo ~= nil then
            local xa = math.floor(lo + 0.5)
            local xb = math.ceil(hi - 0.5)
            if xa < 0 then xa = 0 end
            if xb >= self.w then xb = self.w - 1 end
            local base = yy * self.w
            for xx = xa, xb do
                self.buf[base + xx + 1] = v
            end
        end
    end
    self.dirty = true
end

--- 批量绘制图元
--- 图元编码：{1,cx,cy,r} 圆 / {2,x,y,w,h} 矩形 / {3,x0,y0,x1,y1,t} 线段
---            {4,cx,cy,r,t} 圆环 / {5,x0,y0,x1,y1,x2,y2} 三角形
---@param prims table 图元列表
---@param v integer 颜色索引
---@param ox number|nil 整体 X 偏移
---@param oy number|nil 整体 Y 偏移
function Canvas:drawPrims(prims, v, ox, oy)
    local dx, dy = ox or 0, oy or 0
    for i = 1, #prims do
        local p = prims[i]
        local t = p[1]
        if t == 1 then
            self:fillCircle(p[2] + dx, p[3] + dy, p[4], v)
        elseif t == 2 then
            self:fillRect(p[2] + dx, p[3] + dy, p[4], p[5], v)
        elseif t == 3 then
            self:line(p[2] + dx, p[3] + dy, p[4] + dx, p[5] + dy, p[6], v)
        elseif t == 4 then
            self:ring(p[2] + dx, p[3] + dy, p[4], p[5], v)
        elseif t == 5 then
            self:tri(p[2] + dx, p[3] + dy, p[4] + dx, p[5] + dy,
                     p[6] + dx, p[7] + dy, v)
        end
    end
    self.dirty = true
end

--- 把缓冲区扫描成尽量少的矩形
--- 先按行切分横向色段，再与上一行的同位置同色段做垂直合并。
---@return table 矩形列表，每项 {x, y, w, h, v}
function Canvas:_scanRects()
    local rects = {}
    local prev = {}   -- 上一行段的位置索引，key = "x0_w_v"
    local w, h = self.w, self.h
    local buf = self.buf

    for yy = 0, h - 1 do
        local cur = {}
        local base = yy * w
        local x = 0

        while x < w do
            local v = buf[base + x + 1]
            if v ~= 0 then
                -- 找到该段结束位置
                local x2 = x + 1
                while x2 < w and buf[base + x2 + 1] == v do
                    x2 = x2 + 1
                end
                local segW = x2 - x
                local key = x * 4096 + segW * 16 + v
                local idx = prev[key]
                if idx then
                    -- 与上一行完全一致，直接加高
                    rects[idx].h = rects[idx].h + 1
                    cur[key] = idx
                else
                    rects[#rects + 1] = { x = x, y = yy, w = segW, h = 1, v = v }
                    cur[key] = #rects
                end
                x = x2
            else
                x = x + 1
            end
        end
        prev = cur
    end

    return rects
end

--- 将画布内容刷到屏幕上
---@param palette table 调色板，索引 -> 0xRRGGBB 颜色值；索引 0 不使用
---@param ox integer|nil 额外的 X 偏移（默认 0）
---@param oy integer|nil 额外的 Y 偏移（默认 0）
function Canvas:flush(palette, ox, oy)
    local rects = self:_scanRects()
    local bx = self.x + (ox or 0)
    local by = self.y + (oy or 0)
    local pool = self.pool
    local n = 0

    for i = 1, #rects do
        local r = rects[i]
        n = n + 1
        if n > self.pool_size then break end
        local obj = pool[n]
        obj:set({
            x = bx + r.x,
            y = by + r.y,
            w = r.w,
            h = r.h,
            bg_color = palette[r.v] or 0x000000,
            bg_opa = lvgl.OPA(100),
        })
        if FLAG_HIDDEN then obj:clear_flag(FLAG_HIDDEN) end
    end

    -- 余下的池对象收起
    self:_collapseFrom(n + 1)

    self.dirty = false
end

--- 收起从 startIdx 起的池对象：清零尺寸并打隐藏标记
---@param startIdx integer
function Canvas:_collapseFrom(startIdx)
    for i = startIdx, self.pool_size do
        local obj = self.pool[i]
        obj:set({ x = 0, y = 0, w = 0, h = 0 })
        if FLAG_HIDDEN then obj:add_flag(FLAG_HIDDEN) end
    end
end

--- 收起全部池对象并清空画布内容。
--- 语义不同于 flush：flush 是把画布像素刷上屏，hideAll 是让画布彻底不显示。
--- 白天主舞台改用 PNG 天气图标、软画布内容作废时用这个。
--- 别再拿 flush(palette) 当"清空"用——那会白白跑一整遍行扫描才把控件收起来。
function Canvas:hideAll()
    self:clear()
    self:_collapseFrom(1)
    self.dirty = false
end

--- 释放对象池（表盘退出时调用）
function Canvas:destroy()
    for i = 1, self.pool_size do
        if self.pool[i] and self.pool[i].delete then
            self.pool[i]:delete()
        end
        self.pool[i] = nil
    end
end

return Canvas

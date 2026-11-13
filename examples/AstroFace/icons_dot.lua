-- 自动生成，勿手改。来源: tools/gen_icons_dot.py
-- 28x28 点阵天气图标，每图标 112 字节 base64。
local M = {}

M.SIZE = 28
M.ICONS = {
    sunny = "AAAAAAAAAAAAACAAAAAgAAAAIAAAYCAwAHAAcAA4AOAAGCDAAAH8AAAD/gAAB/8AAAf/AAAH/wADz/+eAAf/AAAH/wAAB/8AAAP+AAAB/AAAGCDAADgA4ABwAHAAYCAwAAAgAAAAIAAAACAAAAAAAA==",
    partly = "AAAAAAAAAAAAAAAAAAQAAAAEAAAAREAAAD+AAAA/mAAAP/4AAH//AAA//4AAP//AAB//8AA///AAP//4AD//+AA///gAP//wAB//8AAP/+AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==",
    cloudy = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPgAAAP+AAAH/wAAB/8AAD//gAB//8AA///gAf//8AH///AB///wAf//8AH///AA///wAH//4AB//+AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==",
    rain = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGAAAAH4AAAD/AAAB/4AAD//AAB//8AA///AAP//4AD//+AA///gAP//wAB//8AAP/+AAAAAAAAAAAAABAIAAARCAAAIRAAACIQAABCIAAAQCAA==",
    heavyrain = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPgAAAP+AAAH/wAAB/8AAD//gAB//8AA///gAf//8AH///AB///wAf//8AH///AA///wAH//4AB//+AAAAAAAAAAAAAIxAAAGIwAABGIAAAxGAA==",
    thunder = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGAAAAH4AAAD/AAAB/4AAD//AAB//8AA///AAP//4AD//+AA///gAP//wAB//8AAP/+AAAAwAAAAMAAAAGAAAADAAAAB8AAAAfAAAADgAAABwAA==",
    snow = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGAAAAH4AAAD/AAAB/4AAD//AAB//8AA///AAP//4AD//+AA///gAP//wAB//8AAP/+AAAAAAAAAAAAAAAAAABABAAAQAQAAAGAAAAIIAAAHHAA==",
    fog = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA//+AAAAAAAAAAAAAAAAAA///4AP//+AAAAAAAAAAAAAAAAAAf/8AAAAAAAAAAAAABAAAAA4IAAAECAAAAAAAAAAAAAAAAAA==",
    haze = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAH//8AAAAAAAAAAAAAAAAAAAAAAAP//gAAAAAAAAAAAAAAAAAAAAIAAEACAABAgAAAAIAAAAAAAAAIAAAAHBAAAAg4AAAAEAAAAAAA==",
}

-- 小米天气码 -> 图标名（有序，先命中先用；末项 cloudy 兜底）
M.CODE_LIST = {
    { "sunny", "0" },
    { "partly", "1" },
    { "cloudy", "2" },
    { "thunder", "4,5" },
    { "heavyrain", "9,10,11,12,23,24,25" },
    { "snow", "6,13,14,15,16,17,26,27,28,302" },
    { "fog", "18,32,35,49,57,58" },
    { "haze", "20,29,30,31,53,54,55,56" },
    { "rain", "3,7,8,19,21,22,301" },
    { "cloudy", "" },
}


local B64 = {}
do
    local A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, #A do B64[A:sub(i, i)] = i - 1 end
end

local function b64decode(s)
    local out, n, acc, accbits = {}, 0, 0, 0
    for i = 1, #s do
        local v = B64[s:sub(i, i)]
        if v then
            acc = acc * 64 + v
            accbits = accbits + 6
            if accbits >= 8 then
                accbits = accbits - 8
                n = n + 1
                out[n] = math.floor(acc / (2 ^ accbits)) % 256
            end
        end
    end
    return out
end

local cache = {}

--- 取图标位图 rows[y][x] = 0/1
function M.icon(name)
    if cache[name] then return cache[name] end
    local b64 = M.ICONS[name]
    if not b64 then return nil end
    local bytes = b64decode(b64)
    local rows = {}
    local k = 1
    for y = 1, M.SIZE do
        local val = bytes[k] * 16777216 + bytes[k+1] * 65536 + bytes[k+2] * 256 + bytes[k+3]
        k = k + 4
        local row = {}
        for x = 1, M.SIZE do
            row[x] = math.floor(val / (2 ^ (M.SIZE - x))) % 2
        end
        rows[y] = row
    end
    cache[name] = rows
    return rows
end

--- 天气码 -> 图标名（CODE_LIST 有序，先命中先用）
function M.nameForCode(code)
    for _, entry in ipairs(M.CODE_LIST) do
        local name, list = entry[1], entry[2]
        if list == "" then return name end  -- 兜底项
        for c in list:gmatch("%d+") do
            if tonumber(c) == code then return name end
        end
    end
    return "cloudy"
end

return M

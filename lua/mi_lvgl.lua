-- Mi-style lvgl module built on the native simcore primitives.
local simcore = require("simcore")
local lvgl = {}

lvgl.FLAG = simcore.FLAG
lvgl.EVENT = simcore.EVENT
lvgl.ALIGN = simcore.ALIGN

-- On-device lvgl.HOR_RES()/VER_RES() are functions; keep that call shape.
function lvgl.HOR_RES() return simcore.HOR_RES end
function lvgl.VER_RES() return simcore.VER_RES end

-- lvgl.Object(parent, props); parent nil -> active screen.
function lvgl.Object(parent, props)
    return simcore.object(parent, props)
end

-- lvgl.Image(parent, props) — module-level constructor; the native object
-- metatable also carries :Image{...} so both call styles work unchanged.
lvgl.Image = simcore.image

-- lvgl.Timer({period=, cb=, paused=}) -> {pause=(), resume=()}
lvgl.Timer = simcore.timer

lvgl.tick_get = simcore.tick_get

-- Xiaomi-style percent opacity: OPA(100) == fully opaque (LV_OPA_COVER).
function lvgl.OPA(pct)
    if pct >= 100 then return 255 end
    if pct <= 0 then return 0 end
    return math.floor(pct * 255 / 100 + 0.5)
end

-- Image/set/flag/onevent/Anim are provided directly on the native object
-- metatable, so parent:Image{...} and obj:set{...} work unchanged.

return lvgl

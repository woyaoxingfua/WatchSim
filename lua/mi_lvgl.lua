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

-- lvgl.Label(parent, props) — text properties: text, text_color ('#rrggbb'),
-- text_font (from lvgl.Font), text_align, x/y/width. The device's vendor
-- fonts map onto built-in montserrat sizes (see simcore.font).
lvgl.Label = simcore.label

-- lvgl.Font(name, size) — e.g. lvgl.Font("MiSans-Regular", 18).
lvgl.Font = simcore.font

-- lvgl.Timer({period=, cb=, paused=}) -> {pause=(), resume=()}
lvgl.Timer = simcore.timer

-- Module-level Anim(obj, props); the native object metatable also carries
-- obj:Anim(props). props add path="ease_out", early_apply, done_cb, run.
lvgl.Anim = simcore.Anim

-- Hierarchy helpers some faces call in module form.
lvgl.obj_move_to_index = simcore.obj_move_to_index
lvgl.obj_move_foreground = simcore.obj_move_foreground

-- Headless: no input device, so get_act() is always nil ("no finger").
lvgl.indev = simcore.indev

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

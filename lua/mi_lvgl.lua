-- Mi-style lvgl module built on the native simcore primitives.
local simcore = require("simcore")
local lvgl = {}

lvgl.FLAG = simcore.FLAG
lvgl.EVENT = simcore.EVENT

-- lvgl.Object(parent, props); parent nil -> active screen.
function lvgl.Object(parent, props)
    return simcore.object(parent, props)
end

-- Image/set/flag/onevent/Anim are provided directly on the native object
-- metatable, so parent:Image{...} and obj:set{...} work unchanged.

return lvgl

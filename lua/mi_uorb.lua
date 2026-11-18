-- uorb sensor-node stub. Some faces (e.g. the compass) skip dataman and read
-- raw /dev/uorb/sensor_* nodes directly with io.open + read("*a"). On the
-- host those nodes don't exist, so this module preloads as "uorb" and serves
-- virtual nodes instead; plain file paths fall through to real io.open.
--
-- Frame layouts mirror the on-device firmware (little endian):
--   compass  20 bytes: ts_lo(I4) ts_hi(I4) x(f) y(f) z(f)      heading = y
--   gps      32 bytes: ts_lo(I4) ts_hi(I4) pad(12) lat(f) lon(f) alt(f)
local M = {}

local pack, time = string.pack, os.time

-- node spec: full path -> { size, pack(fmt, fields) }
local SPECS = {
    ["/dev/uorb/sensor_compass0"] = {
        size = 20,
        fields = { "x", "y", "z" },
        frame = function(d)
            return pack("<I4I4fff", d.ts & 0xFFFFFFFF, d.ts >> 32,
                        d.x, d.y, d.z)
        end,
    },
    ["/dev/uorb/sensor_gps0"] = {
        size = 32,
        fields = { "lat", "lon", "alt" },
        frame = function(d)
            -- Lua 5.3 has no 'xN' repeat syntax; spell out 12 pad bytes.
            return pack("<I4I4xxxxxxxxxxxxfff", d.ts & 0xFFFFFFFF, d.ts >> 32,
                        d.lat, d.lon, d.alt)
        end,
    },
}

-- Short aliases for the stdio protocol: SENSOR compass y 45.0
local ALIASES = { compass = "/dev/uorb/sensor_compass0",
                  gps = "/dev/uorb/sensor_gps0" }

local nodes = {}   -- path -> data table

local function default_data(path)
    if path:find("compass") then return { x = 0, y = 0, z = 0 } end
    if path:find("gps") then return { lat = 0, lon = 0, alt = 0 } end
    return {}
end

--- Open a sensor node (read-only). uorb paths get a virtual handle whose
---  read("*a") returns the latest frame; anything else goes to io.open so
---  the module doubles as a drop-in for the on-device uorb.lua.
function M.open(path)
    local spec = SPECS[path]
    if not spec then return io.open(path, "rb") end
    nodes[path] = nodes[path] or default_data(path)
    local d = nodes[path]
    d.ts = d.ts or time()
    local buf = spec.frame(d)
    return {
        read = function(_, _how)
            local cur = nodes[path]
            if cur == nil then return nil end
            return spec.frame(cur)
        end,
        close = function(_)
            nodes[path] = nil   -- match device fd lifecycle: closed fd reads nothing
        end,
    }
end

--- Read `size` bytes from a handle (same shape as the on-device uorb.lua):
---  read everything available, nil if less than `size` bytes came back.
function M.read(fd, size)
    if not fd then return nil end
    local data = fd:read("*a")
    if not data or #data < size then return nil end
    return data:sub(1, size)
end

--- Update one field of a virtual node and refresh its timestamp.
---  node: full path or short alias ("compass"/"gps"); field: "y"/"lat"/...
---  Returns true if the node+field exist.
function M.inject(node, field, value)
    local path = SPECS[node] and node or ALIASES[node]
    if not path then return false end
    local d = nodes[path]
    if d == nil or d[field] == nil then return false end
    d[field] = value + 0.0
    d.ts = time()
    return true
end

M._nodes = nodes
return M

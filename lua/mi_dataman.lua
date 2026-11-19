-- Pure-Lua dataman stub. The control panel drives inject(); face.lua only
-- ever sees subscribe(), so it behaves exactly as on the device.
local dataman = {}
local subs = {}

-- Device-side sentinels (see dataman-topics reference).
dataman.SENTINEL = 2147483647   -- INT_MAX missing-data marker
dataman.NAN = 0                 -- placeholder; use inject_nan() instead

-- Resolve the current mode through the C bridge (exposed as a global).
local function is_aod()
    local sc = rawget(_G, "simcore")
    if sc and sc.is_aod then return sc.is_aod() end
    return false
end

-- dataman.subscribe(key, anchor_obj, callback)
function dataman.subscribe(key, obj, cb)
    subs[#subs + 1] = {key = key, obj = obj, cb = cb, last = nil}
end

-- Publish a raw (already 8.8 fixed-point) value to every matching subscriber.
-- In AOD the device does not push high-frequency duplicates, so unchanged
-- values are suppressed, mirroring the "only set on change" dirty check.
function dataman.inject(key, raw_value)
    local aod = is_aod()
    for _, s in ipairs(subs) do
        if s.key == key then
            if aod and s.last == raw_value then
                dataman.suppressed = (dataman.suppressed or 0) + 1
            else
                s.last = raw_value
                s.cb(s.obj, raw_value)
            end
        end
    end
end

-- Convenience: inject a plain integer using the 8.8 encoding the device uses.
function dataman.inject_int(key, integer_value)
    dataman.inject(key, math.floor(integer_value) * 256)
end

-- Inject a signed integer, encoding negatives in the 16-bit fixed-point form.
function dataman.inject_signed(key, integer_value)
    local raw = math.floor(integer_value) * 256
    if raw < 0 then raw = raw + 65536 end
    dataman.inject(key, raw)
end

-- Inject the missing-data sentinel (face.lua should defend against it).
function dataman.inject_sentinel(key)
    dataman.inject(key, dataman.SENTINEL)
end

-- dataman.updateTime(): on the device this is the runtime asking dataman to
-- refresh its clock topics; in the sim, publish the current wall clock as a
-- normal time snapshot.
function dataman.updateTime()
    local t = os.date("*t")
    dataman.inject_int("timeHour", t.hour)
    dataman.inject_int("timeMinute", t.min)
    dataman.inject_int("timeSecond", t.sec)
end

-- Inject a NaN (face.lua tests with v ~= v).
function dataman.inject_nan(key)
    for _, s in ipairs(subs) do
        if s.key == key then s.cb(s.obj, 0/0) end
    end
end

dataman._subs = subs
dataman.suppressed = 0
return dataman

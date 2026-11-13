-- Sample data injection: a full snapshot at 18:23:37, Nov 11, Wed.
-- Values are plain integers; the stub encodes them as 8.8 fixed point.
local dm = require("dataman")

dm.inject_int("timeHour", 18)
dm.inject_int("timeMinute", 23)
dm.inject_int("timeSecond", 37)
dm.inject_int("dateMonth", 11)
dm.inject_int("dateDay", 11)
dm.inject_int("dateWeek", 3)
dm.inject_int("systemStatusBattery", 71)
dm.inject_int("healthStepCount", 7401)

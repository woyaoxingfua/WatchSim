/* C bridge: exposes a small set of LVGL primitives to Lua. The Mi-style API
 * sugar (Object/Image/set/Anim/flag/event) is organised on top in Lua. */
#ifndef SIM_BRIDGE_H
#define SIM_BRIDGE_H

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

/* Register the native `simcore` module and return the same Lua state. */
lua_State * sim_bridge_newstate(void);

/* Load and run a watch face entry file; mode 0=normal, 1=AOD. */
int sim_bridge_run_face(lua_State * L, const char * entry_path, int aod);

#endif

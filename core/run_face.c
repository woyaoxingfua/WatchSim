#include "sim_display.h"
#include "../bridge/sim_bridge.h"
#include "lvgl.h"
#include <stdio.h>
#include <stdlib.h>
#include <limits.h>
#include <unistd.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#define access(p, m) _access(p, 0)
#define F_OK 0
#endif

/* Make a path absolute against the cwd (device firmware injects absolute
 * SCRIPT_PATH; relative face dirs would break image src resolution). */
static char * abs_path(const char * p)
{
    static char buf[PATH_MAX];
#if _WIN32
    if (p[0] && p[1] == ':') return (char *)p;      /* already absolute */
    if (p[0] == '/' || p[0] == '\\') return (char *)p;
#else
    if (p[0] == '/') return (char *)p;
#endif
    if (!getcwd(buf, sizeof(buf))) return (char *)p;
    size_t n = strlen(buf);
    snprintf(buf + n, sizeof(buf) - n, "/%s", p);
    return buf;
}

/* Run an unmodified watch face under the real LVGL engine.
 * argv: <face_dir> <script_path> <aod 0/1> <out.raw>
 *   face_dir    directory holding face.lua / calendar.lua
 *   script_path value for the global SCRIPT_PATH (ends with '/')
 */
int main(int argc, char ** argv)
{
    if (argc < 5) {
        fprintf(stderr, "usage: %s <face_dir> <script_path> <aod> <out.raw> [inject.lua]\n",
                argv[0]);
        return 1;
    }
    const char * face_dir = abs_path(argv[1]);
    const char * script_path = abs_path(argv[2]);
    int aod = atoi(argv[3]);
    const char * out_raw = argv[4];
    const char * inject_path = (argc >= 6) ? argv[5] : NULL;

    sim_display_init();
    lua_State * L = sim_bridge_newstate();

    /* package table */
    lua_getglobal(L, "package");
    int pkg = lua_gettop(L);

    /* package.path = face_dir/?.lua (so require("calendar") resolves) */
    lua_pushfstring(L, "%s/?.lua", face_dir);
    lua_setfield(L, pkg, "path");

    /* package.loaded table */
    lua_getfield(L, pkg, "loaded");
    int loaded = lua_gettop(L);

    /* loaded.simcore = global simcore */
    lua_getglobal(L, "simcore");
    lua_setfield(L, loaded, "simcore");

    /* loaded.lvgl = dofile(mi_lvgl.lua) */
    lua_getglobal(L, "dofile");
    lua_pushfstring(L, "%s/mi_lvgl.lua", WATCHSIM_LUA_DIR);
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        fprintf(stderr, "mi_lvgl error: %s\n", lua_tostring(L, -1)); return 1;
    }
    lua_setfield(L, loaded, "lvgl");

    /* loaded.dataman = dofile(mi_dataman.lua) */
    lua_getglobal(L, "dofile");
    lua_pushfstring(L, "%s/mi_dataman.lua", WATCHSIM_LUA_DIR);
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        fprintf(stderr, "mi_dataman error: %s\n", lua_tostring(L, -1)); return 1;
    }
    lua_setfield(L, loaded, "dataman");

    /* loaded.uorb = dofile(mi_uorb.lua) — virtual /dev/uorb sensor nodes */
    lua_getglobal(L, "dofile");
    lua_pushfstring(L, "%s/mi_uorb.lua", WATCHSIM_LUA_DIR);
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        fprintf(stderr, "mi_uorb error: %s\n", lua_tostring(L, -1)); return 1;
    }
    lua_setfield(L, loaded, "uorb");

    /* global SCRIPT_PATH */
    lua_pushstring(L, script_path);
    lua_setglobal(L, "SCRIPT_PATH");

    /* run face: face.lua ({start=} convention) or a bare main.lua entry */
    char entry[1100];
    snprintf(entry, sizeof(entry), "%s/face.lua", face_dir);
    if (access(entry, F_OK) != 0) {
        snprintf(entry, sizeof(entry), "%s/main.lua", face_dir);
    }
    if (sim_bridge_run_face_or_main(L, entry, aod) != 0) return 1;

    /* optional data injection before the final layout/render */
    if (inject_path) {
        lua_getglobal(L, "dofile");
        lua_pushstring(L, inject_path);
        if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
            fprintf(stderr, "inject error: %s\n", lua_tostring(L, -1));
            return 1;
        }
    }

    /* force layout so coords and image sizes are resolved before rendering;
     * advance past one period of a 1 s face timer so data injected above
     * gets picked up by the face's own onTick before the frame is dumped */
    lv_obj_update_layout(lv_scr_act());
    sim_render_pump(10);
    sim_tick(1100);
    sim_render_pump(10);

    if (sim_dump_raw(out_raw) != 0) {
        fprintf(stderr, "dump failed\n");
        return 1;
    }
    printf("face rendered (aod=%d) -> %s\n", aod, out_raw);
    return 0;
}

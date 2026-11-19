#include "sim_display.h"
#include "sim_bridge.h"
#include "lvgl.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <unistd.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#define access(p, m) _access(p, 0)
#define F_OK 0
#endif

#define FRAME_BYTES (SIM_HOR_RES * SIM_VER_RES * (int)sizeof(sim_rgba_t))

static char g_face_dir[1100];
static char g_script_path[1100];
static lua_State * g_L = NULL;

/* Build a fresh Lua state, preload the adapter modules and run face.start. */
static int load_face(int aod)
{
    if (g_L) { lua_close(g_L); g_L = NULL; }

    /* Reset LVGL display state for a clean run. */
    sim_display_reset();

    lua_State * L = sim_bridge_newstate();

    lua_getglobal(L, "package");
    int pkg = lua_gettop(L);

    lua_pushfstring(L, "%s/?.lua", g_face_dir);
    lua_setfield(L, pkg, "path");

    lua_getfield(L, pkg, "loaded");
    int loaded = lua_gettop(L);

    lua_getglobal(L, "simcore");
    lua_setfield(L, loaded, "simcore");

    lua_getglobal(L, "dofile");
    lua_pushfstring(L, "%s/mi_lvgl.lua", WATCHSIM_LUA_DIR);
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        fprintf(stderr, "mi_lvgl error: %s\n", lua_tostring(L, -1)); return 1;
    }
    lua_setfield(L, loaded, "lvgl");

    lua_getglobal(L, "dofile");
    lua_pushfstring(L, "%s/mi_dataman.lua", WATCHSIM_LUA_DIR);
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        fprintf(stderr, "mi_dataman error: %s\n", lua_tostring(L, -1)); return 1;
    }
    lua_setfield(L, loaded, "dataman");

    /* loaded.uorb = dofile(mi_uorb.lua) — faces that read /dev/uorb/sensor_*
     * nodes directly get virtual nodes instead of a failing io.open. */
    lua_getglobal(L, "dofile");
    lua_pushfstring(L, "%s/mi_uorb.lua", WATCHSIM_LUA_DIR);
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        fprintf(stderr, "mi_uorb error: %s\n", lua_tostring(L, -1)); return 1;
    }
    lua_setfield(L, loaded, "uorb");

    lua_pushstring(L, g_script_path);
    lua_setglobal(L, "SCRIPT_PATH");

    /* face.lua follows the {start=} convention; faces whose on-device entry
     * is main.lua (no wrapper committed) run that directly instead. */
    char entry[1200];
    snprintf(entry, sizeof(entry), "%s/face.lua", g_face_dir);
    if (access(entry, F_OK) != 0) {
        snprintf(entry, sizeof(entry), "%s/main.lua", g_face_dir);
    }
    if (sim_bridge_run_face_or_main(L, entry, aod) != 0) return 1;

    lv_obj_update_layout(lv_scr_act());
    sim_render_pump(10);

    g_L = L;
    return 0;
}

/* Call a dataman method with a single string and (optional) integer arg. */
static int call_dataman2(const char * method, const char * key, int has_i, long iv)
{
    lua_getglobal(g_L, "require");
    lua_pushstring(g_L, "dataman");
    if (lua_pcall(g_L, 1, 1, 0) != LUA_OK) {
        fprintf(stderr, "require dataman: %s\n", lua_tostring(g_L, -1)); return -1;
    }
    lua_getfield(g_L, -1, method);
    lua_pushstring(g_L, key);
    if (has_i) lua_pushinteger(g_L, iv);
    int narg = has_i ? 2 : 1;
    if (lua_pcall(g_L, narg, 0, 0) != LUA_OK) {
        fprintf(stderr, "dataman.%s: %s\n", method, lua_tostring(g_L, -1));
        lua_pop(g_L, 1); return -1;
    }
    lua_pop(g_L, 1);
    return 0;
}

/* Push one field into a virtual uorb sensor node (see lua/mi_uorb.lua). */
static int call_uorb_inject(const char * node, const char * field, double val)
{
    lua_getglobal(g_L, "require");
    lua_pushstring(g_L, "uorb");
    if (lua_pcall(g_L, 1, 1, 0) != LUA_OK) {
        fprintf(stderr, "require uorb: %s\n", lua_tostring(g_L, -1)); return -1;
    }
    lua_getfield(g_L, -1, "inject");
    lua_pushstring(g_L, node);
    lua_pushstring(g_L, field);
    lua_pushnumber(g_L, (lua_Number)val);
    if (lua_pcall(g_L, 3, 1, 0) != LUA_OK) {
        fprintf(stderr, "uorb.inject: %s\n", lua_tostring(g_L, -1));
        lua_pop(g_L, 1); return -1;
    }
    int found = lua_toboolean(g_L, -1);
    lua_pop(g_L, 1);
    if (!found) {
        fprintf(stderr, "uorb node/field unknown: %s.%s\n", node, field);
        return -1;
    }
    return 0;
}

/* Make a path absolute against the cwd (device firmware injects absolute
 * SCRIPT_PATH; relative face dirs would break image src resolution). */
static char * abs_path(const char * p)
{
    static char buf[PATH_MAX];
    if (p[0] == '/') return (char *)p;
    if (!getcwd(buf, sizeof(buf))) return (char *)p;
    size_t n = strlen(buf);
    snprintf(buf + n, sizeof(buf) - n, "/%s", p);
    return buf;
}

static void emit_frame(void)
{
    lv_obj_update_layout(lv_scr_act());
    /* On-demand rendering: force the refresh timer to run on the next handler
     * instead of waiting for its 30 ms wall-clock period. This also covers the
     * case where the timer was left paused after the previous refresh. */
    lv_disp_t * d = lv_disp_get_default();
    if (d->refr_timer) lv_timer_ready(d->refr_timer);
    sim_render_pump(8);
    printf("FRAME %d\n", FRAME_BYTES);
    fflush(stdout);
    fwrite(sim_framebuffer(), 1, FRAME_BYTES, stdout);
    fflush(stdout);
}

int main(int argc, char ** argv)
{
    setvbuf(stderr, NULL, _IONBF, 0);
    /* Pipes make stdout fully buffered; Lua print() from face code would
     * linger in the buffer between protocol replies. Line-buffered keeps
     * face debug output visible without extra flushes in the protocol. */
    setvbuf(stdout, NULL, _IOLBF, 0);
#ifdef _WIN32
    /* Binary frames go through stdout; text mode would corrupt them. */
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    if (argc < 3) {
        fprintf(stderr, "usage: %s <face_dir> <script_path> [aod]\n", argv[0]);
        return 1;
    }
    snprintf(g_face_dir, sizeof(g_face_dir), "%s", abs_path(argv[1]));
    snprintf(g_script_path, sizeof(g_script_path), "%s", abs_path(argv[2]));
    int aod = (argc >= 4) ? atoi(argv[3]) : 0;

    sim_display_init();
    if (load_face(aod) != 0) { fprintf(stderr, "ERR load failed\n"); return 1; }
    printf("READY\n"); fflush(stdout);

    char line[1400];
    while (fgets(line, sizeof(line), stdin)) {
        char cmd[32], key[128];
        long a = 0, b = 0;
        int n = sscanf(line, "%31s %127s %ld %ld", cmd, key, &a, &b);
        if (n < 1) continue;
        /* TICK takes a bare numeric arg; the shared sscanf puts it in
         * `key`, so re-scan for the number. */
        long tick_ms = 0;
        if (!strcmp(cmd, "TICK")) {
            sscanf(line, "%31s %ld", cmd, &tick_ms);
        }

        if (!strcmp(cmd, "QUIT")) {
            printf("BYE\n"); fflush(stdout);
            break;
        }
        else if (!strcmp(cmd, "MODE")) {
            if (load_face((int)a) != 0) { printf("ERR mode\n"); fflush(stdout); continue; }
            printf("OK mode=%ld\n", a); fflush(stdout);
        }
        else if (!strcmp(cmd, "INJECT") && n >= 3) {
            call_dataman2("inject", key, 1, a);
            printf("OK inject %s\n", key); fflush(stdout);
        }
        else if (!strcmp(cmd, "INJECT_INT") && n >= 3) {
            call_dataman2("inject_int", key, 1, a);
            printf("OK inject_int %s\n", key); fflush(stdout);
        }
        else if (!strcmp(cmd, "SENTINEL") && n >= 2) {
            call_dataman2("inject_sentinel", key, 0, 0);
            printf("OK sentinel %s\n", key); fflush(stdout);
        }
        else if (!strcmp(cmd, "NAN") && n >= 2) {
            call_dataman2("inject_nan", key, 0, 0);
            printf("OK nan %s\n", key); fflush(stdout);
        }
        else if (!strcmp(cmd, "TICK")) {
            sim_tick((uint32_t)tick_ms);
            printf("OK tick %ld\n", tick_ms); fflush(stdout);
        }
        else if (!strcmp(cmd, "SENSOR")) {
            /* SENSOR <node> <field> <float>: node is a short alias
             * ("compass"/"gps") or full /dev/uorb path. Faces poll the
             * node from their own timer, so advance past one poll period
             * to make the value visible in the next frame. The outer
             * sscanf can't parse this (field is a name, not a number),
             * so re-scan the raw line here. */
            char field[64];
            double val = 0;
            if (sscanf(line, "%31s %127s %63s %lf", cmd, key, field, &val) == 4
                && call_uorb_inject(key, field, val) == 0) {
                sim_tick(250);
                printf("OK sensor %s.%s\n", key, field); fflush(stdout);
            } else {
                printf("ERR sensor\n"); fflush(stdout);
            }
        }
        else if (!strcmp(cmd, "DOFILE") && n >= 2) {
            lua_getglobal(g_L, "dofile");
            lua_pushstring(g_L, key);
            if (lua_pcall(g_L, 1, 0, 0) != LUA_OK) {
                fprintf(stderr, "dofile: %s\n", lua_tostring(g_L, -1));
                printf("ERR dofile\n");
            } else printf("OK dofile\n");
            fflush(stdout);
        }
        else if (!strcmp(cmd, "FRAME")) {
            emit_frame();
        }
        else {
            printf("ERR unknown\n"); fflush(stdout);
        }
    }
    return 0;
}

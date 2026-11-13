#include "sim_bridge.h"
#include "../core/sim_display.h"
#include "lvgl.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define OBJ_MT "sim_obj_mt"
#define ANIM_MT "sim_anim_mt"

/* ------------------------------------------------------------------ */
/* Object wrapper                                                      */
/* ------------------------------------------------------------------ */
typedef struct {
    lv_obj_t * obj;
    int event_fn_ref;   /* registry ref for onevent callback */
} sim_obj_t;

typedef struct {
    lv_anim_t anim;
    lua_State * L;
    int target_ref;     /* registry ref to target object userdata */
    int exec_ref;       /* registry ref to exec_cb */
} sim_anim_t;

static lua_State * g_L = NULL;

/* Device mode: 0 = normal (active screen), 1 = AOD (always-on display).
 * On real hardware the AOD runtime does not schedule Lua animations, so the
 * simulator must suppress lv_anim_start while in AOD to stay faithful. */
static int g_aod_mode = 0;

static sim_obj_t * check_obj(lua_State * L, int idx)
{
    return (sim_obj_t *)luaL_checkudata(L, idx, OBJ_MT);
}

static lv_obj_t * parent_from_arg(lua_State * L, int idx)
{
    if (lua_isnil(L, idx) || lua_isnone(L, idx)) return lv_scr_act();
    sim_obj_t * p = check_obj(L, idx);
    return p->obj;
}

/* Apply a Lua table of Mi-style properties onto an LVGL object.
 * Each geometry component is set independently and only when present, so a
 * partial update (e.g. set{y=...}) never clobbers the other component.
 * We deliberately do NOT read back coords, because before layout they may be
 * stale (0), which would wrongly overwrite a previously set style value. */
static void apply_props(lua_State * L, sim_obj_t * so, int tab)
{
    lv_obj_t * o = so->obj;

    lua_pushnil(L);
    while (lua_next(L, tab) != 0) {
        const char * key = luaL_checkstring(L, -2);
        if (!strcmp(key, "x")) {
            lv_obj_set_x(o, (int32_t)luaL_checkinteger(L, -1));
        } else if (!strcmp(key, "y")) {
            lv_obj_set_y(o, (int32_t)luaL_checkinteger(L, -1));
        } else if (!strcmp(key, "w")) {
            lv_obj_set_width(o, (int32_t)luaL_checkinteger(L, -1));
        } else if (!strcmp(key, "h")) {
            lv_obj_set_height(o, (int32_t)luaL_checkinteger(L, -1));
        } else if (!strcmp(key, "bg_color")) {
            lv_obj_set_style_bg_color(o, lv_color_hex((uint32_t)luaL_checkinteger(L, -1)), 0);
        } else if (!strcmp(key, "bg_opa")) {
            lv_obj_set_style_bg_opa(o, (lv_opa_t)luaL_checkinteger(L, -1), 0);
        } else if (!strcmp(key, "border_width")) {
            lv_obj_set_style_border_width(o, (int32_t)luaL_checkinteger(L, -1), 0);
        } else if (!strcmp(key, "pad_all")) {
            lv_obj_set_style_pad_all(o, (int32_t)luaL_checkinteger(L, -1), 0);
        } else if (!strcmp(key, "outline_width")) {
            lv_obj_set_style_outline_width(o, (int32_t)luaL_checkinteger(L, -1), 0);
        } else if (!strcmp(key, "radius")) {
            lv_obj_set_style_radius(o, (int32_t)luaL_checkinteger(L, -1), 0);
        } else if (!strcmp(key, "src")) {
            if (lua_isstring(L, -1)) {
                const char * s = lua_tostring(L, -1);
                if (s[0] == '/') {
                    /* bare absolute path: qualify it for the POSIX drive */
                    char buf[1200];
                    snprintf(buf, sizeof(buf), "P:%s", s);
                    lv_img_set_src(o, buf);
                } else {
                    lv_img_set_src(o, s);
                }
            }
        } else if (!strcmp(key, "angle")) {
            lv_img_set_angle(o, (int16_t)luaL_checkinteger(L, -1));
        }
        lua_pop(L, 1);
    }
}

/* ------------------------------------------------------------------ */
/* Constructors                                                        */
/* ------------------------------------------------------------------ */
static sim_obj_t * push_new_obj(lua_State * L, lv_obj_t * parent, int image)
{
    sim_obj_t * so = (sim_obj_t *)lua_newuserdata(L, sizeof(sim_obj_t));
    so->obj = image ? lv_img_create(parent) : lv_obj_create(parent);
    so->event_fn_ref = LUA_NOREF;
    luaL_getmetatable(L, OBJ_MT);
    lua_setmetatable(L, -2);
    return so;
}

/* simcore.object(parent, props) */
static int l_object(lua_State * L)
{
    lv_obj_t * parent = parent_from_arg(L, 1);
    sim_obj_t * so = push_new_obj(L, parent, 0);
    if (lua_istable(L, 2)) apply_props(L, so, 2);
    return 1;
}

/* simcore.image(parent, props) */
static int l_image(lua_State * L)
{
    lv_obj_t * parent = parent_from_arg(L, 1);
    sim_obj_t * so = push_new_obj(L, parent, 1);
    if (lua_istable(L, 2)) apply_props(L, so, 2);
    return 1;
}

/* ------------------------------------------------------------------ */
/* Methods                                                             */
/* ------------------------------------------------------------------ */
static int m_set(lua_State * L)
{
    sim_obj_t * so = check_obj(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    apply_props(L, so, 2);
    lua_settop(L, 1);
    return 1;
}

static int m_add_flag(lua_State * L)
{
    sim_obj_t * so = check_obj(L, 1);
    lv_obj_add_flag(so->obj, (lv_obj_flag_t)luaL_checkinteger(L, 2));
    return 0;
}

static int m_clear_flag(lua_State * L)
{
    sim_obj_t * so = check_obj(L, 1);
    lv_obj_clear_flag(so->obj, (lv_obj_flag_t)luaL_checkinteger(L, 2));
    return 0;
}

/* LVGL event trampoline -> Lua onevent callback */
static void event_trampoline(lv_event_t * e)
{
    sim_obj_t * so = (sim_obj_t *)lv_event_get_user_data(e);
    lua_State * L = g_L;
    if (!so || so->event_fn_ref == LUA_NOREF) return;
    lua_rawgeti(L, LUA_REGISTRYINDEX, so->event_fn_ref);
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
        fprintf(stderr, "event cb error: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
    }
}

static int m_onevent(lua_State * L)
{
    sim_obj_t * so = check_obj(L, 1);
    lv_event_code_t code = (lv_event_code_t)luaL_checkinteger(L, 2);
    luaL_checktype(L, 3, LUA_TFUNCTION);
    if (so->event_fn_ref != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, so->event_fn_ref);
    lua_pushvalue(L, 3);
    so->event_fn_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    lv_obj_add_event_cb(so->obj, event_trampoline, code, so);
    return 0;
}

static int m_delete(lua_State * L)
{
    sim_obj_t * so = check_obj(L, 1);
    if (so->event_fn_ref != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, so->event_fn_ref);
        so->event_fn_ref = LUA_NOREF;
    }
    lv_obj_del(so->obj);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Animation                                                           */
/* ------------------------------------------------------------------ */
static void anim_exec_trampoline(void * var, int32_t v)
{
    sim_anim_t * sa = (sim_anim_t *)var;
    lua_State * L = sa->L;
    lua_rawgeti(L, LUA_REGISTRYINDEX, sa->exec_ref);
    lua_rawgeti(L, LUA_REGISTRYINDEX, sa->target_ref);
    lua_pushinteger(L, v);
    if (lua_pcall(L, 2, 0, 0) != LUA_OK) {
        fprintf(stderr, "anim exec error: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
    }
}

static sim_anim_t * check_anim(lua_State * L, int idx)
{
    return (sim_anim_t *)luaL_checkudata(L, idx, ANIM_MT);
}

static void anim_apply(lua_State * L, sim_anim_t * sa, int tab, sim_obj_t * target)
{
    int run = 0;
    lua_pushnil(L);
    while (lua_next(L, tab) != 0) {
        const char * key = luaL_checkstring(L, -2);
        if (!strcmp(key, "start_value")) {
            lv_anim_set_values(&sa->anim, (int32_t)luaL_checkinteger(L, -1),
                               sa->anim.end_value);
        } else if (!strcmp(key, "end_value")) {
            lv_anim_set_values(&sa->anim, sa->anim.start_value,
                               (int32_t)luaL_checkinteger(L, -1));
        } else if (!strcmp(key, "duration")) {
            lv_anim_set_time(&sa->anim, (uint32_t)luaL_checkinteger(L, -1));
        } else if (!strcmp(key, "repeat_count")) {
            lv_anim_set_repeat_count(&sa->anim, (uint16_t)luaL_checkinteger(L, -1));
        } else if (!strcmp(key, "path")) {
            lv_anim_set_path_cb(&sa->anim, lv_anim_path_linear);
        } else if (!strcmp(key, "exec_cb")) {
            luaL_checktype(L, -1, LUA_TFUNCTION);
            if (sa->exec_ref != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, sa->exec_ref);
            lua_pushvalue(L, -1);
            sa->exec_ref = luaL_ref(L, LUA_REGISTRYINDEX);
        } else if (!strcmp(key, "run")) {
            run = lua_toboolean(L, -1);
        }
        lua_pop(L, 1);
    }
    (void)target;
    /* Real hardware never runs Lua animations in AOD; mirror that limit. */
    if (run && !g_aod_mode) lv_anim_start(&sa->anim);
}

/* obj:Anim(props) */
static int m_anim(lua_State * L)
{
    sim_obj_t * target = check_obj(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);

    sim_anim_t * sa = (sim_anim_t *)lua_newuserdata(L, sizeof(sim_anim_t));
    memset(sa, 0, sizeof(*sa));
    sa->L = L;
    sa->exec_ref = LUA_NOREF;
    lv_anim_init(&sa->anim);
    lv_anim_set_var(&sa->anim, sa);
    lv_anim_set_exec_cb(&sa->anim, anim_exec_trampoline);
    lv_anim_set_path_cb(&sa->anim, lv_anim_path_linear);

    /* target object ref */
    lua_pushvalue(L, 1);
    sa->target_ref = luaL_ref(L, LUA_REGISTRYINDEX);

    luaL_getmetatable(L, ANIM_MT);
    lua_setmetatable(L, -2);

    anim_apply(L, sa, 2, target);
    return 1;
}

static int anim_m_set(lua_State * L)
{
    sim_anim_t * sa = check_anim(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    anim_apply(L, sa, 2, NULL);
    lua_settop(L, 1);
    return 1;
}

/* ------------------------------------------------------------------ */
/* Module registration                                                 */
/* ------------------------------------------------------------------ */
static const luaL_Reg obj_methods[] = {
    {"set", m_set},
    {"add_flag", m_add_flag},
    {"clear_flag", m_clear_flag},
    {"onevent", m_onevent},
    {"Anim", m_anim},
    {"delete", m_delete},
    {"Image", l_image},
    {NULL, NULL},
};

static const luaL_Reg anim_methods[] = {
    {"set", anim_m_set},
    {NULL, NULL},
};

static int l_set_mode(lua_State * L)
{
    g_aod_mode = lua_toboolean(L, 1) ? 1 : 0;
    return 0;
}

static int l_is_aod(lua_State * L)
{
    lua_pushboolean(L, g_aod_mode);
    return 1;
}

static const luaL_Reg simcore_funcs[] = {
    {"object", l_object},
    {"image", l_image},
    {"set_mode", l_set_mode},
    {"is_aod", l_is_aod},
    {NULL, NULL},
};

static void add_constants(lua_State * L)
{
    /* FLAG: expose real LVGL flag values so the Lua layer never hardcodes them. */
    lua_newtable(L);
    lua_pushinteger(L, LV_OBJ_FLAG_HIDDEN);       lua_setfield(L, -2, "HIDDEN");
    lua_pushinteger(L, LV_OBJ_FLAG_SCROLLABLE);   lua_setfield(L, -2, "SCROLLABLE");
    lua_pushinteger(L, LV_OBJ_FLAG_CLICKABLE);    lua_setfield(L, -2, "CLICKABLE");
    lua_pushinteger(L, LV_OBJ_FLAG_EVENT_BUBBLE); lua_setfield(L, -2, "EVENT_BUBBLE");
    lua_setfield(L, -2, "FLAG");

    lua_newtable(L);
    lua_pushinteger(L, LV_EVENT_SHORT_CLICKED);   lua_setfield(L, -2, "SHORT_CLICKED");
    lua_setfield(L, -2, "EVENT");
}

lua_State * sim_bridge_newstate(void)
{
    lua_State * L = luaL_newstate();
    luaL_openlibs(L);
    g_L = L;

    /* object metatable */
    luaL_newmetatable(L, OBJ_MT);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    luaL_setfuncs(L, obj_methods, 0);
    lua_pop(L, 1);

    /* animation metatable */
    luaL_newmetatable(L, ANIM_MT);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    luaL_setfuncs(L, anim_methods, 0);
    lua_pop(L, 1);

    /* simcore module */
    lua_newtable(L);
    luaL_setfuncs(L, simcore_funcs, 0);
    add_constants(L);
    lua_setglobal(L, "simcore");

    return L;
}

int sim_bridge_run_face(lua_State * L, const char * entry_path, int aod)
{
    /* configure device mode before the face runs so Anim suppression is active */
    g_aod_mode = aod ? 1 : 0;

    /* dofile(entry_path) returns the face module table */
    lua_getglobal(L, "dofile");
    lua_pushstring(L, entry_path);
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        fprintf(stderr, "load face error: %s\n", lua_tostring(L, -1));
        return -1;
    }
    /* call module.start(aod) */
    lua_getfield(L, -1, "start");
    lua_pushinteger(L, aod);
    if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
        fprintf(stderr, "start error: %s\n", lua_tostring(L, -1));
        return -1;
    }
    return 0;
}

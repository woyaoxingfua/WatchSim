#include "sim_bridge.h"
#include "../core/sim_display.h"
#include "lvgl.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define OBJ_MT "sim_obj_mt"
#define ANIM_MT "sim_anim_mt"
#define TIMER_MT "sim_timer_mt"

/* ------------------------------------------------------------------ */
/* Object wrapper                                                      */
/* ------------------------------------------------------------------ */
/* widgets.Pointer value->angle mapping, in LVGL 0.1-degree units:
 * angle = (value - value_start) * angle_range / value_range + angle_start */
typedef struct {
    int32_t angle_start;
    int32_t angle_range;
    int32_t value_start;
    int32_t value_range;
} ptr_range_t;

typedef struct {
    lv_obj_t * obj;
    int event_fn_ref;   /* registry ref for onevent callback */
    int is_pointer;     /* widgets.Pointer: has range mapping + pivot */
    ptr_range_t range;  /* defaults: 0..3600 over 0..360 */
} sim_obj_t;

typedef struct {
    lv_timer_t * timer;
    lua_State * L;
    int cb_ref;         /* registry ref for the tick callback */
} sim_timer_t;

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

/* Device-faithful integer conversion: the on-device runtime accepts floats
 * in set{} (e.g. x = w/2) and truncates them, so don't reject fractional
 * values the way luaL_checkinteger does. */
static int32_t prop_int(lua_State * L, int idx)
{
    return (int32_t)luaL_checknumber(L, idx);
}

/* Colour property: either an integer (0xRRGGBB) or a '#rrggbb' string,
 * the way on-device faces spell text_color. */
static uint32_t prop_color(lua_State * L, int idx)
{
    if (lua_isstring(L, idx)) {
        const char * s = lua_tostring(L, idx);
        if (s[0] == '#') s++;
        return (uint32_t)strtoul(s, NULL, 16);
    }
    return (uint32_t)luaL_checknumber(L, idx);
}

/* Pointer value->angle (0.1-degree units), via the object's range mapping. */
static int32_t ptr_angle(const sim_obj_t * so, lua_Number v)
{
    const ptr_range_t * r = &so->range;
    if (r->value_range == 0) return (int32_t)r->angle_start;
    lua_Number a = (v - (lua_Number)r->value_start) * (lua_Number)r->angle_range
                   / (lua_Number)r->value_range + (lua_Number)r->angle_start;
    return (int32_t)a;
}

/* Set a range table {angleStart=, angleRange=, valueStart=, valueRange=} on a
 * pointer object. Table stays on the stack at `tab`; keys are optional and
 * default to the current values. */
static void apply_ptr_range(lua_State * L, sim_obj_t * so, int tab)
{
    ptr_range_t r = so->range;
    lua_getfield(L, tab, "angleStart");  if (!lua_isnil(L, -1)) r.angle_start = prop_int(L, -1);  lua_pop(L, 1);
    lua_getfield(L, tab, "angleRange");  if (!lua_isnil(L, -1)) r.angle_range = prop_int(L, -1);  lua_pop(L, 1);
    lua_getfield(L, tab, "valueStart");  if (!lua_isnil(L, -1)) r.value_start = prop_int(L, -1);  lua_pop(L, 1);
    lua_getfield(L, tab, "valueRange");  if (!lua_isnil(L, -1)) r.value_range = prop_int(L, -1);  lua_pop(L, 1);
    so->range = r;
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
            lv_obj_set_x(o, prop_int(L, -1));
        } else if (!strcmp(key, "y")) {
            lv_obj_set_y(o, prop_int(L, -1));
        } else if (!strcmp(key, "w")) {
            lv_obj_set_width(o, prop_int(L, -1));
        } else if (!strcmp(key, "h")) {
            lv_obj_set_height(o, prop_int(L, -1));
        } else if (!strcmp(key, "bg_color")) {
            lv_obj_set_style_bg_color(o, lv_color_hex((uint32_t)luaL_checknumber(L, -1)), 0);
        } else if (!strcmp(key, "bg_opa")) {
            lv_obj_set_style_bg_opa(o, (lv_opa_t)prop_int(L, -1), 0);
        } else if (!strcmp(key, "border_width")) {
            lv_obj_set_style_border_width(o, prop_int(L, -1), 0);
        } else if (!strcmp(key, "pad_all")) {
            lv_obj_set_style_pad_all(o, prop_int(L, -1), 0);
        } else if (!strcmp(key, "outline_width")) {
            lv_obj_set_style_outline_width(o, prop_int(L, -1), 0);
        } else if (!strcmp(key, "radius")) {
            lv_obj_set_style_radius(o, prop_int(L, -1), 0);
        } else if (!strcmp(key, "src")) {
            if (lua_isstring(L, -1)) {
                const char * s = lua_tostring(L, -1);
                /* Qualify for the POSIX drive unless it already carries one.
                 * Absolute paths come from SCRIPT_PATH; relative ones resolve
                 * against the driver's base path (the process cwd). */
                if (!(s[0] && s[1] == ':')) {
                    char buf[1200];
                    snprintf(buf, sizeof(buf), "P:%s", s);
                    lv_img_set_src(o, buf);
                } else {
                    lv_img_set_src(o, s);
                }
            }
        } else if (!strcmp(key, "angle")) {
            lv_img_set_angle(o, (int16_t)prop_int(L, -1));
        } else if (!strcmp(key, "align")) {
            lv_obj_set_align(o, (lv_align_t)prop_int(L, -1));
        } else if (!strcmp(key, "pivot")) {
            /* {x=,y=} in image-local coordinates; LVGL default is the centre. */
            if (lua_istable(L, -1) && so->is_pointer) {
                int tab = lua_gettop(L);
                lua_getfield(L, tab, "x");
                lv_coord_t px = (lv_coord_t)prop_int(L, -1);
                lua_pop(L, 1);
                lua_getfield(L, tab, "y");
                lv_coord_t py = (lv_coord_t)prop_int(L, -1);
                lua_pop(L, 1);
                lv_img_set_pivot(o, px, py);
            }
        } else if (!strcmp(key, "range")) {
            if (lua_istable(L, -1) && so->is_pointer) {
                apply_ptr_range(L, so, lua_gettop(L));
            }
        } else if (!strcmp(key, "value")) {
            if (so->is_pointer) {
                lv_img_set_angle(o, (int16_t)ptr_angle(so, luaL_checknumber(L, -1)));
            }
        } else if (!strcmp(key, "text")) {
            lv_label_set_text(o, lua_tostring(L, -1));
        } else if (!strcmp(key, "text_color")) {
            lv_obj_set_style_text_color(o, lv_color_hex(prop_color(L, -1)), 0);
        } else if (!strcmp(key, "text_font")) {
            /* font userdata from simcore.font(name, size) */
            const lv_font_t ** f = (const lv_font_t **)
                luaL_checkudata(L, -1, "sim_font");
            lv_obj_set_style_text_font(o, *f, 0);
        } else if (!strcmp(key, "text_align")) {
            /* Faces pass an lv_align_t (9 values); text align only has
             * left/center/right — centre anything that isn't left(-ish). */
            int a = prop_int(L, -1);
            lv_text_align_t ta = LV_TEXT_ALIGN_CENTER;
            if (a == LV_ALIGN_TOP_LEFT || a == LV_ALIGN_LEFT_MID
                || a == LV_ALIGN_BOTTOM_LEFT) {
                ta = LV_TEXT_ALIGN_LEFT;
            } else if (a == LV_ALIGN_TOP_RIGHT || a == LV_ALIGN_RIGHT_MID
                       || a == LV_ALIGN_BOTTOM_RIGHT) {
                ta = LV_TEXT_ALIGN_RIGHT;
            }
            lv_obj_set_style_text_align(o, ta, 0);
        } else if (!strcmp(key, "width")) {
            lv_obj_set_width(o, prop_int(L, -1));
        }
        lua_pop(L, 1);
    }
}

/* ------------------------------------------------------------------ */
/* Constructors                                                        */
/* ------------------------------------------------------------------ */
/* kind: 0 = plain object, 1 = image, 2 = widgets.Pointer (image + mapping),
 * 3 = label */
static sim_obj_t * push_new_obj(lua_State * L, lv_obj_t * parent, int kind)
{
    sim_obj_t * so = (sim_obj_t *)lua_newuserdata(L, sizeof(sim_obj_t));
    switch (kind) {
    case 1: case 2: so->obj = lv_img_create(parent);  break;
    case 3:         so->obj = lv_label_create(parent); break;
    default:        so->obj = lv_obj_create(parent);  break;
    }
    so->event_fn_ref = LUA_NOREF;
    so->is_pointer   = (kind == 2);
    /* on-device Pointer defaults: 0..360 mapped onto a full turn */
    so->range.angle_start = 0;
    so->range.angle_range = 3600;
    so->range.value_start = 0;
    so->range.value_range = 360;
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

/* simcore.pointer(parent, props) — widgets.Pointer backing */
static int l_pointer(lua_State * L)
{
    lv_obj_t * parent = parent_from_arg(L, 1);
    sim_obj_t * so = push_new_obj(L, parent, 2);
    if (lua_istable(L, 2)) apply_props(L, so, 2);
    return 1;
}

/* simcore.label(parent, props) */
static int l_label(lua_State * L)
{
    lv_obj_t * parent = parent_from_arg(L, 1);
    sim_obj_t * so = push_new_obj(L, parent, 3);
    if (lua_istable(L, 2)) apply_props(L, so, 2);
    return 1;
}

/* simcore.font(name, size) -> font userdata. The device serves vendor fonts
 * (e.g. MiSans); the sim maps the size onto the closest built-in montserrat
 * and warns once about the substitution. */
static int l_font(lua_State * L)
{
    const char * name = luaL_optstring(L, 1, "MiSans-Regular");
    int size = (int)luaL_optnumber(L, 2, 14);

    const lv_font_t * f;
    if      (size <= 12) f = &lv_font_montserrat_12;
    else if (size <= 14) f = &lv_font_montserrat_14;
    else if (size <= 16) f = &lv_font_montserrat_16;
    else if (size <= 20) f = &lv_font_montserrat_20;
    else if (size <= 28) f = &lv_font_montserrat_28;
    else                 f = &lv_font_montserrat_48;
    fprintf(stderr, "[watchsim] font '%s' %d -> built-in montserrat\n",
            name, size);

    const lv_font_t ** fp = (const lv_font_t **)
        lua_newuserdata(L, sizeof(const lv_font_t *));
    *fp = f;
    luaL_getmetatable(L, "sim_font");
    lua_setmetatable(L, -2);
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
            lv_anim_set_values(&sa->anim, prop_int(L, -1),
                               sa->anim.end_value);
        } else if (!strcmp(key, "end_value")) {
            lv_anim_set_values(&sa->anim, sa->anim.start_value,
                               prop_int(L, -1));
        } else if (!strcmp(key, "duration")) {
            lv_anim_set_time(&sa->anim, (uint32_t)prop_int(L, -1));
        } else if (!strcmp(key, "repeat_count")) {
            lv_anim_set_repeat_count(&sa->anim, (uint16_t)prop_int(L, -1));
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
/* Timer (lvgl.Timer on the Lua side)                                  */
/* ------------------------------------------------------------------ */
static void timer_trampoline(lv_timer_t * t)
{
    sim_timer_t * st = (sim_timer_t *)t->user_data;
    lua_rawgeti(st->L, LUA_REGISTRYINDEX, st->cb_ref);
    if (lua_pcall(st->L, 0, 0, 0) != LUA_OK) {
        fprintf(stderr, "timer cb error: %s\n", lua_tostring(st->L, -1));
        lua_pop(st->L, 1);
    }
}

static sim_timer_t * check_timer(lua_State * L, int idx)
{
    return (sim_timer_t *)luaL_checkudata(L, idx, TIMER_MT);
}

/* simcore.timer({period=, cb=, paused=}) */
static int l_timer(lua_State * L)
{
    luaL_checktype(L, 1, LUA_TTABLE);

    sim_timer_t * st = (sim_timer_t *)lua_newuserdata(L, sizeof(sim_timer_t));
    st->timer  = NULL;
    st->L      = L;
    st->cb_ref = LUA_NOREF;

    lua_getfield(L, 1, "period");
    int32_t period = lua_isnumber(L, -1) ? (int32_t)lua_tointeger(L, -1) : 1000;
    lua_pop(L, 1);

    lua_getfield(L, 1, "paused");
    int paused = lua_toboolean(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, 1, "cb");
    luaL_checktype(L, -1, LUA_TFUNCTION);
    lua_pushvalue(L, -1);
    st->cb_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_pop(L, 1);

    st->timer = lv_timer_create(timer_trampoline, (uint32_t)period, st);
    if (paused) lv_timer_pause(st->timer);

    luaL_getmetatable(L, TIMER_MT);
    lua_setmetatable(L, -2);
    return 1;
}

static int tm_pause(lua_State * L)
{
    lv_timer_pause(check_timer(L, 1)->timer);
    return 0;
}

static int tm_resume(lua_State * L)
{
    lv_timer_resume(check_timer(L, 1)->timer);
    return 0;
}

static int tm_gc(lua_State * L)
{
    sim_timer_t * st = check_timer(L, 1);
    if (st->timer) { lv_timer_del(st->timer); st->timer = NULL; }
    if (st->cb_ref != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, st->cb_ref);
        st->cb_ref = LUA_NOREF;
    }
    return 0;
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
    {"Pointer", l_pointer},
    {"Label", l_label},
    {NULL, NULL},
};

static const luaL_Reg anim_methods[] = {
    {"set", anim_m_set},
    {NULL, NULL},
};

static const luaL_Reg timer_methods[] = {
    {"pause", tm_pause},
    {"resume", tm_resume},
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

static int l_tick_get(lua_State * L)
{
    lua_pushinteger(L, lv_tick_get());
    return 1;
}

static const luaL_Reg simcore_funcs[] = {
    {"object", l_object},
    {"image", l_image},
    {"pointer", l_pointer},
    {"label", l_label},
    {"font", l_font},
    {"timer", l_timer},
    {"set_mode", l_set_mode},
    {"is_aod", l_is_aod},
    {"tick_get", l_tick_get},
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

    /* ALIGN: real lv_align_t values, so obj:set{align=lvgl.ALIGN.CENTER} etc. */
    lua_newtable(L);
    lua_pushinteger(L, LV_ALIGN_DEFAULT);       lua_setfield(L, -2, "DEFAULT");
    lua_pushinteger(L, LV_ALIGN_TOP_LEFT);      lua_setfield(L, -2, "TOP_LEFT");
    lua_pushinteger(L, LV_ALIGN_TOP_MID);       lua_setfield(L, -2, "TOP_MID");
    lua_pushinteger(L, LV_ALIGN_TOP_RIGHT);     lua_setfield(L, -2, "TOP_RIGHT");
    lua_pushinteger(L, LV_ALIGN_LEFT_MID);      lua_setfield(L, -2, "LEFT_MID");
    lua_pushinteger(L, LV_ALIGN_CENTER);        lua_setfield(L, -2, "CENTER");
    lua_pushinteger(L, LV_ALIGN_RIGHT_MID);     lua_setfield(L, -2, "RIGHT_MID");
    lua_pushinteger(L, LV_ALIGN_BOTTOM_LEFT);   lua_setfield(L, -2, "BOTTOM_LEFT");
    lua_pushinteger(L, LV_ALIGN_BOTTOM_MID);    lua_setfield(L, -2, "BOTTOM_MID");
    lua_pushinteger(L, LV_ALIGN_BOTTOM_RIGHT);  lua_setfield(L, -2, "BOTTOM_RIGHT");
    lua_setfield(L, -2, "ALIGN");
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

    /* timer metatable */
    luaL_newmetatable(L, TIMER_MT);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    luaL_setfuncs(L, timer_methods, 0);
    lua_pushcfunction(L, tm_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    /* font metatable (no methods; userdata just carries the lv_font_t*) */
    luaL_newmetatable(L, "sim_font");
    lua_pop(L, 1);

    /* simcore module */
    lua_newtable(L);
    luaL_setfuncs(L, simcore_funcs, 0);
    add_constants(L);
    lua_pushinteger(L, SIM_HOR_RES);
    lua_setfield(L, -2, "HOR_RES");
    lua_pushinteger(L, SIM_VER_RES);
    lua_setfield(L, -2, "VER_RES");
    lua_setglobal(L, "simcore");

    /* widgets namespace in the registry. Faces fetch it through
     * debug.getregistry()["widgets"].__index — a *field* named __index
     * holding the constructors (Pointer here), not a metatable. */
    lua_newtable(L);                          /* widgets namespace table */
    lua_newtable(L);                          /* the __index field */
    lua_pushcfunction(L, l_pointer);
    lua_setfield(L, -2, "Pointer");
    lua_setfield(L, -2, "__index");           /* ns.__index = ctor table */
    lua_setfield(L, LUA_REGISTRYINDEX, "widgets");

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

/* Entry-point fallback: face.lua follows the {start=} module convention;
 * a bare main.lua (the on-device entry, returns nothing) runs directly.
 * The caller passes whichever file exists. */
int sim_bridge_run_face_or_main(lua_State * L, const char * entry_path, int aod)
{
    g_aod_mode = aod ? 1 : 0;

    lua_getglobal(L, "dofile");
    lua_pushstring(L, entry_path);
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        fprintf(stderr, "load face error: %s\n", lua_tostring(L, -1));
        return -1;
    }
    /* start() only when the entry returned a face module table */
    if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "start");
        if (lua_isfunction(L, -1)) {
            lua_pushinteger(L, aod);
            if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
                fprintf(stderr, "start error: %s\n", lua_tostring(L, -1));
                return -1;
            }
            return 0;
        }
        lua_pop(L, 1);
    }
    /* plain script entry (main.lua): its return value is discarded */
    lua_pop(L, 1);
    return 0;
}

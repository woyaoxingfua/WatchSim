#include "sim_display.h"
#include <stdio.h>
#include <string.h>

static sim_rgba_t s_fb[SIM_HOR_RES * SIM_VER_RES];
static lv_color_t s_drawbuf[SIM_HOR_RES * SIM_VER_RES];
static lv_disp_draw_buf_t s_disp_buf;
static lv_disp_drv_t s_disp_drv;
static uint32_t s_tick_ms = 0;

static void flush_cb(lv_disp_drv_t * drv, const lv_area_t * area, lv_color_t * color_p)
{
    int32_t x, y;
    uint32_t src_idx = 0;
    for (y = area->y1; y <= area->y2; y++) {
        for (x = area->x1; x <= area->x2; x++) {
            const lv_color32_t c = color_p[src_idx];
            sim_rgba_t * dst = &s_fb[y * SIM_HOR_RES + x];
            dst->r = c.ch.red;
            dst->g = c.ch.green;
            dst->b = c.ch.blue;
            dst->a = c.ch.alpha;
            src_idx++;
        }
    }
    lv_disp_flush_ready(drv);
}

void sim_display_init(void)
{
    lv_init();
    lv_disp_draw_buf_init(&s_disp_buf, s_drawbuf, NULL,
                          SIM_HOR_RES * SIM_VER_RES);
    lv_disp_drv_init(&s_disp_drv);
    s_disp_drv.hor_res = SIM_HOR_RES;
    s_disp_drv.ver_res = SIM_VER_RES;
    s_disp_drv.flush_cb = flush_cb;
    s_disp_drv.draw_buf = &s_disp_buf;
    lv_disp_drv_register(&s_disp_drv);
    memset(s_fb, 0, sizeof(s_fb));
}

void sim_tick(uint32_t ms)
{
    s_tick_ms += ms;
    lv_tick_inc(ms);
    lv_timer_handler();
}

void sim_render_pump(int max_iters)
{
    for (int i = 0; i < max_iters; i++) {
        lv_timer_handler();
    }
}

const sim_rgba_t * sim_framebuffer(void) { return s_fb; }

/* Clear all widgets and the framebuffer so a face can be reloaded on the
 * same LVGL instance without re-initialising the whole library. */
void sim_display_reset(void)
{
    lv_obj_clean(lv_scr_act());
    memset(s_fb, 0, sizeof(s_fb));
}

int sim_dump_raw(const char * path)
{
    FILE * f = fopen(path, "wb");
    if (!f) return -1;
    size_t n = fwrite(s_fb, sizeof(sim_rgba_t),
                      SIM_HOR_RES * SIM_VER_RES, f);
    fclose(f);
    return (n == SIM_HOR_RES * SIM_VER_RES) ? 0 : -1;
}

void dump_tree(lv_obj_t * o, int depth)
{
    for (int i = 0; i < depth; i++) fprintf(stderr, "  ");
    lv_opa_t opa = lv_obj_get_style_bg_opa(o, 0);
    lv_color_t col = lv_obj_get_style_bg_color(o, 0);
    fprintf(stderr, "%p obj x=%d y=%d w=%d h=%d bg_opa=%d bg=0x%06x hidden=%d\n",
            (void*)o,
            (int)lv_obj_get_x(o), (int)lv_obj_get_y(o),
            (int)lv_obj_get_width(o), (int)lv_obj_get_height(o),
            (int)opa, (unsigned)col.full,
            lv_obj_has_flag(o, LV_OBJ_FLAG_HIDDEN) ? 1 : 0);
    uint32_t n = lv_obj_get_child_cnt(o);
    for (uint32_t i = 0; i < n; i++)
        dump_tree(lv_obj_get_child(o, i), depth + 1);
}

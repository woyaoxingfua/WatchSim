#include "sim_display.h"
#include "lvgl.h"
#include <stdio.h>

/* Verify a real lv_anim advances as the LVGL tick is pumped in normal mode. */
int main(int argc, char ** argv)
{
    sim_display_init();
    char src[1024];
    snprintf(src, sizeof(src), "P:%s", argv[1]);

    lv_obj_t * img = lv_img_create(lv_scr_act());
    lv_img_set_src(img, src);
    lv_obj_set_pos(img, 121, 66);

    lv_anim_t a;
    lv_anim_init(&a);
    lv_anim_set_var(&a, img);
    lv_anim_set_values(&a, 0, 1800);
    lv_anim_set_time(&a, 1000);
    lv_anim_set_exec_cb(&a, (lv_anim_exec_xcb_t)lv_img_set_angle);
    lv_anim_start(&a);

    lv_obj_update_layout(lv_scr_act());
    sim_render_pump(10);
    printf("t=0 angle=%d\n", (int)lv_img_get_angle(img));

    /* advance 500 ms */
    for (int i = 0; i < 50; i++) { sim_tick(10); sim_render_pump(2); }
    printf("t=500 angle=%d (expect ~900)\n", (int)lv_img_get_angle(img));

    /* advance to 1100 ms */
    for (int i = 0; i < 60; i++) { sim_tick(10); sim_render_pump(2); }
    printf("t=1100 angle=%d (expect held at 1800)\n", (int)lv_img_get_angle(img));

    sim_dump_raw("build/anim.raw");
    return 0;
}

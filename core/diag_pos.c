#include "sim_display.h"
#include "lvgl.h"
#include <stdio.h>
#include <stdlib.h>

/* Isolate geometry: does set_pos on an image survive layout? */
int main(int argc, char ** argv)
{
    sim_display_init();
    char src[1024];
    snprintf(src, sizeof(src), "P:%s", argv[1]);

    lv_obj_t * img = lv_img_create(lv_scr_act());
    lv_img_set_src(img, src);
    lv_obj_set_pos(img, 121, 66);
    if (argc > 2) lv_img_set_angle(img, (int16_t)atoi(argv[2]));

    lv_obj_update_layout(lv_scr_act());

    printf("style_x=%d style_y=%d\n",
           (int)lv_obj_get_style_x(img, 0),
           (int)lv_obj_get_style_y(img, 0));
    printf("get_x=%d get_y=%d\n",
           (int)lv_obj_get_x(img), (int)lv_obj_get_y(img));
    lv_area_t c;
    lv_obj_get_coords(img, &c);
    printf("coords x1=%d y1=%d x2=%d y2=%d\n",
           (int)c.x1, (int)c.y1, (int)c.x2, (int)c.y2);
    printf("w=%d h=%d\n",
           (int)lv_obj_get_width(img), (int)lv_obj_get_height(img));

    lv_area_t ta;
    lv_point_t piv2;
    lv_img_get_pivot(img, &piv2);
    _lv_img_buf_get_transformed_area(&ta, 32, 184,
        lv_img_get_angle(img), LV_IMG_ZOOM_NONE, &piv2);
    printf("pivot=(%d,%d) transformed local area x=%d..%d y=%d..%d\n",
           (int)piv2.x,(int)piv2.y,(int)ta.x1,(int)ta.x2,(int)ta.y1,(int)ta.y2);

    lv_obj_invalidate(lv_scr_act());
    sim_render_pump(10);
    sim_tick(16);
    sim_render_pump(10);
    sim_dump_raw("build/diag.raw");
    return 0;
}

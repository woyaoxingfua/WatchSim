#include "sim_display.h"
#include <stdio.h>

/* Minimal smoke test: initialise the offscreen display, load a real watch
 * .bin resource through the POSIX file driver, render it, dump raw RGBA. */
int main(int argc, char ** argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <image.bin abs path> <out.raw>\n", argv[0]);
        return 1;
    }
    sim_display_init();

    /* Build a drive-qualified path: P:/abs/path/x.bin */
    char src[1024];
    snprintf(src, sizeof(src), "P:%s", argv[1]);

    lv_obj_t * img = lv_img_create(lv_scr_act());
    lv_img_set_src(img, src);
    lv_obj_center(img);

    sim_render_pump(5);
    sim_tick(16);
    sim_render_pump(5);

    if (sim_dump_raw(argv[2]) != 0) {
        fprintf(stderr, "dump failed\n");
        return 1;
    }
    printf("rendered %s -> %s\n", src, argv[2]);
    return 0;
}

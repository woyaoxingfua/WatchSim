/* Headless offscreen display driver for the watch simulator.
 * It keeps a 336x480 32-bit framebuffer in memory; no window system needed. */
#ifndef SIM_DISPLAY_H
#define SIM_DISPLAY_H

#include "lvgl.h"

#define SIM_HOR_RES 336
#define SIM_VER_RES 480

/* One RGBA pixel in the output framebuffer (byte order R,G,B,A). */
typedef struct { uint8_t r, g, b, a; } sim_rgba_t;

/* Initialise LVGL and register the offscreen display. Call once. */
void sim_display_init(void);

/* Advance LVGL by one tick and run its handler (render pending work). */
void sim_tick(uint32_t ms);

/* Run the handler until nothing is left invalid (bounded by max_iters). */
void sim_render_pump(int max_iters);

/* Pointer to the current framebuffer: SIM_HOR_RES*SIM_VER_RES RGBA pixels. */
const sim_rgba_t * sim_framebuffer(void);

/* Remove all widgets and clear the framebuffer (for reloading a face). */
void sim_display_reset(void);

/* Write the framebuffer as a raw RGBA file (Python converts to PNG). */
int sim_dump_raw(const char * path);

#endif

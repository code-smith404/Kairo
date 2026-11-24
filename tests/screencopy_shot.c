/* screencopy screenshot client used by the shell integration test.
 * Captures a full output through zwlr_screencopy_manager_v1 and writes a PPM.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include "wlr-screencopy-unstable-v1-client-protocol.h"

static struct wl_shm *shm = NULL;
static struct zwlr_screencopy_manager_v1 *scm = NULL;
static struct wl_output *out = NULL;
static int width = 0, height = 0;
static int done = 0;
static int swap_rb = 0;
static uint8_t *data = NULL;
static int stride = 0;
static struct wl_buffer *buffer = NULL;
static struct wl_shm_pool *pool = NULL;

static void shm_format(void *d, struct wl_shm *s, uint32_t format) { (void)d; (void)s; (void)format; }
static const struct wl_shm_listener shm_listener = { shm_format };

static void handle_buffer(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t fmt, uint32_t w, uint32_t h, uint32_t s) {
    (void)d; (void)f;
    /* Memory layout of ARGB8888/XRGB8888 is B,G,R,A; XBGR/ABGR is R,G,B,A. */
    swap_rb = (fmt == WL_SHM_FORMAT_XBGR8888 || fmt == WL_SHM_FORMAT_ABGR8888);
    width = (int)w;
    height = (int)h;
    stride = (int)s;
    int size = stride * height;
    char name[] = "/tmp/kairo-shot-XXXXXX";
    int fd = mkstemp(name);
    if (fd < 0) exit(1);
    unlink(name);
    if (ftruncate(fd, size) != 0) exit(1);
    data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) exit(1);
    memset(data, 0, size);
    pool = wl_shm_create_pool(shm, fd, size);
    buffer = wl_shm_pool_create_buffer(pool, 0, width, height, stride, fmt);
    wl_shm_pool_destroy(pool);
    close(fd);
    zwlr_screencopy_frame_v1_copy(f, buffer);
}

static void handle_flags(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t flags) { (void)d; (void)f; (void)flags; }
static void handle_ready(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t tv1, uint32_t tv2, uint32_t tv3) {
    (void)d; (void)f; (void)tv1; (void)tv2; (void)tv3;
    done = 1;
}
static void handle_failed(void *d, struct zwlr_screencopy_frame_v1 *f) { (void)d; (void)f; fprintf(stderr, "copy failed\n"); exit(1); }
static void handle_damage(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t x, uint32_t y, uint32_t w, uint32_t h) { (void)d; (void)f; (void)x; (void)y; (void)w; (void)h; }
static const struct zwlr_screencopy_frame_v1_listener frame_listener = {
    .buffer = handle_buffer,
    .flags = handle_flags,
    .ready = handle_ready,
    .failed = handle_failed,
    .damage = handle_damage,
};

static void global_add(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver) {
    (void)d; (void)ver;
    if (!strcmp(iface, "wl_shm")) shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, "wl_output")) { if (!out) out = wl_registry_bind(r, name, &wl_output_interface, 1); }
    else if (!strcmp(iface, "zwlr_screencopy_manager_v1")) scm = wl_registry_bind(r, name, &zwlr_screencopy_manager_v1_interface, 1);
}
static void global_remove(void *d, struct wl_registry *r, uint32_t name) { (void)d; (void)r; (void)name; }
static const struct wl_registry_listener reg_listener = { global_add, global_remove };

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "shot.ppm";
    struct wl_display *dp = wl_display_connect(NULL);
    if (!dp) { fprintf(stderr, "connect failed\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dp);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(dp);
    wl_display_roundtrip(dp);
    if (!shm || !scm || !out) { fprintf(stderr, "globals missing\n"); return 1; }

    struct zwlr_screencopy_frame_v1 *frame = zwlr_screencopy_manager_v1_capture_output(scm, 0, out);
    zwlr_screencopy_frame_v1_add_listener(frame, &frame_listener, NULL);
    while (!done && wl_display_dispatch(dp) >= 0) {}

    FILE *fp = fopen(path, "wb");
    if (!fp) return 1;
    fprintf(fp, "P6\n%d %d\n255\n", width, height);
    for (int i = 0; i < stride * height; i += 4) {
        if (swap_rb) {
            fputc(data[i], fp);
            fputc(data[i + 1], fp);
            fputc(data[i + 2], fp);
        } else {
            fputc(data[i + 2], fp);
            fputc(data[i + 1], fp);
            fputc(data[i], fp);
        }
    }
    fclose(fp);
    fprintf(stderr, "saved %s (%dx%d)\n", path, width, height);
    return 0;
}

#define _GNU_SOURCE
#include <wayland-client.h>
#include "ext-session-lock-v1-client-protocol.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <fcntl.h>

static struct wl_display *display;
static struct wl_registry *registry;
static struct ext_session_lock_manager_v1 *manager;
static struct wl_output *output;
static struct wl_shm *shm;
static struct wl_compositor *compositor;
static struct wl_seat *seat;
static struct wl_keyboard *keyboard;
static struct ext_session_lock_v1 *lock;
static struct ext_session_lock_surface_v1 *lock_surface;
static struct wl_surface *surface;
static struct wl_buffer *buffer;
static int locked = 0, configured = 0, focused = 0;

static void reg_global(void *data, struct wl_registry *r, uint32_t name, const char *iface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(iface, ext_session_lock_manager_v1_interface.name)) manager = wl_registry_bind(r, name, &ext_session_lock_manager_v1_interface, 1);
    else if (!strcmp(iface, wl_output_interface.name) && !output) output = wl_registry_bind(r, name, &wl_output_interface, 1);
    else if (!strcmp(iface, wl_shm_interface.name)) shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, wl_compositor_interface.name)) compositor = wl_registry_bind(r, name, &wl_compositor_interface, 4);
    else if (!strcmp(iface, wl_seat_interface.name)) seat = wl_registry_bind(r, name, &wl_seat_interface, 7);
}
static void reg_remove(void *data, struct wl_registry *r, uint32_t name) { (void)data; (void)r; (void)name; }
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

static void kb_keymap(void *data, struct wl_keyboard *kb, uint32_t format, int fd, uint32_t size) {
    (void)data; (void)kb; (void)format; (void)size;
    if (fd >= 0) close(fd);
}
static void kb_enter(void *data, struct wl_keyboard *kb, uint32_t serial, struct wl_surface *surface, struct wl_array *keys) {
    (void)data; (void)kb; (void)serial; (void)surface; (void)keys;
    focused = 1;
    fprintf(stderr, "locktest: focused\n");
}
static void kb_leave(void *data, struct wl_keyboard *kb, uint32_t serial, struct wl_surface *surface) {
    (void)data; (void)kb; (void)serial; (void)surface;
    focused = 0;
}
static void kb_key(void *data, struct wl_keyboard *kb, uint32_t serial, uint32_t time, uint32_t key, uint32_t state) {
    (void)data; (void)kb; (void)serial; (void)time; (void)key; (void)state;
}
static void kb_modifiers(void *data, struct wl_keyboard *kb, uint32_t serial, uint32_t depressed, uint32_t latched, uint32_t locked, uint32_t group) {
    (void)data; (void)kb; (void)serial; (void)depressed; (void)latched; (void)locked; (void)group;
}
static void kb_repeat(void *data, struct wl_keyboard *kb, int32_t rate, int32_t delay) {
    (void)data; (void)kb; (void)rate; (void)delay;
}
static const struct wl_keyboard_listener kb_listener = {
    kb_keymap, kb_enter, kb_leave, kb_key, kb_modifiers, kb_repeat,
};

static void seat_capabilities(void *data, struct wl_seat *s, uint32_t caps) {
    (void)data; (void)s;
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !keyboard) {
        keyboard = wl_seat_get_keyboard(seat);
        wl_keyboard_add_listener(keyboard, &kb_listener, NULL);
    }
}
static void seat_name(void *data, struct wl_seat *s, const char *name) { (void)data; (void)s; (void)name; }
static const struct wl_seat_listener seat_listener = { seat_capabilities, seat_name };

static void lock_locked(void *data, struct ext_session_lock_v1 *l) { (void)data; (void)l; locked = 1; fprintf(stderr, "locktest: locked\n"); }
static void lock_finished(void *data, struct ext_session_lock_v1 *l) { (void)data; (void)l; fprintf(stderr, "locktest: finished\n"); }
static const struct ext_session_lock_v1_listener lock_listener = { lock_locked, lock_finished };

static void surf_configure(void *data, struct ext_session_lock_surface_v1 *s, uint32_t serial, uint32_t w, uint32_t h) {
    (void)data;
    ext_session_lock_surface_v1_ack_configure(s, serial);
    int stride = w * 4, size = stride * h;
    int fd = memfd_create("kairo-lock", MFD_CLOEXEC);
    ftruncate(fd, size);
    uint32_t *pixels = mmap(NULL, size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
    for (int i = 0; i < (int)(w*h); i++) pixels[i] = 0xff101018;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    buffer = wl_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool); close(fd);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, w, h);
    wl_surface_commit(surface);
    configured = 1;
    fprintf(stderr, "locktest: configured %ux%u\n", w, h);
}
static const struct ext_session_lock_surface_v1_listener surf_listener = { surf_configure };

int main(int argc, char **argv) {
    int hold_seconds = 2;
    if (argc > 1) {
        hold_seconds = atoi(argv[1]);
        if (hold_seconds < 1) hold_seconds = 1;
        if (hold_seconds > 30) hold_seconds = 30;
    }
    display = wl_display_connect(NULL);
    if (!display) { perror("connect"); return 1; }
    registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &reg_listener, NULL);
    wl_display_roundtrip(display);
    if (seat) wl_seat_add_listener(seat, &seat_listener, NULL);
    wl_display_roundtrip(display);
    if (!manager || !output || !shm || !compositor || !seat) { fprintf(stderr, "missing globals manager=%p output=%p shm=%p compositor=%p seat=%p\n", (void*)manager, (void*)output, (void*)shm, (void*)compositor, (void*)seat); return 2; }
    lock = ext_session_lock_manager_v1_lock(manager);
    ext_session_lock_v1_add_listener(lock, &lock_listener, NULL);
    surface = wl_compositor_create_surface(compositor);
    lock_surface = ext_session_lock_v1_get_lock_surface(lock, surface, output);
    ext_session_lock_surface_v1_add_listener(lock_surface, &surf_listener, NULL);
    for (int i = 0; i < 200 && !(locked && configured && focused); i++) {
        if (wl_display_dispatch(display) < 0) break;
        usleep(10000);
    }
    if (!locked || !configured || !focused) { fprintf(stderr, "locktest: timeout locked=%d configured=%d focused=%d\n", locked, configured, focused); return 3; }
    fprintf(stderr, "locktest: waiting before unlock\n");
    sleep(hold_seconds);
    ext_session_lock_v1_unlock_and_destroy(lock);
    wl_display_roundtrip(display);
    if (keyboard) wl_keyboard_destroy(keyboard);
    if (buffer) wl_buffer_destroy(buffer);
    if (surface) wl_surface_destroy(surface);
    wl_display_disconnect(display);
    return 0;
}

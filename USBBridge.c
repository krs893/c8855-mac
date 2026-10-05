#include "USBBridge.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// libusb public ABI. Use runtime loading so the bundled LGPL library is replaceable.
typedef struct {
    uint8_t length, type; uint16_t usb;
    uint8_t class_, subclass, protocol, packet;
    uint16_t vid, pid, version;
    uint8_t manufacturer, product, serial, configs;
} DeviceDescriptor;
_Static_assert(sizeof(DeviceDescriptor) == 18, "libusb descriptor ABI");

struct C8855 {
    void *library, *context, *handle;
    int claimed, started;
    unsigned timeout;
    char error[256];
    int (*init)(void **);
    void (*exit)(void *);
    ssize_t (*get_device_list)(void *, void ***);
    void (*free_device_list)(void **, int);
    int (*get_device_descriptor)(void *, DeviceDescriptor *);
    int (*open)(void *, void **);
    void (*close)(void *);
    int (*claim_interface)(void *, int);
    int (*release_interface)(void *, int);
    int (*bulk_transfer)(void *, unsigned char, unsigned char *, int, int *, unsigned);
    const char *(*error_name)(int);
};

static int fail(C8855 *c, const char *message) {
    snprintf(c->error, sizeof(c->error), "%s", message);
    return -1;
}
static int check(C8855 *c, int result) {
    if (result < 0) {
        snprintf(c->error, sizeof(c->error), "USB: %s", c->error_name(result));
        return -1;
    }
    return 0;
}
static C8855 *load(const char *path, char *error, size_t capacity) {
    C8855 *c = calloc(1, sizeof(*c));
    if (!c) { snprintf(error, capacity, "メモリーを確保できません。"); return NULL; }
    c->library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!c->library) {
        snprintf(error, capacity, "USBライブラリを開けません: %s", dlerror());
        free(c); return NULL;
    }
#define LOAD(name) do { *(void **)(&c->name) = dlsym(c->library, "libusb_" #name); \
    if (!c->name) { snprintf(error, capacity, "libusbの関数がありません: " #name); \
    dlclose(c->library); free(c); return NULL; } } while (0)
    LOAD(init); LOAD(exit); LOAD(get_device_list); LOAD(free_device_list);
    LOAD(get_device_descriptor); LOAD(open); LOAD(close); LOAD(claim_interface);
    LOAD(release_interface); LOAD(bulk_transfer); LOAD(error_name);
#undef LOAD
    if (check(c, c->init(&c->context))) {
        snprintf(error, capacity, "%s", c->error);
        dlclose(c->library); free(c); return NULL;
    }
    return c;
}
static int enumerate(C8855 *c, int claim) {
    void **list = NULL, *chosen = NULL;
    ssize_t n = c->get_device_list(c->context, &list);
    if (n < 0) { check(c, (int)n); return -1; }
    int matches = 0, failed = 0;
    for (ssize_t i = 0; i < n; i++) {
        DeviceDescriptor d;
        if (check(c, c->get_device_descriptor(list[i], &d))) { failed = 1; break; }
        if (d.vid == 0x0661 && d.pid == 0x1300) { matches++; chosen = list[i]; }
    }
    if (!failed && claim) {
        if (matches != 1) { fail(c, "C8855-01を1台だけUSB接続してください。"); failed = 1; }
        else if (check(c, c->open(chosen, &c->handle))) failed = 1;
        else if (check(c, c->claim_interface(c->handle, 0))) failed = 1;
        else c->claimed = 1;
    }
    c->free_device_list(list, 1);
    return failed ? -1 : matches;
}
void c8855_close(C8855 *c) {
    if (!c) return;
    if (c->handle) {
        if (c->claimed) c->release_interface(c->handle, 0);
        c->close(c->handle);
    }
    if (c->context) c->exit(c->context);
    dlclose(c->library); free(c);
}
int c8855_probe(const char *library, char *error, size_t capacity) {
    C8855 *c = load(library, error, capacity);
    if (!c) return -1;
    int result = enumerate(c, 0);
    if (result < 0) snprintf(error, capacity, "%s", c->error);
    c8855_close(c); return result;
}
C8855 *c8855_open(const char *library, char *error, size_t capacity) {
    C8855 *c = load(library, error, capacity);
    if (!c) return NULL;
    if (enumerate(c, 1) < 0) {
        snprintf(error, capacity, "%s", c->error); c8855_close(c); return NULL;
    }
    return c;
}
static int write_command(C8855 *c, const uint8_t *data, int size) {
    int transferred = 0;
    if (check(c, c->bulk_transfer(c->handle, 0x02, (unsigned char *)data,
                                size, &transferred, 1000))) return -1;
    if (transferred != size) return fail(c, "USB命令が途中までしか送れませんでした。");
    usleep(5000); return 0;
}
static double monotonic(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static int drain(C8855 *c) {
    double deadline = monotonic() + 2;
    while (monotonic() < deadline) {
        uint8_t data[64]; int transferred = 0;
        int result = c->bulk_transfer(c->handle, 0x81, data, sizeof(data), &transferred, 50);
        if (result == -7 || (result == 0 && transferred == 0)) return 0;
        if (check(c, result)) return -1;
    }
    return fail(c, "停止後のデータが残っています。USBを再接続してください。");
}
int c8855_start(C8855 *c, uint8_t gate, unsigned timeout) {
    if (gate < 0x0c || gate > 0x0f) return fail(c, "対応していない計数時間です。");
    uint8_t stop[] = {4}, reset[] = {7};
    uint8_t setup[] = {1, gate, 1, 0, 4, 0, 0, 0};
    uint8_t start[] = {3, 0, 0, 0, 0, 0, 0, 0};
    c->timeout = timeout;
    if (write_command(c, stop, 1) || drain(c) || write_command(c, reset, 1)
        || write_command(c, setup, 8)) return -1;
    c->started = 1;
    return write_command(c, start, 8);
}
int c8855_read(C8855 *c, uint32_t *count) {
    uint8_t data[4]; int transferred = 0;
    if (check(c, c->bulk_transfer(c->handle, 0x81, data, 4, &transferred, c->timeout))) return -1;
    if (transferred != 4) return fail(c, "受信データ長が不一致です。測定を中止しました。");
    *count = (uint32_t)data[0] | ((uint32_t)data[1] << 8)
           | ((uint32_t)data[2] << 16) | ((uint32_t)data[3] << 24);
    if (*count == UINT32_MAX) return fail(c, "カウンターの転送エラーです。通常のカウントとして扱えません。");
    return 0;
}
int c8855_stop(C8855 *c) {
    if (!c->started) return 0;
    uint8_t command[] = {4};
    if (write_command(c, command, 1) || drain(c)) return -1;
    c->started = 0; return 0;
}
const char *c8855_error(C8855 *c) { return c->error; }

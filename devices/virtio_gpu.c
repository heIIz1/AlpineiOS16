// SPDX-License-Identifier: GPL-2.0-or-later
#include "virtio_gpu.h"

#include <stdlib.h>
#include <string.h>

enum { MAX_RESOURCES = 16, MAX_BACKING = 4096, MAX_WIDTH = 2048, MAX_HEIGHT = 2048 };
enum {
    GET_DISPLAY_INFO = 0x100, CREATE_2D, UNREF, SET_SCANOUT, FLUSH,
    TRANSFER_TO_HOST, ATTACH_BACKING, DETACH_BACKING,
    GET_EDID = 0x10a, OK_EDID = 0x1104,
    OK = 0x1100, OK_DISPLAY_INFO, ERR_UNSPEC = 0x1200, ERR_NOMEM,
    ERR_SCANOUT, ERR_RESOURCE, ERR_CONTEXT, ERR_PARAMETER
};

typedef struct Header {
    uint32_t type, flags;
    uint64_t fence;
    uint32_t context, padding;
} Header;

typedef struct Rect { uint32_t x, y, w, h; } Rect;
typedef struct Backing { uint64_t address; uint32_t length, padding; } Backing;
typedef struct Resource {
    uint32_t id, width, height, format;
    Backing *entries;
    uint32_t entry_count;
    uint8_t *pixels;
} Resource;

typedef struct Gpu {
    HvVirtio v;
    HvFbDisplay *fb;
    uint32_t width, height;
    uint8_t edid[128];
    Resource resources[MAX_RESOURCES];
    Resource *scanout;
    Rect scanout_rect;
    uint8_t *pixels;
} Gpu;

static void edid_timing(uint8_t *d, unsigned w, unsigned h, unsigned hz) {
    const unsigned hblank = 80, vblank = 30;
    unsigned clock = ((w + hblank) * (h + vblank) * hz + 5000) / 10000;
    d[0] = clock;
    d[1] = clock >> 8;
    d[2] = w;
    d[3] = hblank;
    d[4] = (w >> 8) << 4;
    d[5] = h;
    d[6] = vblank;
    d[7] = (h >> 8) << 4;
    d[8] = 16;
    d[9] = 32;
    d[10] = (3 << 4) | 5;
    d[17] = 0x1e; /* Digital, separate positive sync. */
}

static void build_edid(Gpu *g, unsigned preferred_hz) {
    uint8_t *edid = g->edid;
    const uint8_t header[] = {0,255,255,255,255,255,255,0, 0x06,0x10, 1,0};
    memcpy(edid, header, sizeof header);
    edid[16] = 1;
    edid[17] = 36; /* 2026 */
    edid[18] = 1;
    edid[19] = 4;
    edid[20] = 0x80; /* Digital input */
    edid[23] = 0xff; /* Unspecified gamma */
    edid[24] = 2; /* Preferred timing */
    memset(edid + 38, 1, 16); /* No standard timings */
    edid_timing(edid + 54, g->width, g->height, preferred_hz);
    edid_timing(edid + 72, g->width, g->height, 60);
    const uint8_t name[] = {0,0,0,0xfc,0,'A','l','p','i','n','e','i','O','S','\n',' ',' ',' '};
    memcpy(edid + 90, name, sizeof name);
    edid[111] = 0x10; /* Unused descriptor */
    for (unsigned i = 0; i < 127; i++) edid[127] -= edid[i];
}

static Resource *find_resource(Gpu *g, uint32_t id) {
    for (unsigned i = 0; i < MAX_RESOURCES; i++) {
        if (g->resources[i].id == id) return &g->resources[i];
    }
    return NULL;
}

static int contains(uint32_t width, uint32_t height, Rect r) {
    return r.w && r.h && r.x < width && r.y < height &&
           r.w <= width - r.x && r.h <= height - r.y;
}

static int transfer(Gpu *g, Resource *r, Rect rect, uint64_t offset) {
    if (!contains(r->width, r->height, rect) || !r->entries) return -1;
    const uint32_t stride = r->width * 4;
    unsigned index = 0;
    uint64_t base = 0;
    for (uint32_t row = 0; row < rect.h; row++) {
        uint64_t source = offset + (uint64_t)row * stride;
        uint8_t *dest = r->pixels + (size_t)(rect.y + row) * stride + rect.x * 4;
        uint32_t remaining = rect.w * 4;
        while (remaining) {
            while (index < r->entry_count && source - base >= r->entries[index].length)
                base += r->entries[index++].length;
            if (index == r->entry_count) return -1;
            Backing entry = r->entries[index];
            uint32_t off = (uint32_t)(source - base);
            uint32_t length = entry.length - off;
            if (length > remaining) length = remaining;
            const void *p = hv_phys_ptr(g->v.m, entry.address + off, length);
            if (!p) return -1;
            memcpy(dest, p, length);
            dest += length;
            source += length;
            remaining -= length;
        }
    }
    return 0;
}

static void paint(Gpu *g) {
    const Resource *r = g->scanout;
    const Rect a = g->scanout_rect;
    pthread_mutex_lock(&g->fb->mu);
    for (uint32_t y = 0; y < a.h; y++) {
        const uint8_t *src = r->pixels + ((size_t)(a.y + y) * r->width + a.x) * 4;
        uint8_t *dst = g->pixels + (size_t)y * a.w * 4;
        if (r->format == 1 || r->format == 2) {
            memcpy(dst, src, a.w * 4);
        } else {
            for (uint32_t x = 0; x < a.w; x++, src += 4, dst += 4) {
                dst[0] = src[2]; dst[1] = src[1]; dst[2] = src[0]; dst[3] = 255;
            }
        }
    }
    g->fb->fb_host = g->pixels;
    g->fb->width = a.w;
    g->fb->height = a.h;
    g->fb->stride = a.w * 4;
    g->fb->active = 1;
    if (++g->fb->frame_generation == 0) g->fb->frame_generation = 1;
    pthread_mutex_unlock(&g->fb->mu);
}

#define READ_REQUEST(name, ...) \
    struct { Header h; __VA_ARGS__; } name; \
    if (hv_virtq_read(&g->v, e, 0, &name, sizeof name) != sizeof name) return ERR_PARAMETER

static uint32_t execute(Gpu *g, const HvVirtqElem *e, Header *reply, uint32_t *bytes) {
    switch (reply->type) {
    case GET_DISPLAY_INFO: {
        struct { Rect rect; uint32_t enabled, flags; } modes[16] = {0};
        if (hv_virtq_writable(e) < sizeof *reply + sizeof modes)
            return ERR_PARAMETER;
        modes[0].rect = (Rect){0, 0, g->width, g->height};
        modes[0].enabled = 1;
        hv_virtq_write(&g->v, e, sizeof *reply, modes, sizeof modes);
        *bytes += sizeof modes;
        return OK_DISPLAY_INFO;
    }
    case GET_EDID: {
        READ_REQUEST(req, uint32_t scanout, padding);
        if (req.scanout || !g->edid[1]) return ERR_SCANOUT;
        struct { uint32_t len, padding; uint8_t data[1024]; } edid = {sizeof g->edid, 0, {0}};
        if (hv_virtq_writable(e) < sizeof *reply + sizeof edid) return ERR_PARAMETER;
        memcpy(edid.data, g->edid, sizeof g->edid);
        hv_virtq_write(&g->v, e, sizeof *reply, &edid, sizeof edid);
        *bytes += sizeof edid;
        return OK_EDID;
    }
    case CREATE_2D: {
        READ_REQUEST(req, uint32_t id, format, width, height);
        if (!req.id || find_resource(g, req.id)) return ERR_RESOURCE;
        if (!req.width || !req.height || req.width > MAX_WIDTH || req.height > MAX_HEIGHT ||
            (req.format != 1 && req.format != 2 && req.format != 67 && req.format != 134))
            return ERR_PARAMETER;
        Resource *r = find_resource(g, 0);
        if (!r) return ERR_NOMEM;
        r->pixels = calloc((size_t)req.width * req.height, 4);
        if (!r->pixels) return ERR_NOMEM;
        r->id = req.id; r->width = req.width; r->height = req.height; r->format = req.format;
        return OK;
    }
    case UNREF:
    case DETACH_BACKING: {
        READ_REQUEST(req, uint32_t id, padding);
        Resource *r = find_resource(g, req.id);
        if (!req.id || !r) return ERR_RESOURCE;
        free(r->entries);
        r->entries = NULL;
        r->entry_count = 0;
        if (reply->type == UNREF) {
            if (g->scanout == r) g->scanout = NULL;
            free(r->pixels);
            memset(r, 0, sizeof *r);
        }
        return OK;
    }
    case ATTACH_BACKING: {
        READ_REQUEST(req, uint32_t id, count);
        Resource *r = find_resource(g, req.id);
        if (!req.id || !r) return ERR_RESOURCE;
        if (r->entries || !req.count || req.count > MAX_BACKING) return ERR_PARAMETER;
        uint32_t size = req.count * sizeof(Backing);
        Backing *entries = malloc(size);
        if (!entries) return ERR_NOMEM;
        if (hv_virtq_read(&g->v, e, sizeof req, entries, size) != size) {
            free(entries);
            return ERR_PARAMETER;
        }
        for (unsigned i = 0; i < req.count; i++) {
            if (!entries[i].length || entries[i].address > UINT64_MAX - entries[i].length ||
                !hv_phys_ptr(g->v.m, entries[i].address, entries[i].length)) {
                free(entries);
                return ERR_PARAMETER;
            }
        }
        r->entries = entries;
        r->entry_count = req.count;
        return OK;
    }
    case SET_SCANOUT: {
        READ_REQUEST(req, Rect rect; uint32_t scanout, id);
        if (req.scanout != 0) return ERR_SCANOUT;
        if (!req.id) { g->scanout = NULL; return OK; }
        Resource *r = find_resource(g, req.id);
        if (!r) return ERR_RESOURCE;
        if (!contains(r->width, r->height, req.rect)) return ERR_PARAMETER;
        g->scanout = r;
        g->scanout_rect = req.rect;
        paint(g);
        return OK;
    }
    case TRANSFER_TO_HOST: {
        READ_REQUEST(req, Rect rect; uint64_t offset; uint32_t id, padding);
        Resource *r = find_resource(g, req.id);
        if (!req.id || !r) return ERR_RESOURCE;
        if (req.offset > (uint64_t)r->width * r->height * 4) return ERR_PARAMETER;
        return transfer(g, r, req.rect, req.offset) == 0 ? OK : ERR_PARAMETER;
    }
    case FLUSH: {
        READ_REQUEST(req, Rect rect; uint32_t id, padding);
        Resource *r = find_resource(g, req.id);
        if (!req.id || !r) return ERR_RESOURCE;
        if (!contains(r->width, r->height, req.rect)) return ERR_PARAMETER;
        if (r == g->scanout) paint(g);
        return OK;
    }
    case 0x300: /* cursor update */
    case 0x301: /* cursor move */
        return OK;
    default:
        return ERR_UNSPEC;
    }
}

static void notify(HvVirtio *v, int q) {
    Gpu *g = v->dev;
    HvVirtqElem e;
    int any = 0;
    while (hv_virtq_pop(v, q, &e) > 0) {
        Header h;
        uint32_t bytes = 0;
        if (hv_virtq_read(v, &e, 0, &h, sizeof h) == sizeof h) {
            if (q == 0 && hv_virtq_writable(&e) >= sizeof h) {
                bytes = sizeof h;
                h.type = execute(g, &e, &h, &bytes);
                h.flags &= 1;
                hv_virtq_write(v, &e, 0, &h, sizeof h);
            }
        }
        hv_virtq_push(v, q, &e, bytes);
        any = 1;
    }
    if (any) hv_virtio_interrupt(v);
}

int hv_virtio_gpu_create(HvMachine *m, HvPcie *bus, HvFbDisplay *fb,
                         uint32_t width, uint32_t height, unsigned display_hz) {
    Gpu *g = calloc(1, sizeof *g);
    if (!g) return -1;
    g->pixels = calloc((size_t)MAX_WIDTH * MAX_HEIGHT, 4);
    if (!g->pixels) { free(g); return -1; }
    g->width = width;
    g->height = height;
    const int advertise_edid = display_hz > 60 && display_hz <= 120;
    if (advertise_edid) build_edid(g, display_hz);
    hv_virtio_init(&g->v, m, 16, 0x038000, 2, advertise_edid ? 1u << 1 : 0);
    g->v.dev = g;
    g->v.notify = notify;
    g->v.config_len = 16;
    g->v.config[8] = 1; /* num_scanouts */
    g->fb = fb;
    hv_pcie_attach(bus, &g->v.pci);
    return 0;
}

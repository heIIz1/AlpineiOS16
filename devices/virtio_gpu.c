// SPDX-License-Identifier: GPL-2.0-or-later
#include "virtio_gpu.h"
#include "virgl.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>

enum { MAX_RESOURCES = 512, MAX_BACKING = 4096, MAX_WIDTH = 2048, MAX_HEIGHT = 2048 };
enum {
    GET_DISPLAY_INFO = 0x100, CREATE_2D, UNREF, SET_SCANOUT, FLUSH,
    TRANSFER_TO_HOST, ATTACH_BACKING, DETACH_BACKING,
    GET_CAPSET_INFO = 0x108, GET_CAPSET = 0x109,
    GET_EDID = 0x10a, OK_EDID = 0x1104,
    OK_CAPSET_INFO = 0x1102, OK_CAPSET = 0x1103,
    CTX_CREATE = 0x200, CTX_DESTROY, CTX_ATTACH, CTX_DETACH,
    CREATE_3D, TRANSFER_3D_WRITE, TRANSFER_3D_READ, SUBMIT_3D,
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
    struct iovec *iov;
    int renderer_owned;
} Resource;

typedef struct Gpu {
    HvVirtio v;
    HvFbDisplay *fb;
    uint32_t width, height;
    uint8_t edid[128];
    HvVirgl *renderer;
    Resource resources[MAX_RESOURCES];
    Resource *scanout;
    Rect scanout_rect;
    uint8_t *pixels;
} Gpu;

/* Resize requests come from UIKit; the guest CPU applies them at its next poll. */
static Gpu *active_gpu;
static _Atomic uint32_t requested_size;
static unsigned active_refresh_hz;
static uint32_t advertised_modes[3][2];

void hv_virtio_gpu_request_size(uint32_t width, uint32_t height) {
    if (width >= 320 && height >= 320 && width <= MAX_WIDTH && height <= MAX_HEIGHT)
        atomic_store(&requested_size, (width << 16) | height);
}

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
    memset(edid, 0, sizeof g->edid);
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
    unsigned descriptor = 1;
    for (unsigned i = 0; i < 3; i++) {
        unsigned w = advertised_modes[i][0], h = advertised_modes[i][1];
        if (!w || !h || (w == g->width && h == g->height)) continue;
        edid_timing(edid + 54 + descriptor++ * 18, w, h, i == 0 ? 60 : preferred_hz);
    }
    if (descriptor < 4 && preferred_hz != 60) {
        edid_timing(edid + 54 + descriptor++ * 18, g->width, g->height, 60);
    }
    while (descriptor < 4) edid[54 + descriptor++ * 18 + 3] = 0x10;
    for (unsigned i = 0; i < 127; i++) edid[127] -= edid[i];
}

static void gpu_config_write(HvVirtio *v, uint32_t off, uint64_t value, unsigned size) {
    if (off == 4 && size == 4) v->config[0] &= ~(uint8_t)value;
}

void hv_virtio_gpu_poll(void) {
    Gpu *g = active_gpu;
    if (!g || !(g->v.status & 4)) return;
    uint32_t size = atomic_exchange(&requested_size, 0);
    if (!size || (g->width == (size >> 16) && g->height == (size & 0xffff))) return;
    g->width = size >> 16;
    g->height = size & 0xffff;
    build_edid(g, active_refresh_hz);
    g->v.config[0] |= 1; /* VIRTIO_GPU_EVENT_DISPLAY */
    g->v.config_gen++;
    g->v.isr |= 2;       /* PCI configuration interrupt */
    hv_pci_set_intx(&g->v.pci, 1);
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
    Resource *r = g->scanout;
    const Rect a = g->scanout_rect;
    if (r->renderer_owned) {
        HvVirglInfo info = {0};
        if (!g->renderer->info(r->id, &info) && info.native_type == 2 && info.native_handle) {
            pthread_mutex_lock(&g->fb->mu);
            g->fb->fb_host = g->pixels; // Valid fallback storage for the scanout geometry.
            pthread_mutex_unlock(&g->fb->mu);
            // ANGLE must finish writing before another Metal queue copies the texture.
            g->renderer->finish();
            if (hv_fb_metal_publish_texture(g->fb, info.native_handle, a.x, a.y, a.w, a.h)) return;
        }
        if (!r->pixels) r->pixels = calloc((size_t)r->width * r->height, 4);
        if (!r->pixels) return;
        struct iovec target = {r->pixels, (size_t)r->width * r->height * 4};
        HvVirglBox box = {0, 0, 0, r->width, r->height, 1};
        g->renderer->force_context();
        if (g->renderer->read(r->id, 0, 0, r->width * 4, 0, &box, 0, &target, 1)) return;
    }
    hv_fb_metal_use_pixels(g->fb);
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
    case GET_CAPSET_INFO: {
        READ_REQUEST(req, uint32_t index, padding);
        if (!g->renderer || req.index >= 2) return ERR_PARAMETER;
        struct { uint32_t id, version, size, padding; } info = {req.index + 1, 0, 0, 0};
        g->renderer->capset(info.id, &info.version, &info.size);
        if (!info.size || hv_virtq_writable(e) < sizeof *reply + sizeof info) return ERR_PARAMETER;
        hv_virtq_write(&g->v, e, sizeof *reply, &info, sizeof info);
        *bytes += sizeof info;
        return OK_CAPSET_INFO;
    }
    case GET_CAPSET: {
        READ_REQUEST(req, uint32_t id, version);
        if (!g->renderer || req.id < 1 || req.id > 2) return ERR_PARAMETER;
        uint32_t version = 0, size = 0;
        g->renderer->capset(req.id, &version, &size);
        if (!size || size > 1048576 || req.version > version ||
            hv_virtq_writable(e) < sizeof *reply + size) return ERR_PARAMETER;
        void *caps = calloc(1, size);
        if (!caps) return ERR_NOMEM;
        g->renderer->caps(req.id, req.version, caps);
        hv_virtq_write(&g->v, e, sizeof *reply, caps, size);
        free(caps);
        *bytes += size;
        return OK_CAPSET;
    }
    case CTX_CREATE: {
        READ_REQUEST(req, uint32_t length, flags; char name[64]);
        if (!g->renderer || !reply->context || req.flags || req.length > sizeof req.name) return ERR_PARAMETER;
        return g->renderer->context_create(reply->context, req.length, req.name) ? ERR_UNSPEC : OK;
    }
    case CTX_DESTROY:
        if (!g->renderer || !reply->context) return ERR_CONTEXT;
        g->renderer->context_destroy(reply->context);
        return OK;
    case CTX_ATTACH:
    case CTX_DETACH: {
        READ_REQUEST(req, uint32_t id, padding);
        if (!g->renderer || !reply->context || !find_resource(g, req.id)) return ERR_RESOURCE;
        if (reply->type == CTX_ATTACH) g->renderer->ctx_attach(reply->context, req.id);
        else g->renderer->ctx_detach(reply->context, req.id);
        return OK;
    }
    case CREATE_3D: {
        READ_REQUEST(req, HvVirglResource args; uint32_t padding);
        if (!g->renderer || !req.args.handle || find_resource(g, req.args.handle) ||
            !req.args.width || !req.args.height || req.args.height > 8192 ||
            req.args.width > (req.args.target == 0 ? (256u << 20) : 8192u) ||
            req.args.last_level > 15 || req.args.array_size > 2048 || req.args.depth > 2048)
            return ERR_PARAMETER;
        Resource *r = find_resource(g, 0);
        if (!r) return ERR_NOMEM;
        if (g->renderer->resource_create(&req.args, NULL, 0)) return ERR_UNSPEC;
        r->id = req.args.handle;
        r->width = req.args.width;
        r->height = req.args.height;
        r->format = req.args.format;
        r->renderer_owned = 1;
        return OK;
    }
    case TRANSFER_3D_WRITE:
    case TRANSFER_3D_READ: {
        READ_REQUEST(req, HvVirglBox box; uint64_t offset; uint32_t id, level, stride, layer_stride);
        Resource *r = find_resource(g, req.id);
        if (!g->renderer || !r || !r->renderer_owned || !r->iov) return ERR_RESOURCE;
        int result;
        if (reply->type == TRANSFER_3D_READ)
            result = g->renderer->read(req.id, reply->context, req.level, req.stride, req.layer_stride,
                                      &req.box, req.offset, NULL, 0);
        else
            result = g->renderer->write(req.id, reply->context, req.level, req.stride, req.layer_stride,
                                       &req.box, req.offset, NULL, 0);
        return result ? ERR_PARAMETER : OK;
    }
    case SUBMIT_3D: {
        READ_REQUEST(req, uint32_t size, padding);
        if (!g->renderer || !reply->context || !req.size || req.size % 4 || req.size > (16u << 20))
            return ERR_PARAMETER;
        void *commands = malloc(req.size);
        if (!commands) return ERR_NOMEM;
        int result = -1;
        if (hv_virtq_read(&g->v, e, sizeof req, commands, req.size) == req.size)
            result = g->renderer->submit(commands, reply->context, req.size / 4);
        free(commands);
        return result ? ERR_UNSPEC : OK;
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
        // Pixman writes into guest memory. Keep legacy 2D buffers in that path
        // even when 3D resources and contexts are available on the same device.
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
        if (r->renderer_owned) {
            if (reply->type == UNREF) g->renderer->resource_unref(r->id);
            else g->renderer->detach(r->id, NULL, NULL);
        }
        free(r->iov);
        r->iov = NULL;
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
        if (r->renderer_owned) {
            r->iov = calloc(req.count, sizeof(struct iovec));
            if (!r->iov) { free(entries); return ERR_NOMEM; }
            for (unsigned i = 0; i < req.count; i++) {
                r->iov[i].iov_base = hv_phys_ptr(g->v.m, entries[i].address, entries[i].length);
                r->iov[i].iov_len = entries[i].length;
            }
            if (g->renderer->attach(r->id, r->iov, req.count)) {
                free(r->iov);
                r->iov = NULL;
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
        if (!contains(r->width, r->height, req.rect) ||
            req.rect.w > MAX_WIDTH || req.rect.h > MAX_HEIGHT) return ERR_PARAMETER;
        // A new scanout can already contain the finished frame: Linux may
        // upload and flush a buffer before selecting it for display.
        int changed = g->scanout != r ||
                      memcmp(&g->scanout_rect, &req.rect, sizeof req.rect) != 0;
        g->scanout = r;
        g->scanout_rect = req.rect;
        if (changed) paint(g);
        return OK;
    }
    case TRANSFER_TO_HOST: {
        READ_REQUEST(req, Rect rect; uint64_t offset; uint32_t id, padding);
        Resource *r = find_resource(g, req.id);
        if (!req.id || !r) return ERR_RESOURCE;
        if (req.offset > (uint64_t)r->width * r->height * 4) return ERR_PARAMETER;
        if (r->renderer_owned) {
            HvVirglBox box = {req.rect.x, req.rect.y, 0, req.rect.w, req.rect.h, 1};
            return g->renderer->write(r->id, 0, 0, r->width * 4, 0, &box, req.offset, NULL, 0)
                ? ERR_PARAMETER : OK;
        }
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
    if (g->renderer) hv_virgl_enter();
    while (hv_virtq_pop(v, q, &e) > 0) {
        Header h;
        uint32_t bytes = 0;
        if (hv_virtq_read(v, &e, 0, &h, sizeof h) == sizeof h) {
            if (q == 0 && hv_virtq_writable(&e) >= sizeof h) {
                bytes = sizeof h;
                h.type = execute(g, &e, &h, &bytes);
                // Only fenced responses promise GPU completion. Unfenced commands
                // can stay queued, avoiding a GPU/CPU stall after every command.
                if (g->renderer && (h.flags & 1)) g->renderer->finish();
                h.flags &= 1;
                hv_virtq_write(v, &e, 0, &h, sizeof h);
            }
        }
        hv_virtq_push(v, q, &e, bytes);
        any = 1;
    }
    if (g->renderer) hv_virgl_release_current();
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
    memset(advertised_modes, 0, sizeof advertised_modes);
    const char *modes = getenv("HV_VIRTIO_ALTERNATE_MODES");
    if (modes) {
        unsigned w[3], h[3];
        if (sscanf(modes, "%ux%u %ux%u %ux%u", &w[0], &h[0], &w[1], &h[1], &w[2], &h[2]) == 6) {
            for (unsigned i = 0; i < 3; i++) {
                if (w[i] >= 320 && h[i] >= 320 && w[i] <= MAX_WIDTH && h[i] <= MAX_HEIGHT) {
                    advertised_modes[i][0] = w[i];
                    advertised_modes[i][1] = h[i];
                }
            }
        }
    }
    active_refresh_hz = display_hz > 60 && display_hz <= 120 ? display_hz : 60;
    build_edid(g, active_refresh_hz);
    g->renderer = hv_virgl_init();
    uint64_t features = 1u << 1;
    if (g->renderer) features |= 1;
    hv_virtio_init(&g->v, m, 16, 0x038000, 2, features);
    g->v.dev = g;
    g->v.notify = notify;
    g->v.config_write = gpu_config_write;
    g->v.config_len = 16;
    if (g->renderer) g->v.config[12] = 2; /* VIRGL and VIRGL2 capsets */
    g->v.config[8] = 1; /* num_scanouts */
    g->fb = fb;
    atomic_store(&requested_size, 0);
    active_gpu = g;
    hv_pcie_attach(bus, &g->v.pci);
    return 0;
}

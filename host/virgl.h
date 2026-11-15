/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HV_VIRGL_H
#define HV_VIRGL_H
#include <stdint.h>
#include <sys/uio.h>

typedef struct HvVirglResource {
    uint32_t handle, target, format, bind, width, height, depth;
    uint32_t array_size, last_level, samples, flags;
} HvVirglResource;
typedef struct HvVirglBox { uint32_t x, y, z, w, h, d; } HvVirglBox;
typedef struct HvVirglInfo {
    int version;
    struct { uint32_t handle, format, width, height, depth, flags, texture, stride; int fourcc, fd; } base;
    _Bool dmabuf;
    int planes;
    uint64_t modifiers;
    void *native_handle;
    int native_type;
} HvVirglInfo;

typedef struct HvVirgl {
    int (*resource_create)(HvVirglResource *, struct iovec *, uint32_t);
    void (*resource_unref)(uint32_t);
    int (*context_create)(uint32_t, uint32_t, const char *);
    void (*context_destroy)(uint32_t);
    int (*submit)(void *, int, int);
    int (*read)(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, HvVirglBox *, uint64_t, struct iovec *, int);
    int (*write)(uint32_t, uint32_t, int, uint32_t, uint32_t, HvVirglBox *, uint64_t, struct iovec *, unsigned);
    void (*capset)(uint32_t, uint32_t *, uint32_t *);
    void (*caps)(uint32_t, uint32_t, void *);
    int (*attach)(int, struct iovec *, int);
    void (*detach)(int, struct iovec **, int *);
    void (*ctx_attach)(int, int);
    void (*ctx_detach)(int, int);
    void (*finish)(void);
    void (*force_context)(void);
    void (*reset)(void);
    int (*info)(int, HvVirglInfo *);
} HvVirgl;

/* All renderer calls run on the VM CPU thread. */
HvVirgl *hv_virgl_init(void);
void hv_virgl_release_current(void);
void hv_virgl_enter(void);
const char *hv_virgl_status(void);
#endif

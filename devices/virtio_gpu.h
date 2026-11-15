// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef HV_VIRTIO_GPU_H
#define HV_VIRTIO_GPU_H
#include "fb_display.h"
#include "virtio.h"

int hv_virtio_gpu_create(HvMachine *m, HvPcie *bus, HvFbDisplay *fb,
                         uint32_t width, uint32_t height);
#endif

/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * JIT allocator for iOS 16..27 (including iOS 26/27 TXM): a plain RWX mapping
 * where the kernel allows it (jailbreak, CS_DEBUGGED), a writable/executable
 * alias pair otherwise, and the debugger-brokered region on TXM.
 * Adapted from Henge (Leviidev/Henge, GPL-2.0-or-later).
 */
#ifndef WINIOS_JIT_H
#define WINIOS_JIT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WinIosDualMapping {
    uint8_t *rw_addr;
    uint8_t *rx_addr;
    size_t   size;
} WinIosDualMapping;

#define WINIOS_JIT_DEFAULT_BYTES ((size_t)128u << 20) /* 128 MiB for the Alpine profile */

void winios_jit_install_trap_handler(void);
bool winios_jit_is_debugger_attached(void);
bool winios_jit_acquire(size_t bytes, bool detach_after);
bool winios_jit_is_live(void);
WinIosDualMapping winios_jit_mapping(void);
void *winios_jit_guest_ram(uint64_t *out_bytes);
uint64_t winios_guest_ram_target_mb(void);
const char *winios_jit_status_text(void);
size_t winios_available_memory_bytes(void);

#ifdef __cplusplus
}
#endif

#endif

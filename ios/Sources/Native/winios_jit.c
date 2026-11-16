/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Dual-mapped RX/RW JIT allocator for iOS 16.1+ (including iOS 26/27 TXM).
 * Adapted from Henge (Leviidev/Henge, GPL-2.0-or-later).
 */
#include "winios_jit.h"
#include "winvirt.h"

#include <TargetConditionals.h>
#include <errno.h>
#include <fcntl.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/task.h>
#include <mach/task_info.h>
#include <mach/vm_map.h>
#include <os/log.h>
#include <os/proc.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/sysctl.h>
#include <sys/ucontext.h>
#include <unistd.h>

#ifndef MAP_JIT
#define MAP_JIT 0x0800
#endif

/* Provide pipe2 if referenced by static glib/slirp on older iOS runtimes. */
__attribute__((weak, visibility("default")))
int pipe2(int fds[2], int flags) {
    if (!fds) {
        errno = EFAULT;
        return -1;
    }
    if (pipe(fds) < 0) return -1;
    if ((flags & O_CLOEXEC) &&
        (fcntl(fds[0], F_SETFD, FD_CLOEXEC) < 0 || fcntl(fds[1], F_SETFD, FD_CLOEXEC) < 0)) {
        int e = errno;
        close(fds[0]);
        close(fds[1]);
        errno = e;
        return -1;
    }
    if (flags & O_NONBLOCK) {
        int f0 = fcntl(fds[0], F_GETFL), f1 = fcntl(fds[1], F_GETFL);
        if (f0 < 0 || f1 < 0 ||
            fcntl(fds[0], F_SETFL, f0 | O_NONBLOCK) < 0 ||
            fcntl(fds[1], F_SETFL, f1 | O_NONBLOCK) < 0) {
            int e = errno;
            close(fds[0]);
            close(fds[1]);
            errno = e;
            return -1;
        }
    }
    return 0;
}

extern void    *winios_brk_get_jit_mapping(void *addr, size_t len);
extern void     winios_brk_jit_detach(void);
extern uint64_t winios_brk_probe(void);

#define WINIOS_LOG(fmt, ...)                                              \
    do {                                                                  \
        os_log(OS_LOG_DEFAULT, "[winios-jit] " fmt, ##__VA_ARGS__);       \
        fprintf(stderr, "[winios-jit] " fmt "\n", ##__VA_ARGS__);         \
        fflush(stderr);                                                   \
    } while (0)

/* Executable JIT pages above 0x7000000000 hang on iOS 26/27 TXM devices.
 * Reserve a 128 MiB block at runtime so it can sit inside the low < 0x180000000
 * window, then deallocate it immediately before debugserver's `_M<size>,rx`
 * allocation takes the first-fit hole. Avoid a large static reserve in __DATA,
 * which is problematic on iOS 16 and increases launch/memory pressure. */
#define WINIOS_JIT_LOW_LIMIT 0x7000000000ull
static uint8_t *g_jit_reserve;
static size_t g_jit_reserve_bytes;
static bool g_jit_reserve_released;

static _Thread_local bool g_expecting_jit_trap;
static struct sigaction g_prev_sigtrap;
static struct sigaction g_prev_sigbus;

static WinIosDualMapping g_mapping;
static void *g_guest_ram;
static uint64_t g_guest_ram_bytes;
static atomic_bool g_jit_live;
static char g_status[256] = "Not initialized";

uint64_t winios_guest_ram_target_mb(void) {
    uint64_t physical = 0;
    size_t length = sizeof physical;
    if (sysctlbyname("hw.memsize", &physical, &length, NULL, 0) != 0) return 1536;
    // Devices sold with 6 GB or more may expose slightly less usable physical RAM.
    return physical >= (5ull << 30) ? 2048 : 1536;
}

static void prealloc_ledger_exempt_ram(void) {
    if (g_guest_ram) return;
    uint64_t phys_mem = 0;
    size_t len = sizeof phys_mem;
    sysctlbyname("hw.memsize", &phys_mem, &len, NULL, 0);
    uint64_t phys_mb = phys_mem >> 20;
    /* Size Guest RAM to fit comfortably within iOS 36-bit user VA ceiling alongside TXM JIT RX/RW + JIT tables */
    static const uint64_t candidates_mb[] = {2048, 1536};
    uint64_t target_mb = winios_guest_ram_target_mb();
    for (size_t i = 0; i < sizeof(candidates_mb) / sizeof(candidates_mb[0]); i++) {
        uint64_t mb = candidates_mb[i];
        if (mb > target_mb) continue;
        if (phys_mb > 0 && mb + 2560 > phys_mb) continue;
        uint8_t *p = hv_alloc_no_footprint(mb << 20);
        if (p) {
            g_guest_ram = p;
            g_guest_ram_bytes = mb << 20;
            WINIOS_LOG("pre-allocated %llu MiB ledger-exempt Guest RAM at %p",
                       (unsigned long long)mb, (void *)p);
            return;
        }
    }
    WINIOS_LOG("ledger-exempt Guest RAM pre-allocation unavailable; will fall back at VM start");
}

static void set_status(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void set_status(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_status, sizeof g_status, fmt, ap);
    va_end(ap);
}

static void winios_trap_handler(int sig, siginfo_t *info, void *ctx) {
    (void)info;
    if (g_expecting_jit_trap && ctx != NULL) {
        ucontext_t *uc = (ucontext_t *)ctx;
        uc->uc_mcontext->__ss.__pc += 4;
        uc->uc_mcontext->__ss.__x[0] = 0;
        return;
    }
    struct sigaction *prev = (sig == SIGTRAP) ? &g_prev_sigtrap : &g_prev_sigbus;
    sigaction(sig, prev, NULL);
    raise(sig);
}

void winios_jit_install_trap_handler(void) {
    if (!g_jit_reserve && !g_jit_reserve_released) {
        g_jit_reserve_bytes = WINIOS_JIT_DEFAULT_BYTES;
        void *p = mmap(NULL, g_jit_reserve_bytes, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p != MAP_FAILED) {
            g_jit_reserve = (uint8_t *)p;
            WINIOS_LOG("reserved low JIT hold at %p (%zu MiB)", p, g_jit_reserve_bytes >> 20);
        } else {
            WINIOS_LOG("could not reserve low JIT hold: %s", strerror(errno));
            g_jit_reserve_bytes = 0;
        }
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sa.sa_sigaction = winios_trap_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTRAP, &sa, &g_prev_sigtrap);
    sigaction(SIGBUS, &sa, &g_prev_sigbus);
    set_status("Trap guard ready");
    WINIOS_LOG("trap guard installed");
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
bool winios_jit_is_debugger_attached(void) {
    uint32_t flags = 0;
    return syscall(169 /* SYS_csops */, getpid(), 0 /* CS_OPS_STATUS */, &flags, sizeof flags) == 0 &&
           (flags & 0x10000000u) != 0; /* CS_DEBUGGED */
}
#pragma clang diagnostic pop

size_t winios_available_memory_bytes(void) {
#if TARGET_OS_IPHONE
    return os_proc_available_memory();
#else
    return 4ull << 30;
#endif
}

static void release_low_hold(size_t bytes) {
    if (g_jit_reserve_released) return;
    if (!g_jit_reserve || g_jit_reserve_bytes == 0) {
        g_jit_reserve_released = true;
        return;
    }
    if (bytes > g_jit_reserve_bytes) bytes = g_jit_reserve_bytes;
    kern_return_t kr = vm_deallocate(mach_task_self(), (vm_address_t)g_jit_reserve, g_jit_reserve_bytes);
    WINIOS_LOG("released low JIT hold at %p (%zu MiB): %s",
               (void *)g_jit_reserve, g_jit_reserve_bytes >> 20, mach_error_string(kr));
    g_jit_reserve = NULL;
    g_jit_reserve_bytes = 0;
    g_jit_reserve_released = true;
}

static sigjmp_buf g_selftest_jmp;
static volatile sig_atomic_t g_selftest_probing;

static void selftest_fault(int sig, siginfo_t *info, void *ctx) {
    (void)info;
    (void)ctx;
    if (g_selftest_probing) siglongjmp(g_selftest_jmp, 1);
    _exit(128 + sig);
}

static bool jit_selftest(const WinIosDualMapping *m) {
    /* movz w0, #42 ; ret */
    static const uint32_t kCode[2] = {0x52800540u, 0xD65F03C0u};
    if (!m->rw_addr || !m->rx_addr || m->size < 16384) return false;

    /* A mapping that does not work must fail here, not kill the app: catch the
       faults this probe causes (a JIT page that rejects writes, an alias that
       will not execute) and report the probe as failed instead. */
    struct sigaction probe, old[3];
    memset(&probe, 0, sizeof probe);
    probe.sa_flags = SA_SIGINFO | SA_NODEFER;
    probe.sa_sigaction = selftest_fault;
    int sigs[3] = {SIGBUS, SIGILL, SIGSEGV};
    for (int i = 0; i < 3; i++) sigaction(sigs[i], &probe, &old[i]);
    if (sigsetjmp(g_selftest_jmp, 1) != 0) {
        g_selftest_probing = 0;
        for (int i = 0; i < 3; i++) sigaction(sigs[i], &old[i], NULL);
        WINIOS_LOG("selftest FAIL: faulted on JIT memory (write or execute rejected)");
        return false;
    }
    g_selftest_probing = 1;

    bool ok = true;
    const size_t offsets[2] = {0, m->size - 16384};
    for (int i = 0; i < 2; i++) {
        size_t off = offsets[i];
        memcpy(m->rw_addr + off, kCode, sizeof kCode);
        sys_icache_invalidate(m->rx_addr + off, sizeof kCode);

        uint32_t rb[2] = {0, 0};
        memcpy(rb, m->rx_addr + off, sizeof rb);
        if (rb[0] != kCode[0] || rb[1] != kCode[1]) {
            WINIOS_LOG("selftest FAIL at +%#zx: alias mismatch (%08x %08x)", off, rb[0], rb[1]);
            ok = false;
            break;
        }
        int (*fn)(void) = (int (*)(void))(void *)(m->rx_addr + off);
        int rc = fn();
        if (rc != 42) {
            WINIOS_LOG("selftest FAIL at +%#zx: expected 42, got %d", off, rc);
            ok = false;
            break;
        }
    }
    g_selftest_probing = 0;
    for (int i = 0; i < 3; i++) sigaction(sigs[i], &old[i], NULL);
    if (ok)
        WINIOS_LOG("selftest PASS: executed RX code at %p and +%#zx -> 42",
                   (void *)m->rx_addr, m->size - 16384);
    return ok;
}

/* A plain RWX mapping rw == rx: no aliasing, no JIT write protection. The
   jailbroken kernel (Dopamine) and any process with CS_DEBUGGED (set by
   TrollStore's enable-JIT, StikDebug, or a debugger) allows it on iOS < 26. */
static bool try_plain_rwx(size_t bytes) {
    void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) {
        WINIOS_LOG("plain RWX mmap failed: %s", strerror(errno));
        return false;
    }
    WinIosDualMapping m = {(uint8_t *)p, (uint8_t *)p, bytes};
    if (!jit_selftest(&m)) {
        munmap(p, bytes);
        return false;
    }
    g_mapping = m;
    release_low_hold(bytes);
    prealloc_ledger_exempt_ram();
    atomic_store(&g_jit_live, true);
    set_status("Live (%zu MiB RWX)", bytes >> 20);
    return true;
}

/* A writable mapping and a separate executable alias of the same pages, the
   shape a debugger grants on TXM and that CS_DEBUGGED permits on iOS < 26. */
static bool try_dual_mapping(size_t bytes) {
    uint8_t *rx = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (rx == MAP_FAILED)
        rx = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (rx == MAP_FAILED) {
        WINIOS_LOG("dual mapping mmap failed: %s", strerror(errno));
        return false;
    }
#if TARGET_OS_OSX
    pthread_jit_write_protect_np(0);
#endif
    vm_address_t rw = 0;
    vm_prot_t cur, max;
    kern_return_t remap_kr = vm_remap(mach_task_self(), &rw, bytes, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                                      (vm_address_t)rx, FALSE, &cur, &max, VM_INHERIT_NONE);
    kern_return_t rxprot_kr = (remap_kr == KERN_SUCCESS) ?
        vm_protect(mach_task_self(), (vm_address_t)rx, bytes, FALSE, VM_PROT_READ | VM_PROT_EXECUTE) : remap_kr;
    kern_return_t rwprot_kr = (rxprot_kr == KERN_SUCCESS) ?
        vm_protect(mach_task_self(), rw, bytes, FALSE, VM_PROT_READ | VM_PROT_WRITE) : rxprot_kr;
    if (remap_kr == KERN_SUCCESS && rxprot_kr == KERN_SUCCESS && rwprot_kr == KERN_SUCCESS) {
        WinIosDualMapping m = {(uint8_t *)rw, rx, bytes};
        if (jit_selftest(&m)) {
            g_mapping = m;
            release_low_hold(bytes);
            prealloc_ledger_exempt_ram();
            atomic_store(&g_jit_live, true);
#if TARGET_OS_OSX
            pthread_jit_write_protect_np(1);
#endif
            set_status("Live (%zu MiB RX/RW)", bytes >> 20);
            return true;
        }
    }
#if TARGET_OS_OSX
    pthread_jit_write_protect_np(1);
#endif
    if (remap_kr == KERN_SUCCESS) vm_deallocate(mach_task_self(), rw, bytes);
    munmap(rx, bytes);
    WINIOS_LOG("dual mapping rejected (remap=%s rx=%s rw=%s)", mach_error_string(remap_kr),
               mach_error_string(rxprot_kr), mach_error_string(rwprot_kr));
    return false;
}

/* TrollStore's enable-JIT attaches and detaches (ptrace PT_ATTACHEXC +
   PT_DETACH), which sets CS_DEBUGGED without leaving a debugger behind, and
   StikDebug/LLDB answer the brk protocol and hand out an RX region. The plain
   mappings above come first because they need nothing running outside this
   process; this is the TXM (iOS 26+) path and the last resort elsewhere. */
bool winios_jit_acquire(size_t bytes, bool detach_after) {
    if (atomic_load(&g_jit_live)) return true;
    if (bytes == 0) bytes = WINIOS_JIT_DEFAULT_BYTES;
    bytes = (bytes + 0x3fffu) & ~(size_t)0x3fffu;

    /* TXM (iOS 26+) rejects both of these, but they are the cheap path
       everywhere else and the one that works with only CS_DEBUGGED. */
    if (__builtin_available(iOS 26.0, *)) {
        /* the debugger-brokered region below is the only way there */
    } else {
        if (try_plain_rwx(bytes)) return true;
        if (try_dual_mapping(bytes)) return true;
    }

    if (!winios_jit_is_debugger_attached()) {
        set_status("JIT off: tap the button to enable it via TrollStore");
        WINIOS_LOG("acquire: CS_DEBUGGED not set and no RWX mapping; TrollStore enable-JIT needed");
        return false;
    }

    g_expecting_jit_trap = true;
    uint64_t probe = winios_brk_probe();
    g_expecting_jit_trap = false;

    if (probe == 0) {
        /* CS_DEBUGGED (TrollStore) but nobody answers the breakpoints. On iOS
           < 26 the mappings above should have worked, so this is iOS 26+:
           debugger-brokered RX is required there. */
        if (__builtin_available(iOS 26.0, *))
            set_status("JIT off: use StikDebug (TrollStore cannot enable JIT on iOS 26+)");
        else
            set_status("JIT off: enable it via TrollStore or StikDebug");
        WINIOS_LOG("probe returned 0 (debugger did not answer brk #0x69)");
        return false;
    }

    WINIOS_LOG("probe answered: 0x%llx", (unsigned long long)probe);
    release_low_hold(bytes);

    void *rx = NULL;
    for (int attempt = 1; attempt <= 3; attempt++) {
        g_expecting_jit_trap = true;
        rx = winios_brk_get_jit_mapping(NULL, bytes);
        g_expecting_jit_trap = false;
        if (rx != NULL) break;
        usleep(50 * 1000);
    }

    if (!rx) {
        set_status("Failed: debugger returned NULL RX region");
        return false;
    }
    if ((uint64_t)(uintptr_t)rx + bytes > WINIOS_JIT_LOW_LIMIT) {
        WINIOS_LOG("RX region %p above %#llx limit; releasing", rx, WINIOS_JIT_LOW_LIMIT);
        vm_deallocate(mach_task_self(), (vm_address_t)rx, bytes);
        set_status("Failed: RX allocated above low limit (relaunch app)");
        return false;
    }

    /* Map writable alias within +-2 GiB of RX if possible, otherwise anywhere */
    vm_address_t rw = 0;
    vm_prot_t cur_prot = VM_PROT_NONE, max_prot = VM_PROT_NONE;
    kern_return_t kr = KERN_NO_SPACE;
    const uintptr_t step = 16u << 20, reach = (uintptr_t)2 << 30;
    for (uintptr_t off = 0; off <= reach && kr != KERN_SUCCESS; off += step) {
        for (int side = 0; side < 2 && kr != KERN_SUCCESS; side++) {
            uintptr_t want = side == 0 ? (uintptr_t)rx + bytes + off : (uintptr_t)rx - bytes - off;
            if (side == 1 && (uintptr_t)rx < bytes + off + step) continue;
            rw = (vm_address_t)want;
            kr = vm_remap(mach_task_self(), &rw, (vm_size_t)bytes, 0, VM_FLAGS_FIXED,
                          mach_task_self(), (vm_address_t)rx, FALSE, &cur_prot, &max_prot, VM_INHERIT_NONE);
        }
    }
    if (kr != KERN_SUCCESS) {
        rw = 0;
        kr = vm_remap(mach_task_self(), &rw, (vm_size_t)bytes, 0, VM_FLAGS_ANYWHERE,
                      mach_task_self(), (vm_address_t)rx, FALSE, &cur_prot, &max_prot, VM_INHERIT_NONE);
    }
    if (kr != KERN_SUCCESS) {
        set_status("Failed: vm_remap (%s)", mach_error_string(kr));
        vm_deallocate(mach_task_self(), (vm_address_t)rx, bytes);
        return false;
    }

    kr = vm_protect(mach_task_self(), rw, (vm_size_t)bytes, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        set_status("Failed: vm_protect RW (%s)", mach_error_string(kr));
        vm_deallocate(mach_task_self(), rw, bytes);
        vm_deallocate(mach_task_self(), (vm_address_t)rx, bytes);
        return false;
    }

    WinIosDualMapping m = {(uint8_t *)rw, (uint8_t *)rx, bytes};
    if (!jit_selftest(&m)) {
        set_status("Failed: TXM selftest rejected RX execution");
        vm_deallocate(mach_task_self(), rw, bytes);
        vm_deallocate(mach_task_self(), (vm_address_t)rx, bytes);
        return false;
    }

    g_mapping = m;
    prealloc_ledger_exempt_ram();
    atomic_store(&g_jit_live, true);

    if (detach_after) {
        WINIOS_LOG("detaching debugger; %zu MiB RX=%p RW=%p, GuestRAM=%llu MiB stays live",
                   bytes >> 20, (void *)m.rx_addr, (void *)m.rw_addr,
                   (unsigned long long)(g_guest_ram_bytes >> 20));
        g_expecting_jit_trap = true;
        winios_brk_jit_detach();
        g_expecting_jit_trap = false;
    }

    set_status("Live (%zu MiB TXM JIT, %llu MiB RAM)", bytes >> 20,
               (unsigned long long)(g_guest_ram_bytes >> 20));
    return true;
}

bool winios_jit_is_live(void) {
    return atomic_load(&g_jit_live);
}

WinIosDualMapping winios_jit_mapping(void) {
    return g_mapping;
}

void *winios_jit_guest_ram(uint64_t *out_bytes) {
    if (out_bytes) *out_bytes = g_guest_ram_bytes;
    return g_guest_ram;
}

const char *winios_jit_status_text(void) {
    return g_status;
}

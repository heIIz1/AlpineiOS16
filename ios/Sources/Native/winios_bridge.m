/* SPDX-License-Identifier: GPL-2.0-or-later */
#import "winios_bridge.h"

#include "hvsparse.h"
#include "fb_display.h"
#include "virgl.h"
#include "virtio_gpu.h"
#import <AVFoundation/AVFoundation.h>
#include "share.h"
#include "winios_jit.h"
#include "winvm.h"

#import <UIKit/UIKit.h>
#include <math.h>
#include <sys/sysctl.h>
#include <os/lock.h>
#include <sys/stat.h>

static WinIOSBridge *s_shared_bridge = nil;

@interface WinIOSBridge () {
    BOOL _vmRunning;
    BOOL _unpacking;
    double _unpackProgress;
    NSString *_vmStatus;
    dispatch_queue_t _maintenanceQueue;
    dispatch_source_t _maintenanceTimer;
    uint64_t _configuredRamMB;
    int _configuredCPUs;
    CAMetalLayer *__weak _pendingLayer;
    uint64_t _maintenanceTickCount;

    os_unfair_lock _metricsLock;
    CGSize _screenSizePts;
    CGFloat _screenScale;
}
- (void)handleVMExitWithReason:(NSString *)reason;
- (void)updateUnpackProgress:(double)frac;
- (void)startMaintenanceTimer;
- (void)stopMaintenanceTimer;
@end

static void vm_exit_trampoline(int reason) {
    NSString *r = [NSString stringWithUTF8String:hv_winvm_reason_name(reason)];
    dispatch_async(dispatch_get_main_queue(), ^{
        [s_shared_bridge handleVMExitWithReason:r];
    });
}

typedef struct UnpackCtx {
    __unsafe_unretained WinIOSBridge *bridge;
    CFAbsoluteTime lastUpdate;
} UnpackCtx;

static void unpack_progress_cb(uint64_t done, uint64_t total, void *opaque) {
    UnpackCtx *ctx = (UnpackCtx *)opaque;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (done < total && now - ctx->lastUpdate < 0.2) return;
    ctx->lastUpdate = now;
    double frac = total ? (double)done / (double)total : 0.0;
    WinIOSBridge *b = ctx->bridge;
    dispatch_async(dispatch_get_main_queue(), ^{
        [b updateUnpackProgress:frac];
    });
}

@implementation WinIOSBridge

- (NSData *)readSerial {
    uint8_t bytes[16384];
    size_t n = hv_winvm_serial_read(bytes, sizeof bytes);
    return [NSData dataWithBytes:bytes length:n];
}

- (NSUInteger)sendSerial:(NSData *)data {
    return hv_winvm_serial_write(data.bytes, data.length);
}

+ (WinIOSBridge *)shared {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_shared_bridge = [[WinIOSBridge alloc] init];
    });
    return s_shared_bridge;
}

- (instancetype)init {
    if ((self = [super init])) {
        _vmStatus = @"Idle";
        _metricsLock = OS_UNFAIR_LOCK_INIT;
        _screenSizePts = CGSizeZero;
        _screenScale = 3.0;
        hv_share_set_url_handler_enabled(0);
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _maintenanceQueue = dispatch_queue_create("alpineios.maintenance", attr);
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(onAppBackgroundOrTerminate:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [nc addObserver:self selector:@selector(onAppBackgroundOrTerminate:) name:UIApplicationWillTerminateNotification object:nil];
    }
    return self;
}

- (void)onAppBackgroundOrTerminate:(NSNotification *)note {
    (void)note;
    if (_vmRunning) {
        dispatch_async(_maintenanceQueue, ^{
            hv_winvm_flush_disks();
        });
    }
}

- (void)notifyChanged {
    if ([NSThread isMainThread]) {
        if (self.onStateChanged) self.onStateChanged();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onStateChanged) self.onStateChanged();
        });
    }
}

static CGSize guestDisplaySizeAtScale(CGSize size, double *factor) {
    *factor = fmin(*factor, 1536.0 / fmax(size.width, size.height));
    return CGSizeMake(fmax(320, lround(size.width * *factor / 2) * 2),
                      fmax(320, lround(size.height * *factor / 2) * 2));
}

static CGSize guestDisplaySize(CGSize size, double *guestScale) {
    NSString *profile = [[NSUserDefaults standardUserDefaults] stringForKey:@"guestDisplayProfile"];
    *guestScale = [profile isEqualToString:@"smooth"] ? 1.0 : [profile isEqualToString:@"sharp"] ? 1.5 : 1.25;
    return guestDisplaySizeAtScale(size, guestScale);
}

- (void)writeGuestDisplay:(CGSize)size scale:(double)scale {
    NSString *shared = [[self documentsPath] stringByAppendingPathComponent:@"Shared"];
    // Phoc needs a scale of at least 1 even for very small Stage Manager windows.
    [[NSString stringWithFormat:@"%.3f", fmax(1.0, scale)]
        writeToFile:[shared stringByAppendingPathComponent:@".alpineios-display-scale"]
         atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [[NSString stringWithFormat:@"%ux%u %.3f", (unsigned)size.width, (unsigned)size.height, fmax(1.0, scale)]
        writeToFile:[shared stringByAppendingPathComponent:@".alpineios-display-mode"]
         atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)updateScreenSize:(CGSize)size scale:(CGFloat)scale {
    os_unfair_lock_lock(&_metricsLock);
    _screenSizePts = size;
    if (scale > 0.0) _screenScale = scale;
    os_unfair_lock_unlock(&_metricsLock);
    if (_vmRunning && size.width > 0 && size.height > 0) {
        double guestScale;
        CGSize target = guestDisplaySize(size, &guestScale);
        hv_virtio_gpu_request_size((unsigned)target.width, (unsigned)target.height);
        [self writeGuestDisplay:target scale:guestScale];
    }
}

- (void)refreshGuestDisplay {
    os_unfair_lock_lock(&_metricsLock);
    CGSize size = _screenSizePts;
    CGFloat scale = _screenScale;
    os_unfair_lock_unlock(&_metricsLock);
    [self updateScreenSize:size scale:scale];
}

- (void)setGuestPaused:(BOOL)paused {
    if (_vmRunning) hv_winvm_set_paused(paused);
}

- (void)publishClipboard:(NSString *)text {
    hv_share_set_clipboard(text.UTF8String);
}

- (nullable NSString *)takeGuestClipboard {
    char *text = hv_share_take_clipboard();
    if (!text) return nil;
    NSString *value = [NSString stringWithUTF8String:text];
    free(text);
    return value;
}

static NSString *hostModel(void) {
    char model[64] = {0};
    size_t len = sizeof model;
    if (sysctlbyname("hw.machine", model, &len, NULL, 0) != 0 || len == 0 || len > sizeof model) return nil;
    return [NSString stringWithUTF8String:model];
}

static NSString *hostChip(NSString *model) {
    char brand[96] = {0};
    size_t len = sizeof brand;
    if (sysctlbyname("machdep.cpu.brand_string", brand, &len, NULL, 0) == 0 && len > 1 && len <= sizeof brand) {
        NSString *name = [NSString stringWithUTF8String:brand];
        if ([name hasPrefix:@"Apple "]) return name;
    }
    if ([model hasPrefix:@"iPhone17,"]) {
        return [model isEqualToString:@"iPhone17,1"] || [model isEqualToString:@"iPhone17,2"]
            ? @"Apple A18 Pro" : @"Apple A18";
    }
    if ([model hasPrefix:@"iPhone16,"]) return @"Apple A17 Pro";
    if ([model hasPrefix:@"iPhone15,"]) return @"Apple A16 Bionic";
    if ([model hasPrefix:@"iPhone14,"]) return @"Apple A15 Bionic";
    if ([model hasPrefix:@"iPhone13,"]) return @"Apple A14 Bionic";
    if ([model hasPrefix:@"iPhone12,"]) return @"Apple A13 Bionic";
    return nil;
}

- (void)publishHostBattery:(NSNotification *)notification {
    (void)notification;
    UIDevice *device = UIDevice.currentDevice;
    float level = device.batteryLevel;
    HvBatteryState state = HV_BATTERY_UNKNOWN;
    switch (device.batteryState) {
        case UIDeviceBatteryStateUnplugged: state = HV_BATTERY_UNPLUGGED; break;
        case UIDeviceBatteryStateCharging: state = HV_BATTERY_CHARGING; break;
        case UIDeviceBatteryStateFull: state = HV_BATTERY_FULL; break;
        case UIDeviceBatteryStateUnknown: break;
    }
    hv_share_set_battery(level < 0 ? -1 : (int)(level * 100 + 0.5f), state);
}

- (void)installTrapGuard {
    winios_jit_install_trap_handler();
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(publishHostBattery:) name:UIDeviceBatteryLevelDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(publishHostBattery:) name:UIDeviceBatteryStateDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(publishHostBattery:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [self publishHostBattery:nil];
    [[UIApplication sharedApplication] setIdleTimerDisabled:YES];
    UIScreen *mainScreen = [UIScreen mainScreen];
    [self updateScreenSize:mainScreen.bounds.size scale:mainScreen.scale];
    [self notifyChanged];
}

- (BOOL)tryAcquireJIT:(BOOL)detachAfter {
    BOOL ok = winios_jit_acquire(WINIOS_JIT_DEFAULT_BYTES, detachAfter);
    [self notifyChanged];
    return ok;
}

- (BOOL)isJITLive {
    return winios_jit_is_live();
}

- (BOOL)isDebuggerAttached {
    return winios_jit_is_debugger_attached();
}

- (BOOL)isVMRunning {
    return _vmRunning;
}

- (BOOL)isUnpacking {
    return _unpacking;
}

- (double)unpackProgress {
    return _unpackProgress;
}

- (NSString *)jitStatusText {
    return [NSString stringWithUTF8String:winios_jit_status_text()];
}

- (NSString *)vmStatusText {
    return _vmStatus;
}

- (uint32_t)framebufferWidth {
    uint32_t w = 0, h = 0;
    if (_vmRunning && hv_winvm_display_size(&w, &h) == 0) return w;
    return 0;
}

- (uint32_t)framebufferHeight {
    uint32_t w = 0, h = 0;
    if (_vmRunning && hv_winvm_display_size(&w, &h) == 0) return h;
    return 0;
}

- (uint64_t)presentedFrames {
    return _vmRunning ? hv_winvm_display_frames() : 0;
}

- (uint64_t)availableMemoryMB {
    return (uint64_t)(winios_available_memory_bytes() >> 20);
}

- (BOOL)usbKeyboardReady {
    if (!_vmRunning) return NO;
    int kr = 0;
    hv_winvm_usb_stats(&kr, NULL, NULL);
    return kr != 0;
}

- (BOOL)usbTabletReady {
    if (!_vmRunning) return NO;
    int tr = 0;
    hv_winvm_usb_stats(NULL, &tr, NULL);
    return tr != 0;
}

- (uint64_t)usbEventsDelivered {
    if (!_vmRunning) return 0;
    uint64_t d = 0;
    hv_winvm_usb_stats(NULL, NULL, &d);
    return d;
}

- (NSString *)documentsPath {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
}

- (NSString *)machineDirectory {
    NSString *docs = [self documentsPath];
    NSString *alpineDir = [docs stringByAppendingPathComponent:@"Machines/PostmarketOS-Native"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:[alpineDir stringByAppendingPathComponent:@"code.fd"]]) {
        return alpineDir;
    }
    if ([fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"code.fd"]]) {
        return docs;
    }
    [fm createDirectoryAtPath:alpineDir withIntermediateDirectories:YES attributes:nil error:nil];
    return alpineDir;
}

- (BOOL)hasRawDiskImageAt:(NSString *)dir {
    NSString *raw = [dir stringByAppendingPathComponent:@"alpine.img"];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:raw error:nil];
    return attrs && [attrs fileSize] >= (64ull << 20);
}

- (BOOL)needsSparseUnpack {
    NSString *dir = [self machineDirectory];
    NSString *sparse = [dir stringByAppendingPathComponent:@"alpine.hvsparse"];
    return ![self hasRawDiskImageAt:dir] && [[NSFileManager defaultManager] fileExistsAtPath:sparse];
}

- (BOOL)hasProvisionedMachine {
    NSString *dir = [self machineDirectory];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"code.fd"]]) return NO;
    if (![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"vars.fd"]]) return NO;
    return [self hasRawDiskImageAt:dir] || [self needsSparseUnpack];
}

- (void)updateUnpackProgress:(double)frac {
    _unpackProgress = frac;
    _vmStatus = [NSString stringWithFormat:@"Unpacking postmarketOS NVMe image (%.0f%%)...", frac * 100.0];
    [self notifyChanged];
}

- (void)bindMetalLayer:(nullable CAMetalLayer *)layer {
    _pendingLayer = layer;
    if (_vmRunning) {
        hv_winvm_set_display_layer((__bridge void *)layer);
    }
}

- (void)prepareAndStartWithLayer:(nullable CAMetalLayer *)layer {
    if (layer) _pendingLayer = layer;
    if (_vmRunning || _unpacking) return;

    if (![self hasProvisionedMachine]) {
        _vmStatus = @"Download Phosh or import an existing machine";
        [self notifyChanged];
        return;
    }

    NSString *dir = [self machineDirectory];
    if ([self needsSparseUnpack]) {
        _unpacking = YES;
        _unpackProgress = 0.0;
        _vmStatus = @"Unpacking postmarketOS NVMe image (0%)...";
        [self notifyChanged];

        NSString *src = [dir stringByAppendingPathComponent:@"alpine.hvsparse"];
        NSString *dst = [dir stringByAppendingPathComponent:@"alpine.img"];
        NSString *tmpDst = [dir stringByAppendingPathComponent:@"alpine.img.unpacking"];

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            unlink(tmpDst.fileSystemRepresentation);
            UnpackCtx ctx = {.bridge = self, .lastUpdate = 0};
            int rc = hv_sparse_unpack(src.fileSystemRepresentation, tmpDst.fileSystemRepresentation, unpack_progress_cb, &ctx);
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_unpacking = NO;
                if (rc == 0) {
                    if (rename(tmpDst.fileSystemRepresentation, dst.fileSystemRepresentation) != 0) {
                        self->_vmStatus = @"Error: cannot install unpacked Alpine disk";
                        [self notifyChanged];
                        return;
                    }
                    unlink(src.fileSystemRepresentation);
                    self->_unpackProgress = 1.0;
                    [self startConfiguredVMInDirectory:dir];
                } else {
                    unlink(tmpDst.fileSystemRepresentation);
                    self->_vmStatus = @"Error: failed to unpack alpine.hvsparse";
                    [self notifyChanged];
                }
            });
        });
        return;
    }

    [self startConfiguredVMInDirectory:dir];
}

- (void)startConfiguredVMInDirectory:(NSString *)dir {
    if (_vmRunning) return;

    if (!self.isJITLive) {
        [self tryAcquireJIT:YES];
        if (!self.isJITLive) {
            _vmStatus = @"Waiting for TXM JIT (attach StikDebug or launch_on_iphone.sh)";
            [self notifyChanged];
            return;
        }
    }

    setenv("HV_NO_USB", "1", 1);
    // Linux uses virtio-snd. Skip the legacy HDA controller.
    setenv("HV_NO_AUDIO", "1", 1);
    AVAudioSession *audio = AVAudioSession.sharedInstance;
    [audio setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault
               options:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [audio setPreferredSampleRate:48000 error:nil];
    [audio setPreferredIOBufferDuration:0.02 error:nil];
    [audio setActive:YES error:nil];
    WinIosDualMapping jit = winios_jit_mapping();
    if (!jit.rx_addr || !jit.rw_addr) {
        _vmStatus = @"Error: JIT region missing";
        [self notifyChanged];
        return;
    }

    NSString *ramBacking = [NSTemporaryDirectory() stringByAppendingPathComponent:@"alpine_guest_ram.bin"];
    setenv("HV_RAM_FILE", ramBacking.fileSystemRepresentation, 1);

    uint64_t preallocBytes = 0;
    void *preallocRam = winios_jit_guest_ram(&preallocBytes);
    // Alpine profile: keep the same allocation size before and after LLDB detaches.
    uint64_t ramMB = preallocRam ? preallocBytes >> 20 : winios_guest_ram_target_mb();
    if (preallocRam && preallocBytes < (ramMB << 20)) {
        _vmStatus = @"Error: preallocated RAM is smaller than the Alpine profile";
        [self notifyChanged];
        return;
    }

    NSString *sharedDir = [[self documentsPath] stringByAppendingPathComponent:@"Shared"];
    [[NSFileManager defaultManager] createDirectoryAtPath:sharedDir withIntermediateDirectories:YES attributes:nil error:nil];
    // Preserve the device aspect ratio and keep the guest close to UIKit's logical size.
    // Limit the longest edge to keep the framebuffer affordable on larger iPads.
    UIWindowScene *scene = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if ([candidate isKindOfClass:UIWindowScene.class] &&
            candidate.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)candidate;
            break;
        }
    }
    UIScreen *activeScreen = scene.screen ?: UIScreen.mainScreen;
    CGSize screen = scene ? scene.coordinateSpace.bounds.size : activeScreen.bounds.size;
    double scale;
    CGSize target = guestDisplaySize(screen, &scale);
    NSString *mode = [NSString stringWithFormat:@"%ux%u", (unsigned)target.width, (unsigned)target.height];
    setenv("HV_VIRTIO_DISPLAY", mode.UTF8String, 1);
    double smoothScale = 1.0, sharpScale = 1.5, automaticScale = 1.25;
    CGSize smooth = guestDisplaySizeAtScale(screen, &smoothScale);
    CGSize sharp = guestDisplaySizeAtScale(screen, &sharpScale);
    CGSize automatic = guestDisplaySizeAtScale(screen, &automaticScale);
    // Seed the compositor with the profile modes before it opens the DRM output.
    BOOL hasOppositeOrientation = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
    CGSize extra = hasOppositeOrientation ? CGSizeMake(automatic.height, automatic.width) : automatic;
    // The two native Duo panels have these pixel dimensions. Seed its other
    // panel so Phoc already knows the full-screen mode on a fold or unfold.
    CGSize pixels = activeScreen.nativeBounds.size;
    CGFloat shortEdge = fmin(pixels.width, pixels.height);
    CGFloat longEdge = fmax(pixels.width, pixels.height);
    if ((shortEdge == 1398 && longEdge == 2034) || (shortEdge == 1878 && longEdge == 2670)) {
        BOOL inner = shortEdge == 1878;
        BOOL landscape = screen.width > screen.height;
        CGSize other = inner ? CGSizeMake(1398, 2034) : CGSizeMake(1878, 2670);
        if (landscape) other = CGSizeMake(other.height, other.width);
        CGFloat density = activeScreen.nativeScale;
        double otherScale;
        extra = guestDisplaySize(CGSizeMake(other.width / density, other.height / density), &otherScale);
    }
    NSString *alternates = [NSString stringWithFormat:@"%ux%u %ux%u %ux%u",
        (unsigned)smooth.width, (unsigned)smooth.height, (unsigned)sharp.width, (unsigned)sharp.height,
        (unsigned)extra.width, (unsigned)extra.height];
    setenv("HV_VIRTIO_ALTERNATE_MODES", alternates.UTF8String, 1);

    [self writeGuestDisplay:target scale:scale];

    /* Keep AF_UNIX sun_path well under Darwin's 104-byte limit (~82 bytes vs 106 bytes) */
    NSString *rawTmp = [NSTemporaryDirectory() stringByReplacingOccurrencesOfString:@"/private/var/" withString:@"/var/"];
    NSString *shareSock = [rawTmp stringByAppendingPathComponent:@"s"];
    unlink(shareSock.fileSystemRepresentation);

    NSString *codePath = [dir stringByAppendingPathComponent:@"code.fd"];
    NSString *varsPath = [dir stringByAppendingPathComponent:@"vars.fd"];
    NSString *diskPath = [dir stringByAppendingPathComponent:@"alpine.img"];
    NSString *seedPath = [dir stringByAppendingPathComponent:@"seed.img"];
    BOOL hasSeed = [[NSFileManager defaultManager] fileExistsAtPath:seedPath];

    _configuredRamMB = ramMB;
    _configuredCPUs = 1;

    NSString *model = hostModel();
    NSString *chip = hostChip(model);
    unsigned displayHz = (unsigned)activeScreen.maximumFramesPerSecond;
    NSDictionary *identity = @{
        @"model": model ?: NSNull.null,
        @"chip": chip ?: NSNull.null,
        @"cpu_count": @(NSProcessInfo.processInfo.processorCount),
        @"ios_version": UIDevice.currentDevice.systemVersion,
        @"maximum_refresh_hz": @(displayHz)
    };
    NSData *identityJSON = [NSJSONSerialization dataWithJSONObject:identity options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:identityJSON encoding:NSUTF8StringEncoding];
    hv_share_set_host_info(json.UTF8String ?: "{}");
    [self publishHostBattery:nil];

    HvWinVmConfig cfg = {
        .code_fd = codePath.fileSystemRepresentation,
        .vars_fd = varsPath.fileSystemRepresentation,
        .disk0 = diskPath.fileSystemRepresentation,
        .disk1 = hasSeed ? seedPath.fileSystemRepresentation : NULL,
        .share_dir = sharedDir.fileSystemRepresentation,
        .share_sock = shareSock.fileSystemRepresentation,
        .host_model = model.UTF8String,
        .host_chip = chip.UTF8String,
        .display_hz = displayHz,
        .ncpus = _configuredCPUs,
        .ram_mb = _configuredRamMB,
        .jit_bytes = jit.size,
        .jit_rx = jit.rx_addr,
        .jit_rw = jit.rw_addr,
        .prealloc_ram = preallocRam,
        .no_net = 0,
        .enable_sound = 1,
        .log = 0,
        .stats_interval = 0,
    };

    char err[256] = {0};
    if (hv_winvm_create(&cfg, err, sizeof err) != 0) {
        _vmStatus = [NSString stringWithFormat:@"VM create failed: %s", err];
        [self notifyChanged];
        return;
    }

    NSString *graphics = strstr(hv_virgl_status(), "VirGL /") ? @"virgl" : @"software";
    [graphics writeToFile:[sharedDir stringByAppendingPathComponent:@".alpineios-graphics"]
               atomically:YES encoding:NSUTF8StringEncoding error:nil];

    CAMetalLayer *layer = _pendingLayer;
    if (layer) {
        hv_winvm_set_display_layer((__bridge void *)layer);
    }

    _vmRunning = YES;
    _maintenanceTickCount = 0;
    _vmStatus = [NSString stringWithFormat:@"Running postmarketOS ARM64 (%d vCPUs, %llu MB RAM)", _configuredCPUs, _configuredRamMB];
    [[UIApplication sharedApplication] setIdleTimerDisabled:YES];

    hv_winvm_start(1, vm_exit_trampoline);

    [self startMaintenanceTimer];
    [self notifyChanged];
}

- (void)startMaintenanceTimer {
    [self stopMaintenanceTimer];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _maintenanceQueue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                              8ull * NSEC_PER_SEC,
                              1ull * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf onMaintenanceTick];
    });
    _maintenanceTimer = timer;
    dispatch_resume(timer);
}

- (void)stopMaintenanceTimer {
    if (_maintenanceTimer) {
        dispatch_source_cancel(_maintenanceTimer);
        _maintenanceTimer = nil;
    }
}

- (void)onMaintenanceTick {
    _maintenanceTickCount++;
    dispatch_async(dispatch_get_main_queue(), ^{ [self publishHostBattery:nil]; });
    if (_vmRunning && (_maintenanceTickCount % 4u) == 0u) {
        hv_winvm_flush_disks();
    }
    [self notifyChanged];
}

- (void)handleVMExitWithReason:(NSString *)reason {
    _vmRunning = NO;
    [self stopMaintenanceTimer];
    [[UIApplication sharedApplication] setIdleTimerDisabled:NO];
    _vmStatus = [NSString stringWithFormat:@"Stopped (%@)", reason];
    [self notifyChanged];
}

- (void)sendTabletNormalizedX:(double)x y:(double)y buttons:(uint8_t)buttons wheel:(int8_t)wheel {
    if (!_vmRunning) return;
    hv_winvm_tablet(x, y, buttons, wheel);
}

- (void)sendKeyHid:(uint8_t)usage down:(BOOL)down {
    if (!_vmRunning) return;
    hv_winvm_key_hid(usage, down ? 1 : 0);
}

- (void)tapKeyHid:(uint8_t)usage {
    if (!_vmRunning) return;
    hv_winvm_key_hid(usage, 1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(35 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        hv_winvm_key_hid(usage, 0);
    });
}

- (void)sendKeyComboWithModifiers:(NSArray<NSNumber *> *)modifiers key:(uint8_t)usage {
    if (!_vmRunning) return;
    for (NSNumber *m in modifiers) {
        hv_winvm_key_hid((uint8_t)m.unsignedCharValue, 1);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(18 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (usage != 0) hv_winvm_key_hid(usage, 1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(38 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            if (usage != 0) hv_winvm_key_hid(usage, 0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                for (NSNumber *m in [modifiers reverseObjectEnumerator]) {
                    hv_winvm_key_hid((uint8_t)m.unsignedCharValue, 0);
                }
            });
        });
    });
}

- (void)sendWindowsKey {
    [self tapKeyHid:0xe3]; /* Left GUI / Windows key */
}

- (void)sendEscape {
    [self tapKeyHid:0x29]; /* Escape */
}

- (void)sendAltTab {
    [self sendKeyComboWithModifiers:@[@(0xe2)] key:0x2b];
}

- (void)sendCtrlAltDel {
    if (!_vmRunning) return;
    hv_winvm_send_ctrl_alt_del();
}

- (void)pressPowerButton {
    if (!_vmRunning) return;
    hv_winvm_power_button();
}

- (void)flushDisks {
    if (!_vmRunning) return;
    hv_winvm_flush_disks();
}

- (void)stopVM {
    if (!_vmRunning) return;
    hv_winvm_stop();
}

@end

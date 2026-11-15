/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "virgl.h"
#include <TargetConditionals.h>

#if TARGET_OS_IPHONE
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

/* EGL and the stable VirGL callbacks ABI. The dependency frameworks are loaded from the app bundle. */
typedef void *Display;
typedef void *Context;
typedef void *Surface;
typedef struct ContextParams { int version; _Bool shared; int major, minor, compat; } ContextParams;
typedef struct Callbacks {
    int version;
    void (*fence)(void *, uint32_t);
    Context (*create)(void *, int, ContextParams *);
    void (*destroy)(void *, Context);
    int (*current)(void *, int, Context);
    int (*drm_fd)(void *);
    void (*context_fence)(void *, uint32_t, uint32_t, uint64_t);
    int (*server_fd)(void *, uint32_t);
    void *(*egl_display)(void *);
} Callbacks;
static Display display;
static Context root_context;
static Surface surface;
static void *config;
static HvVirgl api;
static const char *status = "Software";
static char failure[512];
static int (*eglMakeCurrent_)(Display, Surface, Surface, Context);
static Context (*eglCreateContext_)(Display, void *, Context, const int *);
static int (*eglDestroyContext_)(Display, Context);
static int (*eglGetError_)(void);
static void *libraries[5];

static void write_fence(void *cookie, uint32_t fence) { (void)cookie; (void)fence; }
static Context create_context(void *cookie, int scanout, ContextParams *p) {
    (void)cookie; (void)scanout;
    const int attributes[] = {0x3098, p->major >= 3 ? 3 : 2, 0x3038};
    Context context = eglCreateContext_(display, config, p->shared ? root_context : NULL, attributes);
    if (!context) fprintf(stderr, "alpineios: EGL context creation failed: 0x%x\n", eglGetError_());
    if (!root_context) root_context = context;
    return context;
}
static void destroy_context(void *cookie, Context context) {
    (void)cookie;
    if (context == root_context) root_context = NULL;
    eglDestroyContext_(display, context);
}
static int make_current(void *cookie, int scanout, Context context) {
    (void)cookie; (void)scanout;
    if (eglMakeCurrent_(display, context ? surface : NULL, context ? surface : NULL, context)) return 0;
    fprintf(stderr, "alpineios: EGL make current failed: 0x%x\n", eglGetError_());
    return -1;
}
static void *get_display(void *cookie) { (void)cookie; return display; }

#define SYMBOL(handle, target, name) do { *(void **)(&(target)) = dlsym(handle, name); if (!(target)) { snprintf(failure, sizeof failure, "Missing %s", name); goto failed; } } while (0)

HvVirgl *hv_virgl_init(void) {
    if (display) {
        hv_virgl_enter();
        api.reset();
        hv_virgl_release_current();
        return &api;
    }
    NSString *folder = NSBundle.mainBundle.privateFrameworksPath;
    const char *names[] = {"vulkan.1", "epoxy.0", "GLESv2", "EGL", "virglrenderer.1"};
    for (unsigned i = 0; i < 5; i++) {
        NSString *name = [NSString stringWithUTF8String:names[i]];
        NSString *path = [[folder stringByAppendingPathComponent:[name stringByAppendingString:@".framework"]]
                         stringByAppendingPathComponent:name];
        libraries[i] = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
        if (!libraries[i]) { snprintf(failure, sizeof failure, "Load %s: %s", names[i], dlerror()); goto failed; }
    }
    void *egl = libraries[3], *renderer = libraries[4];
    Display (*platform_display)(unsigned, void *, const int *);
    int (*initialize)(Display, int *, int *);
    int (*bind_api)(unsigned);
    int (*choose_config)(Display, const int *, void **, int, int *);
    Surface (*create_surface)(Display, void *, const int *);
    int (*renderer_init)(void *, int, Callbacks *);
    void *(*get_proc)(const char *);
    SYMBOL(egl, get_proc, "eglGetProcAddress");
    *(void **)(&platform_display) = get_proc("eglGetPlatformDisplayEXT");
    if (!platform_display) goto failed;
    SYMBOL(egl, initialize, "eglInitialize");
    SYMBOL(egl, bind_api, "eglBindAPI");
    SYMBOL(egl, choose_config, "eglChooseConfig");
    SYMBOL(egl, create_surface, "eglCreatePbufferSurface");
    SYMBOL(egl, eglCreateContext_, "eglCreateContext");
    SYMBOL(egl, eglDestroyContext_, "eglDestroyContext");
    SYMBOL(egl, eglMakeCurrent_, "eglMakeCurrent");
    SYMBOL(egl, eglGetError_, "eglGetError");
    SYMBOL(renderer, renderer_init, "virgl_renderer_init");
    SYMBOL(renderer, api.resource_create, "virgl_renderer_resource_create");
    SYMBOL(renderer, api.resource_unref, "virgl_renderer_resource_unref");
    SYMBOL(renderer, api.context_create, "virgl_renderer_context_create");
    SYMBOL(renderer, api.context_destroy, "virgl_renderer_context_destroy");
    SYMBOL(renderer, api.submit, "virgl_renderer_submit_cmd");
    SYMBOL(renderer, api.read, "virgl_renderer_transfer_read_iov");
    SYMBOL(renderer, api.write, "virgl_renderer_transfer_write_iov");
    SYMBOL(renderer, api.capset, "virgl_renderer_get_cap_set");
    SYMBOL(renderer, api.caps, "virgl_renderer_fill_caps");
    SYMBOL(renderer, api.attach, "virgl_renderer_resource_attach_iov");
    SYMBOL(renderer, api.detach, "virgl_renderer_resource_detach_iov");
    SYMBOL(renderer, api.ctx_attach, "virgl_renderer_ctx_attach_resource");
    SYMBOL(renderer, api.ctx_detach, "virgl_renderer_ctx_detach_resource");
    SYMBOL(renderer, api.force_context, "virgl_renderer_force_ctx_0");
    SYMBOL(renderer, api.reset, "virgl_renderer_reset");
    SYMBOL(renderer, api.info, "virgl_renderer_resource_get_info_ext");
    SYMBOL(libraries[2], api.finish, "glFinish");

    snprintf(failure, sizeof failure, "ANGLE Metal display initialization");
    const int metal[] = {0x3203, 0x3489, 0x3038}; /* ANGLE platform type Metal */
    display = platform_display(0x3202, NULL, metal);
    if (!display || !initialize(display, NULL, NULL) || !bind_api(0x30a0)) goto failed;
    snprintf(failure, sizeof failure, "ANGLE GLES3 configuration");
    const int attributes[] = {0x3033, 1, 0x3040, 0x40, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3038};
    int count = 0;
    if (!choose_config(display, attributes, &config, 1, &count) || !count) goto failed;
    const int dimensions[] = {0x3057, 1, 0x3056, 1, 0x3038};
    snprintf(failure, sizeof failure, "ANGLE pbuffer surface");
    surface = create_surface(display, config, dimensions);
    if (!surface) goto failed;

    static Callbacks callbacks = {4, write_fence, create_context, destroy_context, make_current,
                                  NULL, NULL, NULL, get_display};
    snprintf(failure, sizeof failure, "VirGL GLES initialization");
    int result = renderer_init(&api, (1 << 4) | (1 << 12), &callbacks);
    if (result) { snprintf(failure, sizeof failure, "VirGL GLES initialization (%d)", result); goto failed; }
    status = "VirGL / ANGLE / Metal";
    hv_virgl_release_current();
    return &api;
failed:
    display = NULL;
    status = failure[0] ? failure : "Software (VirGL unavailable)";
    fprintf(stderr, "alpineios: %s\n", status);
    return NULL;
}

void hv_virgl_enter(void) {
    if (display) {
        make_current(NULL, 0, root_context);
        api.force_context();
    }
}
void hv_virgl_release_current(void) {
    if (display) eglMakeCurrent_(display, NULL, NULL, NULL);
}
const char *hv_virgl_status(void) { return status; }

#else
HvVirgl *hv_virgl_init(void) { return 0; }
void hv_virgl_enter(void) {}
void hv_virgl_release_current(void) {}
const char *hv_virgl_status(void) { return "Software"; }
#endif

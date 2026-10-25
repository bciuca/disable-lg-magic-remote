#define _GNU_SOURCE
#include "pointer.h"
#include <dlfcn.h>
#include <gum/gum.h>
#include <stdio.h>

static GumInterceptor *interceptor;
static void *targets[3];
static unsigned installed;
static int attempted;
static mp_custom_fn original_custom;

static int suppress_position(void *handle, int x, int y)
{
    (void)handle; (void)x; (void)y;
    return 0;
}

static int suppress_wheel(void *handle, int delta)
{
    (void)handle; (void)delta;
    return 0;
}

static int filter_custom(void *handle, int kind, unsigned int reason)
{
    /* Function-level IDs, NOT the 0x4ae/0x4af evdev key codes. Preserve
       cursor-off, disconnect, and unknown events with their exact arguments. */
    return original_custom(handle, kind == 4 ? 5 : kind, reason);
}

void mp_restore(void)
{
    if (!interceptor)
        return;
    gum_interceptor_begin_transaction(interceptor);
    while (installed)
        gum_interceptor_revert(interceptor, targets[--installed]);
    gum_interceptor_end_transaction(interceptor);
    /* Do not deinitialize Gum or unload this library: another thread can
       still be returning from a replacement or its original trampoline. */
}

int mp_install(void)
{
    const char *names[] = {
        "lginput_uinput_send_position",
        "lginput_uinput_send_wheel",
        "lginput_uinput_send_custom_event"
    };
    void *replacements[] = {
        (void *)suppress_position, (void *)suppress_wheel, (void *)filter_custom
    };
    if (attempted++)
        return -1;
    /* Resolve everything before changing any function. */
    for (unsigned i = 0; i < 3; ++i) {
        targets[i] = dlsym(RTLD_DEFAULT, names[i]);
        if (!targets[i]) {
            fprintf(stderr, "magic-pointer: missing symbol %s\n", names[i]);
            return -1;
        }
    }
    gum_init_embedded();
    interceptor = gum_interceptor_obtain();
    if (!interceptor)
        return -1;
    gum_interceptor_begin_transaction(interceptor);
    for (unsigned i = 0; i < 3; ++i) {
        void *original = NULL;
        GumReplaceReturn result = gum_interceptor_replace(interceptor,
            targets[i], replacements[i], NULL, &original);
        if (result != GUM_REPLACE_OK) {
            fprintf(stderr, "magic-pointer: replacement failed %s (%d)\n",
                    names[i], result);
            while (installed)
                gum_interceptor_revert(interceptor, targets[--installed]);
            gum_interceptor_end_transaction(interceptor);
            return -1;
        }
        ++installed;
        if (i == 2)
            original_custom = (mp_custom_fn)original;
    }
    /* Publish all hooks only after the original function pointer is ready. */
    gum_interceptor_end_transaction(interceptor);
    return 0;
}

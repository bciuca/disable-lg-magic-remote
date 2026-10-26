/*
 * Copyright (c) 2026, BC (https://github.com/bciuca).
 * SPDX-License-Identifier: MIT
 * See LICENSE in the project root for the full license text.
 */

/* Run on the TV BEFORE touching lginput2. Exercises the real ARM hook engine
   against exported stand-in input functions, including restoration. */
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile int position_calls, wheel_calls, button_calls, event_calls;
static void        *last_handle;
static int          last_kind;
static unsigned int last_reason;

__attribute__((noinline)) int
lginput_uinput_send_position (void *h, int x, int y)
{
    (void)h;
    ++position_calls;
    return x + y + 100;
}
__attribute__((noinline)) int
lginput_uinput_send_wheel (void *h, int delta)
{
    (void)h;
    ++wheel_calls;
    return delta + 200;
}
__attribute__((noinline)) int
lginput_uinput_send_button (void *h, int key, int state)
{
    (void)h;
    ++button_calls;
    return key + state + 300;
}
__attribute__((noinline)) int
lginput_uinput_send_custom_event (void *h, int kind, unsigned int reason)
{
    ++event_calls;
    last_handle = h;
    last_kind   = kind;
    last_reason = reason;
    return kind + 400;
}

static int
serve (void)
{
    char path[160], status[64];
    snprintf(path, sizeof(path), "/tmp/magic-pointer-native-%ld/status",
             (long)getpid());
    printf("READY: isolated injection target PID=%ld\n", (long)getpid());
    fflush(stdout);
    int tested = 0, token = 0;
    for (int seconds = 0; seconds < 180; ++seconds)
    {
        FILE *file = fopen(path, "r");
        status[0]  = '\0';
        if (file)
        {
            if (!fgets(status, sizeof(status), file))
                status[0] = '\0';
            fclose(file);
        }
        if (strcmp(status, "failed\n") == 0)
            return 1;
        if (!tested && strcmp(status, "ready\n") == 0)
        {
            assert(lginput_uinput_send_position(&token, 2, 3) == 0);
            assert(lginput_uinput_send_wheel(&token, 1) == 0);
            assert(lginput_uinput_send_button(&token, 28, 1) == 329);
            assert(lginput_uinput_send_custom_event(&token, 4, 99) == 405);
            assert(last_kind == 5 && last_reason == 99);
            tested = 1;
        }
        if (tested && strcmp(status, "restored\n") == 0)
        {
            assert(lginput_uinput_send_position(&token, 2, 3) == 105);
            assert(lginput_uinput_send_wheel(&token, 1) == 201);
            assert(lginput_uinput_send_custom_event(&token, 4, 99) == 404);
            puts("PASS: injected module, readiness, filtering, timed/explicit "
                 "restoration");
            return 0;
        }
        sleep(1);
    }
    fputs("FAIL: injection/restoration did not finish in 180 seconds\n",
          stderr);
    return 1;
}

int
main (int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "--serve") == 0)
        return serve();
    if (argc != 2)
    {
        fprintf(stderr, "usage: %s /absolute/path/libmagicpointer.so\n",
                argv[0]);
        return 2;
    }
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library)
    {
        fprintf(stderr, "%s\n", dlerror());
        return 1;
    }
    int (*install)(void)  = dlsym(library, "mp_install");
    void (*restore)(void) = dlsym(library, "mp_restore");
    assert(install && restore);
    int token = 123;
    assert(lginput_uinput_send_position(&token, 2, 3) == 105);
    assert(install() == 0);
    assert(lginput_uinput_send_position(&token, 2, 3) == 0);
    assert(position_calls == 1);
    assert(lginput_uinput_send_wheel(&token, -9) == 0);
    assert(wheel_calls == 0);
    for (int state = 0; state <= 2; ++state)
        assert(lginput_uinput_send_button(&token, 28, state) == 328 + state);
    assert(button_calls == 3);
    for (int kind = -1; kind <= 20; ++kind)
    {
        int expected = kind == 4 ? 5 : kind;
        assert(lginput_uinput_send_custom_event(&token, kind, 0xf1234567U) ==
               expected + 400);
        assert(last_handle == &token && last_kind == expected &&
               last_reason == 0xf1234567U);
    }
    assert(event_calls == 22);
    assert(install() != 0);
    restore();
    restore();
    assert(lginput_uinput_send_position(&token, 2, 3) == 105);
    assert(lginput_uinput_send_wheel(&token, -9) == 191);
    assert(lginput_uinput_send_custom_event(&token, 4, 99) == 404);
    assert(last_kind == 4 && last_reason == 99);
    /* Intentionally retain the module, matching the production lifetime. */
    puts("PASS: real hooks, event forwarding, buttons, duplicate rejection, "
         "restoration");
    return 0;
}

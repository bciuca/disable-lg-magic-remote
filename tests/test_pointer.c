/*
 * Copyright (c) 2026, BC (https://github.com/bciuca).
 * SPDX-License-Identifier: MIT
 * See LICENSE in the project root for the full license text.
 */

#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#define dlsym fake_dlsym
#include "../src/pointer.c"
#undef dlsym

static GumInterceptor mock;
static int            lookup_count, replacement_count, reverted, depth;
static int            fail_lookup = -1, fail_replace = -1;
static int            identifiers[3];
static void          *callbacks[3];
static void          *seen_handle;
static int            seen_kind;
static unsigned int   seen_reason;
static int
original (void *h, int kind, unsigned int reason)
{
    seen_handle = h;
    seen_kind   = kind;
    seen_reason = reason;
    return -123;
}
void *
fake_dlsym (void *handle, const char *name)
{
    (void)handle;
    assert(strstr(name, "send_button") == NULL);
    int index = lookup_count++;
    return index == fail_lookup ? NULL : &identifiers[index];
}
void
gum_init_embedded (void)
{
}
GumInterceptor *
gum_interceptor_obtain (void)
{
    return &mock;
}
void
gum_interceptor_begin_transaction (GumInterceptor *i)
{
    assert(i == &mock);
    ++depth;
}
void
gum_interceptor_end_transaction (GumInterceptor *i)
{
    assert(i == &mock);
    assert(depth-- == 1);
}
GumReplaceReturn
gum_interceptor_replace (GumInterceptor *i, void *target, void *callback,
                         void *data, void **out)
{
    (void)data;
    assert(i == &mock && depth == 1);
    int index = replacement_count++;
    assert(target == &identifiers[index]);
    if (index == fail_replace)
        return GUM_REPLACE_WRONG_SIGNATURE;
    callbacks[index] = callback;
    *out             = (void *)original;
    return GUM_REPLACE_OK;
}
void
gum_interceptor_revert (GumInterceptor *i, void *target)
{
    assert(i == &mock && depth == 1);
    assert(target != NULL);
    ++reverted;
}

static void
scenario (int kind, int index)
{
    if (kind == 1)
        fail_lookup = index;
    if (kind == 2)
        fail_replace = index;
    int result = mp_install();
    if (kind)
    {
        assert(result == -1 && depth == 0);
        assert(reverted == (kind == 2 ? index : 0));
        assert(installed == 0);
    }
    else
    {
        assert(result == 0 && depth == 0 && installed == 3);
        assert(((mp_position_fn)callbacks[0])(&mock, -99, 100) == 0);
        assert(((mp_wheel_fn)callbacks[1])(&mock, -9) == 0);
        for (int event = -100; event <= 100; ++event)
        {
            assert(((mp_custom_fn)callbacks[2])(&mock, event, 0xf1234567U) ==
                   -123);
            assert(seen_handle == &mock && seen_reason == 0xf1234567U);
            assert(seen_kind == (event == 4 ? 5 : event));
        }
        assert(mp_install() == -1 && replacement_count == 3);
        mp_restore();
        mp_restore();
        assert(reverted == 3 && installed == 0 && depth == 0);
    }
}
int
main (void)
{
    for (int kind = 0; kind < 3; ++kind)
        for (int index = 0; index < (kind ? 3 : 1); ++index)
        {
            pid_t child = fork();
            assert(child >= 0);
            if (child == 0)
            {
                scenario(kind, index);
                _exit(0);
            }
            int status;
            assert(waitpid(child, &status, 0) == child);
            assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
        }
    puts("PASS: filtering, forwarding, missing symbols, partial installation, "
         "rollback, duplicate refusal");
    return 0;
}

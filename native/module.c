#include "ezinject_module.h"
#include "pointer.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static char state_dir[128];
static unsigned trial_seconds;
#ifndef MP_STATE_PREFIX
#define MP_STATE_PREFIX "/tmp/magic-pointer-native-"
#endif

static int status_write(const char *status)
{
    char path[160], temporary[160];
    snprintf(path, sizeof(path), "%s/status", state_dir);
    snprintf(temporary, sizeof(temporary), "%s/status.new", state_dir);
    int fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    if (fd < 0)
        return -1;
    size_t length = strlen(status);
    int ok = write(fd, status, length) == (ssize_t)length;
    if (close(fd) != 0)
        ok = 0;
    if (!ok || rename(temporary, path) != 0)
        return -1;
    return 0;
}

static void *control(void *unused)
{
    (void)unused;
    char request[160];
    snprintf(request, sizeof(request), "%s/restore", state_dir);
    struct timespec start, now;
    if (clock_gettime(CLOCK_MONOTONIC, &start) != 0 || mp_install() != 0) {
        status_write("failed\n");
        return NULL;
    }
    if (status_write("ready\n") != 0) {
        mp_restore();
        status_write("failed\n");
        return NULL;
    }
    for (;;) {
        if (access(request, F_OK) == 0)
            break;
        if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
            break;
        if (trial_seconds && now.tv_sec - start.tv_sec >= (time_t)trial_seconds)
            break;
        sleep(1);
    }
    mp_restore();
    unlink(request);
    status_write("restored\n");
    return NULL;
}

int lib_loginit(log_config_t *config)
{
    (void)config;
    return -1;
}

int lib_preinit(struct injcode_user *user)
{
    user->persist = 1;
    return 0;
}

int lib_main(int argc, char **argv)
{
    /* ezinject supplies the module path as argv[0]. Require an explicit
       duration: positive = timed trial, zero = persist for this process. */
    if (argc != 2 || !argv[1][0])
        return -1;
    for (const char *p = argv[1]; *p; ++p)
        if (*p < '0' || *p > '9')
            return -1;
    errno = 0;
    unsigned long duration = strtoul(argv[1], NULL, 10);
    if (errno || duration > 3600)
        return -1;
    trial_seconds = (unsigned)duration;
    snprintf(state_dir, sizeof(state_dir), MP_STATE_PREFIX "%ld", (long)getpid());
    /* Exclusive private directory also refuses a second load into this PID. */
    if (mkdir(state_dir, 0700) != 0)
        return -1;
    pthread_t thread;
    if (pthread_create(&thread, NULL, control, NULL) != 0) {
        status_write("failed\n");
        return -1;
    }
    pthread_detach(thread);
    return 0;
}

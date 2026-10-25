#include <assert.h>
#include <stdatomic.h>
#include <sys/wait.h>
#include "../native/module.c"

static atomic_int restores;
static int installation_failure;
int mp_install(void) { return installation_failure ? -1 : 0; }
void mp_restore(void) { atomic_fetch_add(&restores, 1); }

static void wait_status(const char *expected)
{
    char path[160], actual[64];
    snprintf(path, sizeof(path), "%s/status", state_dir);
    for (int tries = 0; tries < 300; ++tries) {
        FILE *file = fopen(path, "r");
        if (file) {
            char *result = fgets(actual, sizeof(actual), file);
            fclose(file);
            if (result && strcmp(actual, expected) == 0)
                return;
        }
        usleep(10000);
    }
    assert(!"timed out waiting for module status");
}
static void scenario(int test)
{
    struct injcode_user user = {0};
    assert(lib_preinit(&user) == 0 && user.persist == 1);
    char *invalid[] = { "module", "-1" };
    assert(lib_main(2, invalid) == -1);
    invalid[1] = "3601";
    assert(lib_main(2, invalid) == -1);
    invalid[1] = "1x";
    assert(lib_main(2, invalid) == -1);
    assert(lib_main(1, invalid) == -1);
    char *args[] = { "module", test == 0 ? "1" : "0" };
    if (test == 2) installation_failure = 1;
    assert(lib_main(2, args) == 0);
    assert(lib_main(2, args) == -1);
    if (test == 2) {
        wait_status("failed\n");
        assert(atomic_load(&restores) == 0);
    } else {
        wait_status("ready\n");
        if (test == 1) {
            char path[160];
            snprintf(path, sizeof(path), "%s/restore", state_dir);
            int fd = open(path, O_WRONLY | O_CREAT, 0600);
            assert(fd >= 0);
            close(fd);
        }
        wait_status("restored\n");
        assert(atomic_load(&restores) == 1);
    }
    char status[160];
    snprintf(status, sizeof(status), "%s/status", state_dir);
    assert(unlink(status) == 0 && rmdir(state_dir) == 0);
}
int main(void)
{
    for (int test = 0; test < 3; ++test) {
        pid_t child = fork();
        assert(child >= 0);
        if (child == 0) { scenario(test); _exit(0); }
        int status;
        assert(waitpid(child, &status, 0) == child);
        assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    }
    puts("PASS: timed restoration, explicit restoration, readiness, failure reporting, argument validation");
    return 0;
}

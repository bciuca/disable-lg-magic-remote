#!/bin/sh
# Single-instance watcher for the tested native module. Never restart lginput2.
set -eu
BASE=${MP_BASE:-/home/root/magic-pointer-native}
RUNTIME=${MP_RUNTIME:-/tmp}
PROC=${MP_PROC:-/proc}
LOG="$RUNTIME/magic-pointer-native-watch.log"

for command in flock timeout sha256sum; do
    command -v "$command" >/dev/null || exit 1
done
# Keep the lock inode in place. flock releases it on process exit or reboot.
exec 9>"$RUNTIME/magic-pointer-native-watch.lock"
flock -n 9 || exit 0
exec >>"$LOG" 2>&1
echo "native watcher starting: $(date)"
[ ! -e "$BASE/disabled" ] || exit 0
PAYLOAD=$(cat "$BASE/active")
case "$PAYLOAD" in "$BASE"/candidate-*) ;; *) echo 'Invalid payload path'; exit 1;; esac
[ -x "$PAYLOAD/ezinject" ] && [ -f "$PAYLOAD/libmagicpointer.so" ] || exit 1
(cd "$PAYLOAD" && sha256sum -c SHA256SUMS) || exit 1

identity() {
    [ "$(cat "$PROC/$1/comm" 2>/dev/null)" = lginput2 ] || return 1
    # lginput2's comm contains no spaces, so field 22 is its start time.
    start=$(awk '{print $22}' "$PROC/$1/stat" 2>/dev/null) || return 1
    [ -n "$start" ] || return 1
    printf '%s:%s\n' "$1" "$start"
}

resume_own_target() {
    [ "$(identity "$pid" || true)" = "$target" ] || return 0
    state=$(awk '$1 == "State:" {print $2}' "$PROC/$pid/status")
    tracer=$(awk '$1 == "TracerPid:" {print $2}' "$PROC/$pid/status")
    # Only recover our originally running target after the injector has exited.
    if [ "$state" = T ] && [ "$tracer" = 0 ]; then
        echo "Resuming our detached target $target"
        kill -CONT "$pid"
    fi
}

# Attempts survive watcher restarts, but /tmp resets on reboot. Each directory
# is reserved BEFORE invoking ptrace and includes the process start time.
ATTEMPTS="$RUNTIME/magic-pointer-native-attempts"
mkdir -p "$ATTEMPTS"

handle_target() (
    # A subshell contains set -e failures (including disappearing /proc files).
    state=$(awk '$1 == "State:" {print $2}' "$PROC/$pid/status")
    tracer=$(awk '$1 == "TracerPid:" {print $2}' "$PROC/$pid/status")
    case "$state" in T|t|Z|X) echo "Refusing target state $state"; exit 1;; esac
    [ "$tracer" = 0 ] || { echo 'Target already traced; skipping'; exit 1; }
    state_dir="$RUNTIME/magic-pointer-native-$pid"
    owner="$ATTEMPTS/owner-$pid"
    if grep -Eq 'libphp|libinputhook|libnopointer' "$PROC/$pid/maps"; then
        echo 'Existing foreign input hook; waiting for a clean process'
        exit 1
    fi
    if grep -q libmagicpointer "$PROC/$pid/maps"; then
        if [ "$(cat "$state_dir/status" 2>/dev/null || true)" = ready ]; then
            # Adopt supervision after a watcher restart without loading again.
            printf '%s\n' "$target" > "$owner"
            echo "Native hook already ready in $target; supervising without reinjection"
            exit 0
        fi
        echo 'Existing native library is not ready; waiting for a clean process'
        exit 1
    fi
    [ ! -d "$ATTEMPTS/$target" ] || {
        echo "Already attempted $target; waiting for a fresh process"; exit 1;
    }
    if [ -e "$state_dir" ]; then
        previous=$(cat "$owner" 2>/dev/null || true)
        case "$previous" in
            "$pid":*)
                [ "$previous" != "$target" ] || exit 1
                # Preserve stale state for diagnostics; never reuse its ready marker.
                mv "$state_dir" "$ATTEMPTS/$previous-state"
                ;;
            *) echo 'Unknown existing module state; refusing reinjection'; exit 1;;
        esac
    fi
    [ "$(identity "$pid" || true)" = "$target" ] || exit 1
    [ ! -e "$BASE/disabled" ] || exit 0
    mkdir "$ATTEMPTS/$target"
    printf '%s\n' "$target" > "$owner"
    echo "Injecting native hook into $target"
    : > "$RUNTIME/magic-pointer-native-module.log"
    result=0
    timeout -t 30 -s KILL "$PAYLOAD/ezinject" \
        -l "$RUNTIME/magic-pointer-native-module.log" \
        "$pid" "$PAYLOAD/libmagicpointer.so" 0 \
        > "$RUNTIME/magic-pointer-native-injector.log" 2>&1 || result=$?
    resume_own_target
    if [ "$result" -ne 0 ]; then
        echo "Injector failed ($result); waiting for a fresh process"
        exit 1
    fi
    count=0
    status=
    while [ "$count" -lt 15 ]; do
        [ "$(identity "$pid" || true)" = "$target" ] || {
            echo 'Target changed during injection; waiting for a fresh process'; exit 1;
        }
        resume_own_target
        status=$(cat "$state_dir/status" 2>/dev/null || true)
        case "$status" in
            ready) break;;
            failed|restored) echo "Hook status: $status; no reinjection"; exit 1;;
        esac
        sleep 1
        count=$((count + 1))
    done
    [ "$status" = ready ] || { echo 'Hook readiness timed out; no retries'; exit 1; }
    echo "Native hook ready in $target"
)

last=
while [ ! -e "$BASE/disabled" ]; do
    pid=$(pidof lginput2 || true)
    case "$pid" in
        ''|*[!0-9]*) sleep 2; continue;;
    esac
    target=$(identity "$pid" || true)
    [ -n "$target" ] || { sleep 2; continue; }
    if [ "$target" != "$last" ]; then
        # Do not use handle_target in an OR/if condition: that disables set -e
        # inside shell functions. Wait explicitly so failures remain contained.
        handle_target &
        worker=$!
        wait "$worker" || echo "Target $target skipped; watcher remains available for respawns"
        last=$target
    fi
    sleep 2
done
echo 'Native watcher disabled'

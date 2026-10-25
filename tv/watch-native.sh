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
exec >"$LOG" 2>&1
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

last=
while [ ! -e "$BASE/disabled" ]; do
    pid=$(pidof lginput2 || true)
    case "$pid" in
        '') sleep 2; continue;;
        *[!0-9]*) echo 'Expected one lginput2 process; stopping'; exit 1;;
    esac
    target=$(identity "$pid" || true)
    [ -n "$target" ] || { sleep 2; continue; }
    if [ "$target" = "$last" ]; then
        # Intentional restoration must not trigger another injection.
        [ "$(cat "$RUNTIME/magic-pointer-native-$pid/status" 2>/dev/null)" = ready ] || {
            echo 'Native hook no longer ready; stopping without reinjection'; exit 1;
        }
        sleep 2
        continue
    fi
    state=$(awk '$1 == "State:" {print $2}' "$PROC/$pid/status")
    tracer=$(awk '$1 == "TracerPid:" {print $2}' "$PROC/$pid/status")
    case "$state" in T|t|Z|X) echo "Refusing target state $state"; exit 1;; esac
    [ "$tracer" = 0 ] || { echo 'Target already traced; stopping'; exit 1; }
    if grep -Eq 'libphp|libmagicpointer|libinputhook|libnopointer' "$PROC/$pid/maps"; then
        echo 'Existing injected library; reboot into a clean process before switching'
        exit 1
    fi
    [ ! -e "$RUNTIME/magic-pointer-native-$pid" ] || {
        echo 'Existing module state for PID; refusing an ambiguous reinjection'; exit 1;
    }
    [ "$(identity "$pid" || true)" = "$target" ] || continue
    [ ! -e "$BASE/disabled" ] || exit 0
    echo "Injecting native hook into $target"
    : > "$RUNTIME/magic-pointer-native-module.log"
    # BusyBox 1.24 on the C9 uses -t, not the newer positional timeout syntax.
    result=0
    timeout -t 30 -s KILL "$PAYLOAD/ezinject" \
        -l "$RUNTIME/magic-pointer-native-module.log" \
        "$pid" "$PAYLOAD/libmagicpointer.so" 0 \
        > "$RUNTIME/magic-pointer-native-injector.log" 2>&1 || result=$?
    resume_own_target
    if [ "$result" -ne 0 ]; then
        echo "Injector failed ($result); no retries in this process"
        exit 1
    fi
    count=0
    while [ "$count" -lt 15 ]; do
        [ "$(identity "$pid" || true)" = "$target" ] || {
            echo 'Target changed during injection; stopping'; exit 1;
        }
        resume_own_target
        status=$(cat "$RUNTIME/magic-pointer-native-$pid/status" 2>/dev/null || true)
        case "$status" in
            ready) break;;
            failed|restored) echo "Hook status: $status; stopping"; exit 1;;
        esac
        sleep 1
        count=$((count + 1))
    done
    [ "$status" = ready ] || { echo 'Hook readiness timed out; no retries'; exit 1; }
    echo "Native hook ready in $target"
    last=$target
done
echo 'Native watcher disabled'

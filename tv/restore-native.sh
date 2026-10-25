#!/bin/sh
# Disable this native setup and request live restoration; never kill lginput2.
set -eu
BASE=/home/root/magic-pointer-native
touch "$BASE/disabled"
rm -f /var/lib/webosbrew/init.d/disable-magic-pointer-native
# Wait for any in-progress injection to finish before requesting restoration.
count=0
while ! flock -n /tmp/magic-pointer-native-watch.lock true; do
    count=$((count + 1))
    [ "$count" -le 50 ] || { echo 'Watcher did not stop; inspect its log'; exit 1; }
    sleep 1
done
pid=$(pidof lginput2 || true)
case "$pid" in ''|*[!0-9]*) echo 'No single input process; native autostart disabled'; exit 0;; esac
STATE="/tmp/magic-pointer-native-$pid"
if [ "$(cat "$STATE/status" 2>/dev/null || true)" = ready ]; then
    touch "$STATE/restore"
    count=0
    while [ "$(cat "$STATE/status")" != restored ]; do
        count=$((count + 1))
        [ "$count" -le 10 ] || { echo 'Restoration not acknowledged; inspect input-service status'; exit 1; }
        sleep 1
    done
    echo 'Native input restored; library remains mapped until process exit'
else
    echo 'Native autostart disabled; no ready native hook to restore'
fi

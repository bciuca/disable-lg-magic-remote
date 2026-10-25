#!/bin/sh
# Schedule the validated candidate for the next boot. Does not reboot/inject.
set -eu
TV="${1:?usage: ./install-native.sh root@TV-IP}"
case "$TV" in -*) echo 'Invalid SSH target' >&2; exit 1;; esac
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BASE=/home/root/magic-pointer-native
"$ROOT/stage-native.sh" "$TV"
ID=$(shasum -a 256 "$ROOT/.build/dist/SHA256SUMS" | cut -c1-16)
ssh "$TV" 'command -v flock >/dev/null && command -v timeout >/dev/null && test -d /var/lib/webosbrew/init.d'
for name in watch-native.sh restore-native.sh; do
    ssh "$TV" "cat > '$BASE/$name.new' && chmod 755 '$BASE/$name.new' && mv '$BASE/$name.new' '$BASE/$name'" < "$ROOT/tv/$name"
done
ssh "$TV" "cat > '$BASE/boot-native.new' && chmod 755 '$BASE/boot-native.new'" < "$ROOT/tv/boot-native.sh"
ssh "$TV" "set -eu
    mkdir -p '$BASE/legacy-backup'
    if [ -f /var/lib/webosbrew/init.d/disable-magic-pointer ]; then
        if [ -f '$BASE/legacy-backup/disable-magic-pointer' ]; then
            cmp /var/lib/webosbrew/init.d/disable-magic-pointer '$BASE/legacy-backup/disable-magic-pointer'
        else
            cp -p /var/lib/webosbrew/init.d/disable-magic-pointer '$BASE/legacy-backup/disable-magic-pointer'
        fi
        rm /var/lib/webosbrew/init.d/disable-magic-pointer
    fi
    printf '%s\n' '$BASE/candidate-$ID' > '$BASE/active.new'
    mv '$BASE/active.new' '$BASE/active'
    rm -f '$BASE/disabled'
    mv '$BASE/boot-native.new' /var/lib/webosbrew/init.d/disable-magic-pointer-native
    sync"
echo 'Native boot hook installed. Reboot to replace any existing in-memory hook.'
echo "Rollback: ssh $TV 'sh $BASE/restore-native.sh'"

#!/bin/sh
# Copyright (c) 2026, BC (https://github.com/bciuca).
# SPDX-License-Identifier: MIT
# See LICENSE in the project root for the full license text.

# Upload an immutable candidate for isolated tests. Does not inject or autostart.
set -eu
TV="${1:?usage: ./stage-native.sh root@TV-IP}"
case "$TV" in -*) echo 'Invalid SSH target' >&2; exit 1;; esac
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DIST="$ROOT/.build/dist"
[ -f "$DIST/SHA256SUMS" ] || { echo 'Run ./build-native.sh first.' >&2; exit 1; }
(cd "$DIST" && shasum -a 256 -c SHA256SUMS)
ID=$(shasum -a 256 "$DIST/SHA256SUMS" | cut -c1-16)
DEST="/home/root/magic-pointer-native/candidate-$ID"
ssh -o ConnectTimeout=8 -o BatchMode=yes "$TV" \
    'test "$(id -u)" = 0 && command -v sha256sum >/dev/null' || {
    echo 'Root SSH and sha256sum are required.' >&2; exit 1;
}
if ssh "$TV" "test -d '$DEST'"; then
    ssh "$TV" "cd '$DEST' && sha256sum -c SHA256SUMS"
else
    # mkdir without -p for the staging directory refuses concurrent writers.
    ssh "$TV" "mkdir -p /home/root/magic-pointer-native && mkdir '$DEST.upload'"
    for name in ezinject libmagicpointer.so pointer-fixture pointer-fixture-thumb SHA256SUMS; do
        ssh "$TV" "cat > '$DEST.upload/$name'" < "$DIST/$name"
    done
    ssh "$TV" "cd '$DEST.upload' && sha256sum -c SHA256SUMS && chmod 755 ezinject pointer-fixture pointer-fixture-thumb && mv '$DEST.upload' '$DEST'"
fi
echo "Staged at $DEST"
echo 'No input-service changes or boot-hook changes were made.'
echo "Next: run $DEST/pointer-fixture $DEST/libmagicpointer.so in an isolated process."

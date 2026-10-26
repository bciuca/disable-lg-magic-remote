#!/bin/sh
# Copyright (c) 2026, BC (https://github.com/bciuca).
# SPDX-License-Identifier: MIT
# See LICENSE in the project root for the full license text.

BASE=/home/root/magic-pointer-native
[ ! -e "$BASE/disabled" ] || exit 0
[ -x "$BASE/watch-native.sh" ] || exit 1
nohup /bin/sh "$BASE/watch-native.sh" </dev/null >/dev/null 2>&1 &
exit 0

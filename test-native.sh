#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$ROOT/.build/tests"
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -I "$ROOT/tests/stubs" \
    "$ROOT/tests/test_pointer.c" -o "$ROOT/.build/tests/test-pointer"
"$ROOT/.build/tests/test-pointer"
TEST_STATE=$(mktemp -d /tmp/magic-pointer-tests.XXXXXX)
trap 'rmdir "$TEST_STATE"' EXIT HUP INT TERM
"${CC:-cc}" -std=c11 -D_DEFAULT_SOURCE -Wall -Wextra -Werror -pthread \
    -DMP_STATE_PREFIX="\"$TEST_STATE/pid-\"" -I "$ROOT/tests/stubs" \
    "$ROOT/tests/test_module.c" -o "$ROOT/.build/tests/test-module"
"$ROOT/.build/tests/test-module"
python3 "$ROOT/tests/test_watcher.py"

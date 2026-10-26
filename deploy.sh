#!/bin/sh
# Copyright (c) 2026, BC (https://github.com/bciuca).
# SPDX-License-Identifier: MIT
# See LICENSE in the project root for the full license text.

# Install the native candidate for the next boot; build and test it first.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$HERE/install-native.sh" "$@"

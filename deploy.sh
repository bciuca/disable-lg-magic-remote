#!/bin/sh
# Install the native candidate for the next boot; build and test it first.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$HERE/install-native.sh" "$@"

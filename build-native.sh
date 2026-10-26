#!/bin/sh
# Copyright (c) 2026, BC (https://github.com/bciuca).
# SPDX-License-Identifier: MIT
# See LICENSE in the project root for the full license text.

# Build a matching ARM injector, native module, and isolated TV test programs.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD="$ROOT/.build"
SDK="${1:-$BUILD/sdk}"
SDK_REV=webos-d7ed7ee.6
SDK_SHA=954333694ab1fe1f7737e81a0be1e3188cdfffc1a119c81c86f5fcebf1857c45
DEPS_SHA=a8d82460b3a96a96cb2f3847df19d2c641672a9d8facf7141502c29dd86f9000
EZ_REV=d9338952cd01597c5fdd7d6e98991474df5dc89c

for tool in cmake git curl tar shasum pkg-config; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
PKG_CONFIG=$(command -v pkg-config)
mkdir -p "$BUILD/downloads"
verify() { printf '%s  %s\n' "$1" "$2" | shasum -a 256 -c -; }
download() {
    if [ ! -f "$2" ]; then
        curl --fail --location --retry 3 "$1" -o "$2.part"
        mv "$2.part" "$2"
    fi
    verify "$3" "$2"
}

if [ ! -f "$SDK/share/buildroot/toolchainfile.cmake" ]; then
    if [ "$#" -gt 0 ] || [ "$(uname -sm)" != 'Darwin arm64' ]; then
        echo "Provide an extracted webOS SDK: $0 /absolute/path/to/sdk" >&2
        exit 1
    fi
    download "https://github.com/webosbrew/native-toolchain/releases/download/$SDK_REV/arm-webos-linux-gnueabi_sdk-buildroot_darwin-arm64.tar.bz2" \
        "$BUILD/downloads/webos-sdk.tar.bz2" "$SDK_SHA"
    mkdir -p "$SDK"
    tar -xjf "$BUILD/downloads/webos-sdk.tar.bz2" -C "$SDK" --strip-components=1
fi
SDK=$(CDPATH= cd -- "$SDK" && pwd)

GUM_SYSROOT="$BUILD/deps/arm-lgtv-linux-gnueabi/sysroot"
if [ ! -f "$BUILD/deps/.complete" ]; then
    download https://github.com/openlgtv/buildroot-nc4/releases/download/2026.08-webos/arm-lgtv-linux-gnueabi_sdk-buildroot-x86_64.tar.gz \
        "$BUILD/downloads/webos-deps.tar.gz" "$DEPS_SHA"
    mkdir -p "$BUILD/deps"
    # Extract only ARM headers/libraries, avoiding Linux host programs and
    # case-sensitive terminfo paths that cannot be extracted on default macOS.
    tar -xzf "$BUILD/downloads/webos-deps.tar.gz" -C "$BUILD/deps" --strip-components=1 \
        arm-lgtv-linux-gnueabi_sdk-buildroot/arm-lgtv-linux-gnueabi/sysroot/usr/include \
        arm-lgtv-linux-gnueabi_sdk-buildroot/arm-lgtv-linux-gnueabi/sysroot/usr/lib
    touch "$BUILD/deps/.complete"
fi

if [ ! -d "$BUILD/ezinject/.git" ]; then
    git clone https://github.com/smx-smx/ezinject.git "$BUILD/ezinject"
    git -C "$BUILD/ezinject" checkout --detach "$EZ_REV"
fi
[ "$(git -C "$BUILD/ezinject" rev-parse HEAD)" = "$EZ_REV" ] || {
    echo "Injector cache does not match pinned revision $EZ_REV" >&2; exit 1;
}
git -C "$BUILD/ezinject" diff --quiet HEAD -- || {
    echo 'Injector sources have local modifications; refusing an unverified build.' >&2; exit 1;
}

cmake -S "$BUILD/ezinject" -B "$BUILD/ezinject-build" \
    -DCMAKE_TOOLCHAIN_FILE="$SDK/share/buildroot/toolchainfile.cmake" \
    -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_BUILD_TYPE=Release \
    -DUSE_FRIDA_GUM=OFF -DENABLE_CPP_SAMPLES=OFF -DENABLE_PHP_SAMPLE=OFF
cmake --build "$BUILD/ezinject-build" --target ezinject ezinject_crt --parallel 4
cmake -S "$ROOT/src" -B "$BUILD/src" \
    -DCMAKE_TOOLCHAIN_FILE="$SDK/share/buildroot/toolchainfile.cmake" \
    -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_BUILD_TYPE=Release \
    -DPKG_CONFIG_EXECUTABLE="$PKG_CONFIG" \
    -DEZINJECT_SOURCE="$BUILD/ezinject" -DEZINJECT_BUILD="$BUILD/ezinject-build" \
    -DGUM_SYSROOT="$GUM_SYSROOT"
cmake --build "$BUILD/src" --parallel 4

mkdir -p "$BUILD/dist"
cp "$BUILD/ezinject-build/ezinject" "$BUILD/src/libmagicpointer.so" \
    "$BUILD/src/pointer-fixture" "$BUILD/src/pointer-fixture-thumb" "$BUILD/dist/"
for name in ezinject libmagicpointer.so pointer-fixture pointer-fixture-thumb; do
    "$SDK/bin/arm-webos-linux-gnueabi-strip" --strip-unneeded "$BUILD/dist/$name"
done
(cd "$BUILD/dist" && shasum -a 256 ezinject libmagicpointer.so pointer-fixture pointer-fixture-thumb > SHA256SUMS)
echo "Native artifacts: $BUILD/dist (not yet verified on your TV)"

#!/bin/sh
# Reproducible build script for awg-warp-auto-quic using OpenWrt SDK
set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
SDK_DIR=${1:-/home/mmikhnev/sdk/openwrt-sdk-25.12.4-mediatek-filogic_gcc-14.3.0_musl.Linux-x86_64}
OUT_DIR=${2:-"$REPO_DIR/dist"}

if [ ! -d "$SDK_DIR" ]; then
	echo "Error: SDK directory not found at $SDK_DIR" >&2
	exit 1
fi

mkdir -p "$OUT_DIR"
STAGING_TARGET="$SDK_DIR/staging_dir/target-aarch64_cortex-a53_musl"
TOOLCHAIN_BIN="$SDK_DIR/staging_dir/toolchain-aarch64_cortex-a53_gcc-14.3.0_musl/bin"
HOST_BIN="$SDK_DIR/staging_dir/host/bin"
export PATH="$HOST_BIN:$TOOLCHAIN_BIN:$PATH"
export STAGING_DIR="$SDK_DIR/staging_dir"

TARGET_CC="$TOOLCHAIN_BIN/aarch64-openwrt-linux-gcc"
TARGET_STRIP="$TOOLCHAIN_BIN/aarch64-openwrt-linux-musl-strip"
APK_TOOL="$HOST_BIN/apk"

TMP_BUILD=$(mktemp -d /tmp/quic-i1-build.XXXXXX)
trap 'rm -rf "$TMP_BUILD"' EXIT

echo "Compiling quic-i1 with $TARGET_CC..."
"$TARGET_CC" -O2 -pipe -mcpu=cortex-a53 \
  -I"$STAGING_TARGET/usr/include" \
  -L"$STAGING_TARGET/usr/lib" \
  -Wl,--allow-shlib-undefined \
  -std=c99 -Wall -Wextra -Werror \
  -o "$TMP_BUILD/quic-i1" \
  "$REPO_DIR/source/awg-warp-auto-quic/src/quic-i1.c" \
  -lmbedcrypto

"$TARGET_STRIP" "$TMP_BUILD/quic-i1"

echo "Packaging APK using $APK_TOOL..."
PKG_ROOT="$TMP_BUILD/pkg-root"
mkdir -p "$PKG_ROOT/usr/bin" "$PKG_ROOT/lib/apk/packages"
cp "$TMP_BUILD/quic-i1" "$PKG_ROOT/usr/bin/quic-i1"
chmod 755 "$PKG_ROOT/usr/bin/quic-i1"
echo "/usr/bin/quic-i1" > "$PKG_ROOT/lib/apk/packages/awg-warp-auto-quic.list"

"$APK_TOOL" mkpkg \
  --info "name:awg-warp-auto-quic" \
  --info "version:1.0.0-r1" \
  --info "description:Local Mini QUIC I1 generator for AmneziaWG" \
  --info "arch:aarch64_cortex-a53" \
  --info "license:MIT" \
  --info "origin:source/awg-warp-auto-quic" \
  --info "maintainer:OpenWrt Developer" \
  --info "depends:libmbedtls21" \
  --files "$PKG_ROOT" \
  --output "$OUT_DIR/awg-warp-auto-quic-1.0.0-r1.apk"

cp "$TMP_BUILD/quic-i1" "$OUT_DIR/quic-i1"

echo "Build successful: $OUT_DIR/awg-warp-auto-quic-1.0.0-r1.apk"

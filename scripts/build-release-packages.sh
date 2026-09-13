#!/bin/sh
# Reproducible build script for WARP Auto packages and release archive
set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
SDK_DIR=${1:-/home/mmikhnev/sdk/openwrt-sdk-25.12.4-mediatek-filogic_gcc-14.3.0_musl.Linux-x86_64}
VERSION="2.0.5-r1"
RELEASE_DIR="$REPO_DIR/dist"

if [ ! -d "$SDK_DIR" ]; then
	echo "Error: SDK directory not found at $SDK_DIR" >&2
	exit 1
fi

mkdir -p "$RELEASE_DIR" "$REPO_DIR/release/packages" "$REPO_DIR/release/keys"
STAGING_TARGET="$SDK_DIR/staging_dir/target-aarch64_cortex-a53_musl"
TOOLCHAIN_BIN="$SDK_DIR/staging_dir/toolchain-aarch64_cortex-a53_gcc-14.3.0_musl/bin"
HOST_BIN="$SDK_DIR/staging_dir/host/bin"
export PATH="$HOST_BIN:$TOOLCHAIN_BIN:$PATH"
export STAGING_DIR="$SDK_DIR/staging_dir"

TARGET_CC="$TOOLCHAIN_BIN/aarch64-openwrt-linux-gcc"
TARGET_STRIP="$TOOLCHAIN_BIN/aarch64-openwrt-linux-musl-strip"
APK_TOOL="$HOST_BIN/apk"

TMP_BUILD=$(mktemp -d /tmp/warp-auto-build.XXXXXX)
trap 'rm -rf "$TMP_BUILD"' EXIT

echo "=== 1. Building awg-warp-auto-quic binary ==="
"$TARGET_CC" -O2 -pipe -mcpu=cortex-a53 \
  -I"$STAGING_TARGET/usr/include" \
  -L"$STAGING_TARGET/usr/lib" \
  -Wl,--allow-shlib-undefined \
  -std=c99 -Wall -Wextra -Werror \
  -o "$TMP_BUILD/quic-i1" \
  "$REPO_DIR/source/awg-warp-auto-quic/src/quic-i1.c" \
  -lmbedcrypto

"$TARGET_STRIP" "$TMP_BUILD/quic-i1"

echo "=== 2. Packaging awg-warp-auto-quic APK ==="
QUIC_ROOT="$TMP_BUILD/quic-pkg-root"
mkdir -p "$QUIC_ROOT/usr/bin" "$QUIC_ROOT/lib/apk/packages"
cp "$TMP_BUILD/quic-i1" "$QUIC_ROOT/usr/bin/quic-i1"
chmod 755 "$QUIC_ROOT/usr/bin/quic-i1"
echo "/usr/bin/quic-i1" > "$QUIC_ROOT/lib/apk/packages/awg-warp-auto-quic.list"

"$APK_TOOL" mkpkg \
  --info "name:awg-warp-auto-quic" \
  --info "version:1.0.0-r1" \
  --info "description:Local Mini QUIC I1 generator for AmneziaWG" \
  --info "arch:aarch64_cortex-a53" \
  --info "license:MIT" \
  --info "origin:source/awg-warp-auto-quic" \
  --info "maintainer:OpenWrt Developer" \
  --info "depends:libmbedtls21" \
  --files "$QUIC_ROOT" \
  --output "$RELEASE_DIR/awg-warp-auto-quic-1.0.0-r1.apk"

cp "$TMP_BUILD/quic-i1" "$RELEASE_DIR/quic-i1"
cp "$RELEASE_DIR/awg-warp-auto-quic-1.0.0-r1.apk" "$REPO_DIR/release/packages/"
cp "$RELEASE_DIR/quic-i1" "$REPO_DIR/release/packages/"

echo "=== 3. Packaging luci-proto-amneziawg APK (WARP Auto bundle) ==="
LUCI_ROOT="$TMP_BUILD/luci-pkg-root"
mkdir -p "$LUCI_ROOT/www/luci-static/resources/view/amneziawg" \
         "$LUCI_ROOT/www/luci-static/resources/protocol" \
         "$LUCI_ROOT/www/luci-static/resources/icons" \
         "$LUCI_ROOT/usr/share/rpcd/ucode" \
         "$LUCI_ROOT/usr/share/rpcd/acl.d" \
         "$LUCI_ROOT/usr/share/luci/menu.d" \
         "$LUCI_ROOT/usr/share/ucode/luci/controller" \
         "$LUCI_ROOT/usr/libexec/awg-warp-auto" \
         "$LUCI_ROOT/etc/config" \
         "$LUCI_ROOT/etc/init.d" \
         "$LUCI_ROOT/lib/apk/packages"

SRC="$REPO_DIR/source/luci-proto-amneziawg"

cp "$SRC/htdocs/luci-static/resources/view/amneziawg/status.js" "$LUCI_ROOT/www/luci-static/resources/view/amneziawg/"
cp "$SRC/htdocs/luci-static/resources/protocol/amneziawg.js" "$LUCI_ROOT/www/luci-static/resources/protocol/"
cp "$SRC/htdocs/luci-static/resources/icons/amneziawg.svg" "$LUCI_ROOT/www/luci-static/resources/icons/"
cp "$SRC/root/usr/share/rpcd/ucode/luci.amneziawg" "$LUCI_ROOT/usr/share/rpcd/ucode/"
cp "$SRC/root/usr/share/rpcd/acl.d/luci-amneziawg.json" "$LUCI_ROOT/usr/share/rpcd/acl.d/"
cp "$SRC/root/usr/share/luci/menu.d/luci-proto-amneziawg.json" "$LUCI_ROOT/usr/share/luci/menu.d/"
cp "$SRC/root/usr/share/ucode/luci/controller/awgdownload.uc" "$LUCI_ROOT/usr/share/ucode/luci/controller/"
cp "$SRC/root/usr/libexec/awg-warp-auto/"* "$LUCI_ROOT/usr/libexec/awg-warp-auto/"
cp "$SRC/root/etc/config/awg-warp-auto" "$LUCI_ROOT/etc/config/"
cp "$SRC/root/etc/init.d/awg-warp-auto" "$LUCI_ROOT/etc/init.d/"

chmod 644 "$LUCI_ROOT/www/luci-static/resources/view/amneziawg/status.js" \
          "$LUCI_ROOT/www/luci-static/resources/protocol/amneziawg.js" \
          "$LUCI_ROOT/www/luci-static/resources/icons/amneziawg.svg" \
          "$LUCI_ROOT/usr/share/rpcd/ucode/luci.amneziawg" \
          "$LUCI_ROOT/usr/share/rpcd/acl.d/luci-amneziawg.json" \
          "$LUCI_ROOT/usr/share/luci/menu.d/luci-proto-amneziawg.json" \
          "$LUCI_ROOT/usr/share/ucode/luci/controller/awgdownload.uc" \
          "$LUCI_ROOT/usr/libexec/awg-warp-auto/warp-gen-fetch.uc" \
          "$LUCI_ROOT/usr/libexec/awg-warp-auto/warp-gen-provider.uc" \
          "$LUCI_ROOT/etc/config/awg-warp-auto"
chmod 755 "$LUCI_ROOT/usr/libexec/awg-warp-auto/activate-worker.uc" \
          "$LUCI_ROOT/usr/libexec/awg-warp-auto/daemon.sh" \
          "$LUCI_ROOT/usr/libexec/awg-warp-auto/candidate-test.sh" \
          "$LUCI_ROOT/usr/libexec/awg-warp-auto/health-check.sh" \
          "$LUCI_ROOT/usr/libexec/awg-warp-auto/native-provider.sh" \
          "$LUCI_ROOT/usr/libexec/awg-warp-auto/provider-fetch.sh" \
          "$LUCI_ROOT/etc/init.d/awg-warp-auto"

# Write installed files list for clean apk management
cat << "LISTEOF" > "$LUCI_ROOT/lib/apk/packages/luci-proto-amneziawg.list"
/etc/config/awg-warp-auto
/etc/init.d/awg-warp-auto
/usr/libexec/awg-warp-auto/activate-worker.uc
/usr/libexec/awg-warp-auto/candidate-test.sh
/usr/libexec/awg-warp-auto/daemon.sh
/usr/libexec/awg-warp-auto/health-check.sh
/usr/libexec/awg-warp-auto/native-provider.sh
/usr/libexec/awg-warp-auto/provider-fetch.sh
/usr/libexec/awg-warp-auto/warp-gen-fetch.uc
/usr/libexec/awg-warp-auto/warp-gen-provider.uc
/usr/share/luci/menu.d/luci-proto-amneziawg.json
/usr/share/rpcd/acl.d/luci-amneziawg.json
/usr/share/rpcd/ucode/luci.amneziawg
/usr/share/ucode/luci/controller/awgdownload.uc
/www/luci-static/resources/icons/amneziawg.svg
/www/luci-static/resources/protocol/amneziawg.js
/www/luci-static/resources/view/amneziawg/status.js
LISTEOF

"$APK_TOOL" mkpkg \
  --info "name:luci-proto-amneziawg" \
  --info "version:$VERSION" \
  --info "description:Support and Web UI for AmneziaWG VPN and WARP Auto" \
  --info "arch:aarch64_cortex-a53" \
  --info "license:Apache-2.0" \
  --info "origin:source/luci-proto-amneziawg" \
  --info "maintainer:OpenWrt Developer" \
  --info "depends:amneziawg-tools ucode luci-lib-uqr resolveip curl ca-bundle awg-warp-auto-quic" \
  --files "$LUCI_ROOT" \
  --output "$RELEASE_DIR/luci-proto-amneziawg-$VERSION.apk"

cp "$RELEASE_DIR/luci-proto-amneziawg-$VERSION.apk" "$REPO_DIR/release/packages/"

echo "=== 4. Syncing release overlay ==="
mkdir -p "$REPO_DIR/release/overlay"
cp -r "$SRC/root/"* "$REPO_DIR/release/overlay/"
mkdir -p "$REPO_DIR/release/overlay/www"
cp -r "$SRC/htdocs/"* "$REPO_DIR/release/overlay/www/"
chmod 755 "$REPO_DIR/release/overlay/usr/libexec/awg-warp-auto/activate-worker.uc" \
          "$REPO_DIR/release/overlay/usr/libexec/awg-warp-auto/daemon.sh" \
          "$REPO_DIR/release/overlay/usr/libexec/awg-warp-auto/candidate-test.sh" \
          "$REPO_DIR/release/overlay/usr/libexec/awg-warp-auto/health-check.sh" \
          "$REPO_DIR/release/overlay/usr/libexec/awg-warp-auto/native-provider.sh" \
          "$REPO_DIR/release/overlay/usr/libexec/awg-warp-auto/provider-fetch.sh" \
          "$REPO_DIR/release/overlay/etc/init.d/awg-warp-auto"

echo "=== 5. Packaging release archive ==="
RELEASE_TAR="awg-warp-auto-${VERSION}-openwrt25.12.4-filogic.tar.gz"
(
  cd "$REPO_DIR"
  rm -rf "$TMP_BUILD/awg-warp-auto-release"
  mkdir -p "$TMP_BUILD/awg-warp-auto-release"
  cp -r release/* "$TMP_BUILD/awg-warp-auto-release/"
  tar -czf "$RELEASE_DIR/$RELEASE_TAR" -C "$TMP_BUILD" awg-warp-auto-release
  cp "$RELEASE_DIR/$RELEASE_TAR" "$REPO_DIR/release/awg-warp-auto-release.tar.gz"
  cp "$RELEASE_DIR/$RELEASE_TAR" "$RELEASE_DIR/awg-warp-auto-release.tar.gz"
  (cd "$RELEASE_DIR" && sha256sum "$RELEASE_TAR" > "${RELEASE_TAR}.sha256")
)

echo "=== 6. Packaging unified installer zip ==="
INSTALLER_DIR="$RELEASE_DIR/windows-installer"
rm -rf "$INSTALLER_DIR"
mkdir -p "$INSTALLER_DIR"
cp "$REPO_DIR/release/README.txt" "$INSTALLER_DIR/" 2>/dev/null || true
cp "$REPO_DIR/release/install-windows.bat" "$INSTALLER_DIR/"
cp "$REPO_DIR/release/install-windows.ps1" "$INSTALLER_DIR/"
cp "$REPO_DIR/release/install-linux.sh" "$INSTALLER_DIR/"
cp "$RELEASE_DIR/awg-warp-auto-release.tar.gz" "$INSTALLER_DIR/"

(
  cd "$RELEASE_DIR"
  rm -f awg-warp-auto-installer.zip awg-warp-auto-windows-installer.zip
  zip -q -r awg-warp-auto-installer.zip windows-installer/
  cp awg-warp-auto-installer.zip awg-warp-auto-windows-installer.zip
)

echo "=== Build finished successfully: $RELEASE_DIR/$RELEASE_TAR ==="
echo "=== Installer archive ready: $RELEASE_DIR/awg-warp-auto-installer.zip ==="

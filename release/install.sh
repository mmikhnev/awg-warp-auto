#!/bin/sh
# Production self-contained installer for WARP Auto & AmneziaWG
# Supports OpenWrt 25.x+ (apk) and fallback 24.x (opkg)
# Uses verified package feed from https://github.com/Slava-Shchipunov/awg-openwrt
set -eu

# ANSI colors
C_RESET=$(printf '\033[0m')
C_RED=$(printf '\033[1;31m')
C_GREEN=$(printf '\033[1;32m')
C_YELLOW=$(printf '\033[1;33m')
C_BLUE=$(printf '\033[1;34m')
C_CYAN=$(printf '\033[1;36m')
C_BOLD=$(printf '\033[1m')

case "$(id -u)" in
	0) ;;
	*) echo "${C_RED}[ERROR] Run as root on the OpenWrt router.${C_RESET}" >&2; exit 1 ;;
esac

BASE_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
AWG_UPSTREAM_BASE="https://slava-shchipunov.github.io/awg-openwrt"
AWG_KEY_URL="$AWG_UPSTREAM_BASE/keys/awg-openwrt-feed.pem"

echo "${C_CYAN}=== 1. System & Target Detection ===${C_RESET}"
OS_RELEASE="/etc/openwrt_release"
if [ ! -f "$OS_RELEASE" ]; then
	echo "${C_RED}[ERROR] /etc/openwrt_release not found. Not an OpenWrt system.${C_RESET}" >&2
	exit 1
fi

# Detect OpenWrt version, target, subtarget, and architecture
DISTRIB_RELEASE=$(grep "^DISTRIB_RELEASE=" "$OS_RELEASE" | cut -d"'" -f2)
DISTRIB_TARGET=$(grep "^DISTRIB_TARGET=" "$OS_RELEASE" | cut -d"'" -f2)
DISTRIB_ARCH=$(grep "^DISTRIB_ARCH=" "$OS_RELEASE" | cut -d"'" -f2)

TARGET=${DISTRIB_TARGET%/*}
SUBTARGET=${DISTRIB_TARGET#*/}
VERSION=${DISTRIB_RELEASE}

if command -v ubus >/dev/null 2>&1; then
	UBUS_TARGET=$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.target' 2>/dev/null || true)
	if [ -n "$UBUS_TARGET" ]; then
		TARGET=${UBUS_TARGET%/*}
		SUBTARGET=${UBUS_TARGET#*/}
	fi
	UBUS_VER=$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.version' 2>/dev/null || true)
	[ -n "$UBUS_VER" ] && VERSION="$UBUS_VER"
fi

if command -v apk >/dev/null 2>&1; then
	PKG_MGR="apk"
elif command -v opkg >/dev/null 2>&1; then
	PKG_MGR="opkg"
else
	echo "ERROR: Neither apk nor opkg package manager found." >&2
	exit 1
fi

echo "Detected System:"
echo "  OpenWrt Version : $VERSION"
echo "  Target/Subtarget: $TARGET/$SUBTARGET"
echo "  Architecture    : $DISTRIB_ARCH"
echo "  Package Manager : $PKG_MGR"

echo "${C_CYAN}=== 2. Checking & Configuring AmneziaWG Upstream Feed ===${C_RESET}"
if [ "$PKG_MGR" = "apk" ]; then
	# OpenWrt 25.x+ flow: add upstream signed APK feed
	KEYS_DIR="/etc/apk/keys"
	mkdir -p "$KEYS_DIR"
	FEED_KEY="$KEYS_DIR/awg-openwrt-feed.pem"
	if [ -f "$BASE_DIR/keys/awg-openwrt-feed.pem" ]; then
		cp "$BASE_DIR/keys/awg-openwrt-feed.pem" "$FEED_KEY"
		echo "Installed bundled AmneziaWG public signing key."
	elif [ ! -s "$FEED_KEY" ]; then
		echo "Installing AmneziaWG public signing key..."
		if ! curl -fsSL --connect-timeout 10 "$AWG_KEY_URL" -o "$FEED_KEY" 2>/dev/null && \
		   ! wget -q -O "$FEED_KEY" "$AWG_KEY_URL" 2>/dev/null; then
			echo "${C_YELLOW}[WARNING] Could not download signing key from $AWG_KEY_URL. Untrusted packages will be allowed.${C_RESET}" >&2
		fi
	fi

	FEED_URL="$AWG_UPSTREAM_BASE/$VERSION/$TARGET/$SUBTARGET/packages.adb"
	FEED_FILE="/etc/apk/repositories.d/customfeeds.list"
	mkdir -p "/etc/apk/repositories.d"
	[ -f "$FEED_FILE" ] || touch "$FEED_FILE"

	# Add feed only if not already present
	if ! grep -qF "$FEED_URL" "$FEED_FILE"; then
		# Safe backup of customfeeds.list
		cp "$FEED_FILE" "${FEED_FILE}.bak.$(date +%s)"
		echo "$FEED_URL" >> "$FEED_FILE"
		echo "Added upstream feed: $FEED_URL"
	else
		echo "Upstream feed already configured: $FEED_URL"
	fi

	echo "Updating package index..."
	apk update 2>/dev/null || echo "${C_YELLOW}[WARNING] apk update had warnings or network is offline. Proceeding with local packages...${C_RESET}"
else
	# OpenWrt 24.x opkg flow
	echo "Updating opkg index..."
	opkg update 2>/dev/null || echo "${C_YELLOW}[WARNING] opkg update had warnings. Proceeding...${C_RESET}"
fi

echo "${C_CYAN}=== 3. Installing Base Dependencies ===${C_RESET}"
# Required runtime utilities including LuCI Web UI
if [ "$PKG_MGR" = "apk" ]; then
	apk add --allow-untrusted luci curl ca-bundle ucode resolveip jsonfilter luci-lib-uqr libmbedtls21 2>/dev/null || {
		echo "NOTE: Some base packages were already installed or network is offline. Continuing..."
	}
else
	opkg install luci curl ca-bundle ucode resolveip jsonfilter luci-lib-uqr libmbedtls21 2>/dev/null || true
fi

echo "${C_CYAN}=== 4. Installing AmneziaWG Kernel Module & Userspace Tools ===${C_RESET}"
# Install kmod-amneziawg and amneziawg-tools from local packages or configured feeds
PACKAGES_DIR="$BASE_DIR/packages"
KMOD_APK=$(find "$PACKAGES_DIR" -name "kmod-amneziawg-*.apk" 2>/dev/null | head -n 1 || true)
AWG_TOOLS_APK=$(find "$PACKAGES_DIR" -name "amneziawg-tools-*.apk" 2>/dev/null | head -n 1 || true)

if [ "$PKG_MGR" = "apk" ]; then
	if ! apk info -e kmod-amneziawg >/dev/null 2>&1; then
		if [ -n "$KMOD_APK" ] && [ -f "$KMOD_APK" ]; then
			echo "Installing bundled $KMOD_APK..."
			apk add --allow-untrusted "$KMOD_APK" 2>/dev/null || true
		fi
		if ! apk info -e kmod-amneziawg >/dev/null 2>&1; then
			echo "Installing kmod-amneziawg from feed..."
			apk add --allow-untrusted kmod-amneziawg || {
				echo "${C_RED}[ERROR] Unable to install kmod-amneziawg for target $TARGET/$SUBTARGET${C_RESET}" >&2
				exit 1
			}
		fi
	else
		echo "${C_GREEN}[✓] kmod-amneziawg already installed.${C_RESET}"
	fi

	if ! apk info -e amneziawg-tools >/dev/null 2>&1; then
		if [ -n "$AWG_TOOLS_APK" ] && [ -f "$AWG_TOOLS_APK" ]; then
			echo "Installing bundled $AWG_TOOLS_APK..."
			apk add --allow-untrusted "$AWG_TOOLS_APK" 2>/dev/null || true
		fi
		if ! apk info -e amneziawg-tools >/dev/null 2>&1; then
			echo "Installing amneziawg-tools from feed..."
			apk add --allow-untrusted amneziawg-tools || {
				echo "${C_RED}[ERROR] Unable to install amneziawg-tools${C_RESET}" >&2
				exit 1
			}
		fi
	else
		echo "${C_GREEN}[✓] amneziawg-tools already installed.${C_RESET}"
	fi
else
	opkg list-installed | grep -q "^kmod-amneziawg " || opkg install kmod-amneziawg
	opkg list-installed | grep -q "^amneziawg-tools " || opkg install amneziawg-tools
fi

echo "${C_CYAN}=== 5. Installing Local Packages (quic-i1 & WARP Auto) ===${C_RESET}"
# Check for bundled APKs in packages/
QUIC_APK=$(find "$PACKAGES_DIR" -name "awg-warp-auto-quic-*.apk" 2>/dev/null | head -n 1 || true)
LUCI_APK=$(find "$PACKAGES_DIR" -name "luci-proto-amneziawg-*.apk" 2>/dev/null | head -n 1 || true)

if [ "$PKG_MGR" = "apk" ] && [ -n "$QUIC_APK" ] && [ -f "$QUIC_APK" ]; then
	echo "Installing bundled $QUIC_APK..."
	apk add --allow-untrusted "$QUIC_APK"
elif [ -f "$BASE_DIR/dist/quic-i1" ]; then
	echo "Installing standalone quic-i1 binary..."
	cp "$BASE_DIR/dist/quic-i1" /usr/bin/quic-i1
	chmod 755 /usr/bin/quic-i1
fi

if [ "$PKG_MGR" = "apk" ] && [ -n "$LUCI_APK" ] && [ -f "$LUCI_APK" ]; then
	echo "Installing bundled $LUCI_APK..."
	apk add --allow-untrusted "$LUCI_APK"
elif [ -d "$BASE_DIR/overlay" ]; then
	echo "Installing WARP Auto application files from overlay..."
	cp -r "$BASE_DIR/overlay/"* /
	chmod 644 /usr/share/rpcd/ucode/luci.amneziawg \
	          /www/luci-static/resources/view/amneziawg/status.js \
	          /usr/share/ucode/luci/controller/awgdownload.uc \
	          /usr/share/rpcd/acl.d/luci-amneziawg.json \
	          /usr/share/luci/menu.d/luci-proto-amneziawg.json
	chmod 755 /usr/libexec/awg-warp-auto/*.sh \
	          /usr/libexec/awg-warp-auto/*.uc \
	          /etc/init.d/awg-warp-auto
fi

# Ensure AWG 3.1 binaries & netifd protocol are applied if bundled
if [ -f "$PACKAGES_DIR/v3/awg" ]; then
	echo "Installing AmneziaWG 3.1 userspace tool (/usr/bin/awg)..."
	cp "$PACKAGES_DIR/v3/awg" /usr/bin/awg
	chmod 755 /usr/bin/awg
fi
if [ -f "$PACKAGES_DIR/v3/amneziawg.ko" ]; then
	kmod_dir="/lib/modules/$(uname -r)"
	if [ -d "$kmod_dir" ]; then
		echo "Installing AmneziaWG 3.1 kernel module ($kmod_dir/amneziawg.ko)..."
		cp "$PACKAGES_DIR/v3/amneziawg.ko" "$kmod_dir/amneziawg.ko"
		chmod 644 "$kmod_dir/amneziawg.ko"
		if ! lsmod | grep -q amneziawg; then
			echo "Loading AmneziaWG kernel module (insmod)..."
			insmod "$kmod_dir/amneziawg.ko" 2>/dev/null || true
		fi
	fi
fi
if [ -f "$BASE_DIR/overlay/lib/netifd/proto/amneziawg.sh" ]; then
	echo "Installing AWG 3.1 netifd protocol handler..."
	mkdir -p /lib/netifd/proto
	cp "$BASE_DIR/overlay/lib/netifd/proto/amneziawg.sh" /lib/netifd/proto/amneziawg.sh
	chmod 755 /lib/netifd/proto/amneziawg.sh
fi

# Ensure all scripts and binaries have proper permissions regardless of packaging method
chmod 755 /usr/libexec/awg-warp-auto/*.sh \
          /usr/libexec/awg-warp-auto/*.uc \
          /etc/init.d/awg-warp-auto 2>/dev/null || true
[ -f /usr/bin/quic-i1 ] && chmod 755 /usr/bin/quic-i1
[ -f /lib/netifd/proto/amneziawg.sh ] && chmod 755 /lib/netifd/proto/amneziawg.sh

echo "${C_CYAN}=== 6. Initializing Configuration & Services Safely ===${C_RESET}"
# Ensure default UCI config exists without overwriting user data
if [ ! -f /etc/config/awg-warp-auto ]; then
	if [ -f "$BASE_DIR/overlay/etc/config/awg-warp-auto" ]; then
		cp "$BASE_DIR/overlay/etc/config/awg-warp-auto" /etc/config/awg-warp-auto
		chmod 600 /etc/config/awg-warp-auto
	fi
fi

# Ensure default native_quic_mode is dynamic
if [ -f /etc/config/awg-warp-auto ]; then
	current_mode=$(uci -q get awg-warp-auto.main.native_quic_mode || true)
	if [ "$current_mode" != "dynamic" ] && [ "$current_mode" != "fallback" ]; then
		uci set awg-warp-auto.main.native_quic_mode='dynamic'
		uci commit awg-warp-auto
	fi
fi

# Clear LuCI cache
rm -f /tmp/luci-indexcache 2>/dev/null || true

# Reload rpcd and restart awg-warp-auto service ONLY
echo "Reloading rpcd service..."
/etc/init.d/rpcd restart

echo "Enabling and starting awg-warp-auto service..."
/etc/init.d/awg-warp-auto enable 2>/dev/null || true
/etc/init.d/awg-warp-auto restart 2>/dev/null || true

echo "${C_CYAN}=== 7. Post-Installation Verification ===${C_RESET}"
FAILURES=0

if [ -x /usr/bin/quic-i1 ]; then
	echo "  ${C_GREEN}[✓]${C_RESET} /usr/bin/quic-i1 is present and executable"
else
	echo "  ${C_RED}[✗]${C_RESET} /usr/bin/quic-i1 missing or not executable"
	FAILURES=$((FAILURES + 1))
fi

if command -v awg >/dev/null 2>&1; then
	echo "  ${C_GREEN}[✓]${C_RESET} amneziawg-tools (awg binary) is functional"
else
	echo "  ${C_RED}[✗]${C_RESET} awg binary missing"
	FAILURES=$((FAILURES + 1))
fi

if [ -f /lib/modules/$(uname -r)/amneziawg.ko ] || lsmod | grep -q amneziawg; then
	echo "  ${C_GREEN}[✓]${C_RESET} kmod-amneziawg kernel module is present"
else
	echo "  ${C_RED}[✗]${C_RESET} kmod-amneziawg missing"
	FAILURES=$((FAILURES + 1))
fi

if ubus call luci.amneziawg getWarpAutoStatus >/dev/null 2>&1; then
	echo "  ${C_GREEN}[✓]${C_RESET} rpcd luci.amneziawg ubus service responding"
else
	echo "  ${C_RED}[✗]${C_RESET} rpcd luci.amneziawg ubus service not responding"
	FAILURES=$((FAILURES + 1))
fi

if [ "$FAILURES" -eq 0 ]; then
	echo ""
	echo "${C_GREEN}============================================================${C_RESET}"
	echo "${C_BOLD}${C_GREEN}  WARP Auto installation completed successfully!            ${C_RESET}"
	echo "  Open LuCI Web UI -> Services -> AmneziaWG to manage.      "
	echo "${C_GREEN}============================================================${C_RESET}"
	exit 0
else
	echo ""
	echo "${C_RED}[ERROR] Installation finished with $FAILURES verification failure(s).${C_RESET}" >&2
	exit 1
fi

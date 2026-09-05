#!/bin/sh
# Installs only the matching AmneziaWG base packages from the bundled upstream
# installer. The -n switch is intentional: interface/firewall setup belongs to
# the WARP Auto LuCI flow and must never be performed by this script.
set -eu

case "$(id -u)" in
	0) ;;
	*) echo 'Run as root on the OpenWrt router.' >&2; exit 1 ;;
esac

BASE_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
INSTALLER="$BASE_DIR/source/amneziawg-install.sh"

[ -f "$INSTALLER" ] || {
	echo 'Bundled base installer is missing.' >&2
	exit 1
}

install_runtime_dependencies() {
	if command -v apk >/dev/null 2>&1; then
		apk update
		apk add luci curl ca-bundle ucode resolveip jsonfilter luci-lib-uqr
	elif command -v opkg >/dev/null 2>&1; then
		opkg update
		opkg install luci curl ca-bundle ucode resolveip jsonfilter luci-lib-uqr
	else
		echo 'No supported OpenWrt package manager (apk/opkg).' >&2
		exit 1
	fi
}

package_installed() {
	package_name=$1
	if command -v apk >/dev/null 2>&1; then
		apk info -e "$package_name" >/dev/null 2>&1
	else
		opkg list-installed 2>/dev/null | grep -q "^${package_name} "
	fi
}

# The bundled installer uses jsonfilter while it detects the matching AWG
# package. Install its runtime prerequisites before invoking it.
install_runtime_dependencies

# -e avoids an optional language-pack prompt; -n avoids the old interface,
# firewall and full-network-restart branch in the upstream installer.
sh "$INSTALLER" -e -n

# WARP Auto extends the current JavaScript protocol package. Do not install an
# incompatible overlay on legacy releases that only provide luci-app-amneziawg.
package_installed luci-proto-amneziawg || {
	echo 'This WARP Auto release requires luci-proto-amneziawg (a current supported OpenWrt release).' >&2
	exit 1
}

echo 'AmneziaWG base stack and WARP Auto runtime dependencies are installed.'

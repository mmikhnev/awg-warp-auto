#!/bin/sh
# Clean uninstaller for WARP Auto
# Preserves network interfaces, Forkop, and global configurations
set -eu

case "$(id -u)" in
	0) ;;
	*) echo "ERROR: Run as root on the OpenWrt router." >&2; exit 1 ;;
esac

echo "=== Stopping and Disabling WARP Auto Service ==="
/etc/init.d/awg-warp-auto stop 2>/dev/null || true
/etc/init.d/awg-warp-auto disable 2>/dev/null || true

echo "=== Removing Application Files ==="
rm -rf /usr/libexec/awg-warp-auto
rm -f /etc/init.d/awg-warp-auto
rm -f /usr/share/rpcd/ucode/luci.amneziawg
rm -f /usr/share/ucode/luci/controller/awgdownload.uc
rm -f /usr/share/rpcd/acl.d/luci-amneziawg.json
rm -f /usr/share/luci/menu.d/luci-proto-amneziawg.json
rm -f /www/luci-static/resources/view/amneziawg/status.js
rm -f /usr/bin/quic-i1

echo "Preserving /etc/config/awg-warp-auto and /etc/awg-warp-auto/ as backup..."
if [ -d /etc/awg-warp-auto ]; then
	mv /etc/awg-warp-auto "/etc/awg-warp-auto.uninstalled.$(date +%s)"
fi
if [ -f /etc/config/awg-warp-auto ]; then
	mv /etc/config/awg-warp-auto "/etc/config/awg-warp-auto.uninstalled.$(date +%s)"
fi

# Clear LuCI cache and restart rpcd
rm -f /tmp/luci-indexcache 2>/dev/null || true
/etc/init.d/rpcd restart 2>/dev/null || true

echo "WARP Auto uninstalled successfully."

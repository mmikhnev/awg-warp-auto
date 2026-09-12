#!/bin/sh
# Safe upgrade script for WARP Auto
# Preserves UCI configuration, profile pool, active profile and keys.
set -eu

case "$(id -u)" in
	0) ;;
	*) echo "ERROR: Run as root on the OpenWrt router." >&2; exit 1 ;;
esac

BASE_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
BACKUP_DIR="/root/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_ARCHIVE="$BACKUP_DIR/warp_auto_pre_upgrade_${TIMESTAMP}.tar.gz"

echo "=== 1. Creating Pre-Upgrade Backup ==="
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

tar -czf "$BACKUP_ARCHIVE" \
	/etc/config/awg-warp-auto \
	/etc/awg-warp-auto \
	/usr/libexec/awg-warp-auto \
	/usr/share/rpcd/ucode/luci.amneziawg \
	/usr/share/ucode/luci/controller/awgdownload.uc \
	/usr/share/rpcd/acl.d/luci-amneziawg.json \
	/usr/share/luci/menu.d/luci-proto-amneziawg.json \
	/www/luci-static/resources/view/amneziawg/status.js \
	/usr/bin/quic-i1 \
	2>/dev/null || true

ln -sfn "$BACKUP_ARCHIVE" "$BACKUP_DIR/latest.tar.gz"
echo "Backup saved to: $BACKUP_ARCHIVE"

rollback() {
	echo "ERROR OCCURRED! Rolling back from $BACKUP_ARCHIVE..." >&2
	tar -xzf "$BACKUP_ARCHIVE" -C /
	/etc/init.d/rpcd restart 2>/dev/null || true
	/etc/init.d/awg-warp-auto restart 2>/dev/null || true
	echo "Rollback complete." >&2
	exit 1
}

trap rollback ERR

echo "=== 2. Applying Application Upgrade ==="
# Preserve pool and uci config
TEMP_RESTORE=$(mktemp -d /tmp/upgrade-save.XXXXXX)
if [ -d /etc/awg-warp-auto/pool ]; then
	cp -r /etc/awg-warp-auto "$TEMP_RESTORE/"
fi
if [ -f /etc/config/awg-warp-auto ]; then
	cp /etc/config/awg-warp-auto "$TEMP_RESTORE/awg-warp-auto.uci"
fi

# Run install.sh to update packages and files
sh "$BASE_DIR/install.sh"

# Restore preserved pool and config
if [ -d "$TEMP_RESTORE/awg-warp-auto" ]; then
	cp -r "$TEMP_RESTORE/awg-warp-auto/"* /etc/awg-warp-auto/
fi
if [ -f "$TEMP_RESTORE/awg-warp-auto.uci" ]; then
	cp "$TEMP_RESTORE/awg-warp-auto.uci" /etc/config/awg-warp-auto
fi
rm -rf "$TEMP_RESTORE"

# Reload services cleanly
/etc/init.d/rpcd restart
/etc/init.d/awg-warp-auto restart

trap - ERR
echo "=== Upgrade completed successfully! ==="

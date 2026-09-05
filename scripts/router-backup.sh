#!/bin/sh
# Backup script for WARP Auto and relevant network configs on the OpenWrt router.
# Safely archives configuration and executables without touching Forkop or stopping services.
set -eu

ROUTER_HOST=${1:-"192.168.10.1"}
ROUTER_USER=${2:-"root"}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="awg_backup_${TIMESTAMP}.tar.gz"

echo "=== Taking remote backup on $ROUTER_USER@$ROUTER_HOST ==="
ssh -o BatchMode=yes "$ROUTER_USER@$ROUTER_HOST" "
	set -eu
	BACKUP_DIR='/root/backups'
	mkdir -p \"\$BACKUP_DIR\"
	chmod 700 \"\$BACKUP_DIR\"
	TARGET=\"\$BACKUP_DIR/$BACKUP_NAME\"

	# Collect all relevant files if they exist
	tar -czf \"\$TARGET\" \
		/etc/config/awg-warp-auto \
		/etc/config/network \
		/etc/awg-warp-auto \
		/usr/libexec/awg-warp-auto \
		/usr/share/rpcd/ucode/luci.amneziawg \
		/usr/share/ucode/luci/controller/awgdownload.uc \
		/usr/share/rpcd/acl.d/luci-amneziawg.json \
		/usr/share/luci/menu.d/luci-proto-amneziawg.json \
		/www/luci-static/resources/view/amneziawg/status.js \
		2>/dev/null || true

	# Maintain a symlink to the latest backup
	ln -sfn \"\$TARGET\" \"\$BACKUP_DIR/latest.tar.gz\"
	echo \"Backup created successfully: \$TARGET\"
	ls -lh \"\$TARGET\"
"
echo "=== Backup completed: $BACKUP_NAME ==="

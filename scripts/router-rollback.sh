#!/bin/sh
# Rollback script for WARP Auto on the OpenWrt router.
# Safely restores files from an archive and restarts only rpcd and awg-warp-auto.
# NEVER touches Forkop or restarts the entire network stack.
set -eu

ROUTER_HOST=${1:-"192.168.10.1"}
ROUTER_USER=${2:-"root"}
BACKUP_ARCHIVE=${3:-"latest.tar.gz"}

echo "=== Rolling back on $ROUTER_USER@$ROUTER_HOST using $BACKUP_ARCHIVE ==="
ssh -o BatchMode=yes "$ROUTER_USER@$ROUTER_HOST" "
	set -eu
	BACKUP_DIR='/root/backups'
	if [ -f \"\$BACKUP_DIR/$BACKUP_ARCHIVE\" ]; then
		FILE=\"\$BACKUP_DIR/$BACKUP_ARCHIVE\"
	elif [ -f \"$BACKUP_ARCHIVE\" ]; then
		FILE=\"$BACKUP_ARCHIVE\"
	else
		echo \"ERROR: Backup archive not found!\" >&2
		exit 1
	fi

	echo \"Extracting \$FILE to root...\"
	tar -xzf \"\$FILE\" -C /

	echo \"Restarting rpcd...\"
	/etc/init.d/rpcd restart

	echo \"Restarting awg-warp-auto...\"
	/etc/init.d/awg-warp-auto restart

	echo \"Rollback successfully completed.\"
"

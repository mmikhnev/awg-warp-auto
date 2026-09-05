#!/bin/sh
# Deploy script for WARP Auto updates to the OpenWrt router.
# Safely updates files and restarts ONLY rpcd and awg-warp-auto.
# NEVER touches Forkop or restarts global network services.
set -eu

ROUTER_HOST=${1:-"192.168.10.1"}
ROUTER_USER=${2:-"root"}
BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SRC="$BASE_DIR/source/luci-proto-amneziawg"

echo "=== 1. Checking local syntax and tests ==="
if command -v node >/dev/null 2>&1; then
	node --check "$SRC/htdocs/luci-static/resources/view/amneziawg/status.js"
	echo "JS syntax check passed."
fi

sh "$SRC/tests/provider-pool-test.sh"
if [ -f "$SRC/tests/extended-integration-test.sh" ]; then
	sh "$SRC/tests/extended-integration-test.sh"
fi
echo "Local tests passed."

echo "=== 2. Creating backup on router before deployment ==="
sh "$BASE_DIR/scripts/router-backup.sh" "$ROUTER_HOST" "$ROUTER_USER"

echo "=== 3. Uploading updated files to router ==="
scp -O -o BatchMode=yes \
	"$SRC/htdocs/luci-static/resources/view/amneziawg/status.js" \
	"$ROUTER_USER@$ROUTER_HOST:/www/luci-static/resources/view/amneziawg/status.js"

scp -O -o BatchMode=yes \
	"$SRC/root/usr/share/rpcd/ucode/luci.amneziawg" \
	"$ROUTER_USER@$ROUTER_HOST:/usr/share/rpcd/ucode/luci.amneziawg"

scp -O -o BatchMode=yes \
	"$SRC/root/usr/libexec/awg-warp-auto/daemon.sh" \
	"$SRC/root/usr/libexec/awg-warp-auto/candidate-test.sh" \
	"$SRC/root/usr/libexec/awg-warp-auto/health-check.sh" \
	"$SRC/root/usr/libexec/awg-warp-auto/native-provider.sh" \
	"$SRC/root/usr/libexec/awg-warp-auto/provider-fetch.sh" \
	"$ROUTER_USER@$ROUTER_HOST:/usr/libexec/awg-warp-auto/"

echo "=== 4. Setting permissions and reloading services ==="
ssh -o BatchMode=yes "$ROUTER_USER@$ROUTER_HOST" "
	chmod 644 /www/luci-static/resources/view/amneziawg/status.js
	chmod 644 /usr/share/rpcd/ucode/luci.amneziawg
	chmod 755 /usr/libexec/awg-warp-auto/*.sh

	# Clean LuCI bytecode / cache if present
	rm -f /tmp/luci-indexcache 2>/dev/null || true

	# Restart ONLY rpcd (for RPC ucode) and awg-warp-auto (for pool coordinator)
	echo 'Restarting rpcd...'
	/etc/init.d/rpcd restart

	echo 'Restarting awg-warp-auto...'
	/etc/init.d/awg-warp-auto restart
"

echo "=== 5. Verifying router status ==="
sleep 2
ssh -o BatchMode=yes "$ROUTER_USER@$ROUTER_HOST" "
	ubus call luci.amneziawg getWarpAutoStatus > /tmp/warp_status.json
	grep -Eq '\"ok\"[[:space:]]*:[[:space:]]*true' /tmp/warp_status.json && echo 'SUCCESS: getWarpAutoStatus returned ok:true' || {
		echo 'ERROR: getWarpAutoStatus check failed!' >&2
		cat /tmp/warp_status.json
		exit 1
	}
	rm -f /tmp/warp_status.json
"

echo "=== Deployment finished successfully! ==="

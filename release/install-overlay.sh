#!/bin/sh
# Installs only the WARP Auto LuCI overlay. It never replaces any interface,
# warp90_peer, Forkop, or an existing /etc/config/awg-warp-auto.
set -eu

case "$(id -u)" in
	0) ;;
	*) echo 'Run as root on the OpenWrt router.' >&2; exit 1 ;;
esac

BASE_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
OVERLAY="$BASE_DIR/overlay"

[ -f "$OVERLAY/usr/share/rpcd/ucode/luci.amneziawg" ] || {
	echo 'overlay directory is missing or incomplete.' >&2
	exit 1
}

package_installed() {
	package_name=$1
	if command -v apk >/dev/null 2>&1; then
		apk info -e "$package_name" >/dev/null 2>&1
	else
		opkg list-installed 2>/dev/null | grep -q "^${package_name} "
	fi
}

missing=''
for command_name in awg curl ucode resolveip jsonfilter; do
	command -v "$command_name" >/dev/null 2>&1 || missing="$missing $command_name"
done
[ -e /lib/netifd/proto/amneziawg.sh ] || missing="$missing amneziawg-netifd-protocol"
[ -r /etc/ssl/certs/ca-certificates.crt ] || missing="$missing ca-bundle"
package_installed luci-proto-amneziawg || missing="$missing luci-proto-amneziawg"
package_installed luci-lib-uqr || missing="$missing luci-lib-uqr"
[ -z "$missing" ] || {
	echo "Missing prerequisites:$missing" >&2
	echo 'Install the base AmneziaWG package first; see README.md.' >&2
	exit 1
}

copy_file() {
	path=$1
	mode=$2
	mkdir -p "$(dirname "/$path")"
	cp "$OVERLAY/$path" "/$path"
	chmod "$mode" "/$path"
}

copy_file usr/share/rpcd/ucode/luci.amneziawg 644
copy_file usr/share/ucode/luci/controller/awgdownload.uc 644
copy_file usr/share/rpcd/acl.d/luci-amneziawg.json 644
copy_file usr/share/luci/menu.d/luci-proto-amneziawg.json 644
copy_file www/luci-static/resources/view/amneziawg/status.js 644
copy_file usr/libexec/awg-warp-auto/daemon.sh 755
copy_file usr/libexec/awg-warp-auto/candidate-test.sh 755
copy_file usr/libexec/awg-warp-auto/health-check.sh 755
copy_file usr/libexec/awg-warp-auto/warp-gen-fetch.uc 644
copy_file usr/libexec/awg-warp-auto/warp-gen-provider.uc 644
copy_file usr/libexec/awg-warp-auto/provider-fetch.sh 755
copy_file usr/libexec/awg-warp-auto/native-provider.sh 755
copy_file etc/init.d/awg-warp-auto 755

if [ ! -e /etc/config/awg-warp-auto ]; then
	copy_file etc/config/awg-warp-auto 600
	installed_config=1
else
	installed_config=0
fi

/etc/init.d/rpcd restart
if [ "$installed_config" = 1 ]; then
	/etc/init.d/awg-warp-auto enable
fi
/etc/init.d/awg-warp-auto restart

echo 'WARP Auto overlay installed.'
echo 'Open Services -> AmneziaWG, configure the source URL if needed, then enable WARP Auto.'
echo 'Existing AWG/Forkop/YT2 configuration was not changed.'

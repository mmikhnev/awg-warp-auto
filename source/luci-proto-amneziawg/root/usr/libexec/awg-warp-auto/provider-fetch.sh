#!/bin/sh
# Provider contract: private config files + metadata JSON, never key material.
set -eu
RUNTIME=/usr/libexec/awg-warp-auto
OUT=/tmp/awg-warp-auto/generated
provider=${1:-remote}
limit=${2:-2}
case "$limit" in ''|*[!0-9]*) exit 2 ;; esac
[ "$limit" -ge 1 ] && [ "$limit" -le 10 ] || exit 2
umask 077
mkdir -p "$OUT"
case "$provider" in
remote)
	ln -sf warp-gen-provider.uc "$RUNTIME/warpgen.uc"
	source=$(uci -q get awg-warp-auto.main.source_url || true)
	awg_ver=$(uci -q get awg-warp-auto.main.awg_version || echo "v3_hybrid")
	exec ucode -L "$RUNTIME" -l warpgen=warpgen -D "outdir=$OUT" -D "source_url=$source" -D timeout=12 -D "limit=$limit" -D include_ipv6=1 -D "awg_version=$awg_ver" "$RUNTIME/warp-gen-fetch.uc"
	;;
native)
	# The coordinator owns the registration budget and commits its reservation
	# before calling us. One invocation registers exactly one independent device.
	endpoint=${3:-}
	sni=$(uci -q get awg-warp-auto.main.native_sni || true)
	quic_mode=$(uci -q get awg-warp-auto.main.native_quic_mode || echo "dynamic")
	awg_ver=$(uci -q get awg-warp-auto.main.awg_version || echo "v3_hybrid")
	path="$OUT/generated-native-$$.conf"
	meta="${path%.conf}.meta.json"
	ret=0
	"$RUNTIME/native-provider.sh" "$path" "$endpoint" "$sni" "$quic_mode" "$awg_ver" >/dev/null 2>&1 || ret=$?
	if [ "$ret" -eq 0 ]; then
		if [ -r "$meta" ]; then
			v4_val=$(jsonfilter -i "$meta" -e '@.v4')
			ports_arr=$(jsonfilter -i "$meta" -e '@.ports')
			cands_arr=$(jsonfilter -i "$meta" -e '@.candidates')
			rm -f "$meta"
			printf '{"ok":true,"provider":"native","v4":"%s","ports":%s,"candidates":%s,"configs":[{"path":"%s","profile":"WARP_native"}]}\n' \
				"$v4_val" "${ports_arr:-[]}" "${cands_arr:-[]}" "$path"
		else
			printf '{"ok":true,"provider":"native","configs":[{"path":"%s","profile":"WARP_native"}]}\n' "$path"
		fi
	else
		rm -f "$path"
		if [ -r "$meta" ] && [ "$(jsonfilter -i "$meta" -e '@.rate_limited' 2>/dev/null)" = "true" ]; then
			retry_after=$(jsonfilter -i "$meta" -e '@.retry_after' 2>/dev/null || echo 300)
			rm -f "$meta"
			printf '{"ok":false,"rate_limited":true,"retry_after":%d,"error":{"code":"REGISTRATION_RATE_LIMITED"}}\n' "$retry_after"
			exit 2
		fi
		rm -f "$meta"
		printf '{"ok":false,"error":{"code":"NATIVE_REGISTRATION_FAILED"}}\n'
		exit 1
	fi
	;;
*) printf '{"ok":false,"error":{"code":"UNKNOWN_PROVIDER"}}\n'; exit 2 ;;
esac

#!/bin/sh
# Provider contract: private config files + metadata JSON, never key material.
set -eu
RUNTIME=/usr/libexec/awg-warp-auto
OUT=/tmp/awg-warp-auto/generated
provider=${1:-remote}
limit=${2:-2}
case "$limit" in ''|*[!0-9]*) exit 2 ;; esac
[ "$limit" -ge 1 ] && [ "$limit" -le 8 ] || exit 2
umask 077
mkdir -p "$OUT"
case "$provider" in
remote)
	ln -sf warp-gen-provider.uc "$RUNTIME/warpgen.uc"
	source=$(uci -q get awg-warp-auto.main.source_url || true)
	exec ucode -L "$RUNTIME" -l warpgen=warpgen -D "outdir=$OUT" -D "source_url=$source" -D timeout=12 -D "limit=$limit" -D include_ipv6=1 "$RUNTIME/warp-gen-fetch.uc"
	;;
native)
	# The coordinator owns the registration budget and commits its reservation
	# before calling us. One invocation registers exactly one independent device.
	endpoint=${3:-}
	sni=$(uci -q get awg-warp-auto.main.native_sni || true)
	quic_mode=$(uci -q get awg-warp-auto.main.native_quic_mode || true)
	path="$OUT/generated-native-$$.conf"
	if "$RUNTIME/native-provider.sh" "$path" "$endpoint" "$sni" "$quic_mode" >/dev/null 2>&1; then
		printf '{"ok":true,"provider":"native","configs":[{"path":"%s","profile":"WARP_native"}]}\n' "$path"
	else
		rm -f "$path"
		printf '{"ok":false,"error":{"code":"NATIVE_REGISTRATION_FAILED"}}\n'
		exit 1
	fi
	;;
*) printf '{"ok":false,"error":{"code":"UNKNOWN_PROVIDER"}}\n'; exit 2 ;;
esac

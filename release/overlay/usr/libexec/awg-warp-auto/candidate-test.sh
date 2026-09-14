#!/bin/sh

# A disposable, policy-routed AmneziaWG probe.  The caller has already passed
# the file through luci.amneziawg's single configuration parser; this script
# deliberately never stores, logs, or activates that file.
set -u

CONFIG=${1:-}
TIMEOUT=${2:-10}
LISTEN_PORT=${3:-51822}
RESOLVERS=${4:-}
DEV=awg_auto_probe
TABLE=51822
PRIO=31822
PROBE_MARK=0x01000000
TMP=/tmp/awg-warp-auto-probe.$$

fail() {
	logger -p user.warning -t awg-warp-auto "candidate probe failed: $1"
	echo "FAIL $1"
	exit 1
}

cleanup() {
	if ip -4 rule show priority "$PRIO" 2>/dev/null | grep -q "lookup $TABLE"; then
		ip rule del priority "$PRIO" 2>/dev/null || true
	fi
	ip route flush table "$TABLE" 2>/dev/null || true
	ip link del dev "$DEV" 2>/dev/null || true
	rm -f "$TMP"
}
trap cleanup EXIT INT TERM
# procd can interrupt a probe before its EXIT handler. Reclaim only our
# dedicated probe resources before testing the next candidate.
cleanup

case "$CONFIG" in
	/etc/awg-warp-auto/pool/p_*.conf|/tmp/awg-warp-auto/generated/*.conf) ;;
	*) fail invalid_path ;;
esac
case "$TIMEOUT" in
	*[!0-9]*|'') fail invalid_timeout ;;
esac
[ "$TIMEOUT" -ge 3 ] && [ "$TIMEOUT" -le 30 ] || fail invalid_timeout
[ "$LISTEN_PORT" -ge 1 ] && [ "$LISTEN_PORT" -le 65535 ] 2>/dev/null || fail invalid_port
[ -r "$CONFIG" ] || fail missing_config

# AWG understands the peer and obfuscation fields itself.  Only IP/DNS/MTU
# are netifd settings, so remove them from the temporary setconf input.
awk '
	BEGIN { section = "" }
	/^\[Interface\][[:space:]]*$/ { section = "interface"; print; next }
	/^\[Peer\][[:space:]]*$/ { section = "peer"; print; next }
	section == "interface" && $0 ~ /^[[:space:]]*(Address|DNS|MTU|ListenPort|FwMark)[[:space:]]*=/ { next }
	{ print }
' "$CONFIG" > "$TMP" || fail config_filter

ADDR4=$(awk -F= '
	BEGIN { IGNORECASE = 1 }
	/^[[:space:]]*Address[[:space:]]*=/ {
		v = $2; gsub(/[[:space:]]/, "", v); n = split(v, a, ",");
		for (i = 1; i <= n; i++) if (a[i] ~ /^[0-9.]+(\/[0-9]+)?$/) { sub(/\/.*/, "", a[i]); print a[i]; exit }
	}
' "$CONFIG")
[ -n "$ADDR4" ] || fail no_ipv4

ip link del dev "$DEV" 2>/dev/null || true
ip link add dev "$DEV" type amneziawg 2>/dev/null || fail link_create
awg setconf "$DEV" "$TMP" 2>/dev/null || fail setconf
# Never inherit selected-interface policy marks. The outer AWG UDP socket must
# leave through WAN; reusing YTwarp's mark routes a probe through a broken
# active tunnel and makes every replacement look failed.
awg set "$DEV" fwmark "$PROBE_MARK" listen-port "$LISTEN_PORT" 2>/dev/null || fail fwmark
ip addr add "$ADDR4/32" dev "$DEV" 2>/dev/null || fail address
ip link set dev "$DEV" up || fail link_up
ip route replace default dev "$DEV" table "$TABLE" || fail route
# Generated WARP profiles commonly share the same tunnel address as the active
# profile. Route by the disposable output interface, never by that source IP,
# otherwise a probe temporarily hijacks active awg_warp traffic.
ip rule add oif "$DEV" priority "$PRIO" table "$TABLE" || fail rule

# Use a real public address instead of a possible Fake-IP returned by the
# local proxy DNS. A temporary block of one public resolver is not evidence
# that an otherwise healthy candidate is broken.
YT_IP=''
CF_SPEED_IP=''
resolvers_list=${RESOLVERS:-"1.1.1.1 8.8.8.8 9.9.9.9 77.88.8.8 77.88.8.1"}
for DNS in $resolvers_list; do
	[ -z "$YT_IP" ] && YT_IP=$(nslookup www.youtube.com "$DNS" 2>/dev/null | awk '
		/^Address [0-9]+: / { ip = $4; if (ip ~ /^[0-9.]+$/) { print ip; exit } }
		/^Address: / { ip = $2; if (ip ~ /^[0-9.]+$/) { print ip; exit } }
	')
	[ -z "$CF_SPEED_IP" ] && CF_SPEED_IP=$(nslookup speed.cloudflare.com "$DNS" 2>/dev/null | awk '
		/^Address [0-9]+: / { ip = $4; if (ip ~ /^[0-9.]+$/) { print ip; exit } }
		/^Address: / { ip = $2; if (ip ~ /^[0-9.]+$/) { print ip; exit } }
	')
	[ -n "$YT_IP" ] && [ -n "$CF_SPEED_IP" ] && break
done
[ -n "$YT_IP" ] || YT_IP='142.250.74.206'
[ -n "$CF_SPEED_IP" ] || CF_SPEED_IP='172.66.0.218'

BEFORE=$(awg show "$DEV" transfer 2>/dev/null | awk 'NR == 1 { print $2 ":" $3 }')
START=$(date +%s%3N 2>/dev/null || date +%s000)
CODE=$(curl -4 --noproxy '*' --interface "$DEV" --resolve "www.youtube.com:443:$YT_IP" \
	-L -sS -o /dev/null -w '%{http_code}' --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
	https://www.youtube.com/generate_204 2>/dev/null)
END=$(date +%s%3N 2>/dev/null || date +%s000)
AFTER=$(awg show "$DEV" transfer 2>/dev/null | awk 'NR == 1 { print $2 ":" $3 }')
HANDSHAKE=$(awg show "$DEV" latest-handshakes 2>/dev/null | awk 'NR == 1 { print $2 }')

case "$CODE" in 200|204) ;; *) fail "http_$CODE" ;; esac
[ -n "$HANDSHAKE" ] && [ "$HANDSHAKE" -gt 0 ] 2>/dev/null || fail handshake
[ -n "$BEFORE" ] && [ -n "$AFTER" ] && [ "$BEFORE" != "$AFTER" ] || fail transfer

LATENCY=$((END - START))
[ "$LATENCY" -ge 0 ] 2>/dev/null || LATENCY=0

# Fast download speed benchmark (25MB payload streamed directly to /dev/null, 0 disk/RAM space used)
SPEED_MBPS=0
SPEED_BPS=$(curl -4 --noproxy '*' --interface "$DEV" --resolve "speed.cloudflare.com:443:$CF_SPEED_IP" \
	-L -sS -o /dev/null -w '%{speed_download}' --connect-timeout 3 --max-time 12 \
	"https://speed.cloudflare.com/__down?bytes=25000000" 2>/dev/null | cut -d. -f1)
if [ -n "$SPEED_BPS" ] && [ "$SPEED_BPS" -gt 0 ] 2>/dev/null; then
	SPEED_MBPS=$(( SPEED_BPS / 125000 ))
fi

echo "OK $LATENCY $SPEED_MBPS"

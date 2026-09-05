#!/bin/sh

# Health of the active interface. "strict" additionally verifies the current
# policy/Forkop route; "direct" is for a fresh router before policy rules exist.
set -u

IFACE=${1:-awg_warp}
TIMEOUT=${2:-10}
RESOURCES=${3:-youtube.com}
MODE=${4:-strict}

case "$IFACE" in ''|[!A-Za-z]*|*[!A-Za-z0-9_]* ) echo 'FAIL interface'; exit 1 ;; esac
[ "${#IFACE}" -le 15 ] || { echo 'FAIL interface'; exit 1; }
case "$TIMEOUT" in *[!0-9]*|'') echo 'FAIL timeout'; exit 1 ;; esac
[ "$TIMEOUT" -ge 3 ] && [ "$TIMEOUT" -le 30 ] || { echo 'FAIL timeout'; exit 1; }
case "$MODE" in strict|direct) ;; *) echo 'FAIL mode'; exit 1 ;; esac

# route_allowed_ips stays disabled because Forkop owns normal policy routing.
# A socket bound to the AWG address therefore needs its own short-lived rule
# for the direct tunnel proof below, just like candidate-test.sh does.
PROBE_TABLE=51823
PROBE_PRIO=31823
ADDR4=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk 'NR == 1 { split($4, a, "/"); print a[1] }')
[ -n "$ADDR4" ] || { echo 'FAIL interface_address'; exit 1; }
cleanup() {
	ip rule del priority "$PROBE_PRIO" 2>/dev/null || true
	ip route flush table "$PROBE_TABLE" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
ip route replace default dev "$IFACE" table "$PROBE_TABLE" || { echo 'FAIL probe_route'; exit 1; }
ip rule add from "$ADDR4/32" priority "$PROBE_PRIO" table "$PROBE_TABLE" || { echo 'FAIL probe_rule'; exit 1; }

before=$(awg show "$IFACE" transfer 2>/dev/null | awk 'NR == 1 { print $2 ":" $3 }')
[ -n "$before" ] || { echo 'FAIL transfer_before'; exit 1; }
start=$(date +%s%3N 2>/dev/null || date +%s000)

oldifs=$IFS
IFS=,
set -- $RESOURCES
IFS=$oldifs
[ "$#" -gt 0 ] || { echo 'FAIL resources'; exit 1; }

global_result=''
if [ "$MODE" = strict ]; then
	# Forkop transparently handles forwarded LAN packets, not a process created
	# on the router itself. A router-local curl is therefore not evidence of a
	# client policy failure. Verify that the expected policy rule exists; the
	# interface-bound request below remains the end-to-end AWG proof.
	ip -4 rule show 2>/dev/null | grep -Eq 'fwmark 0x4000000(/0x4000000)? .*lookup forkop' || global_result='policy_rule'
fi

# Local proxy DNS can supply Fake-IP, so resolve a real public address for
# the interface-bound proof. This does not change DNS settings or routing.
yt_ip=$(nslookup www.youtube.com 1.1.1.1 2>/dev/null | awk '
	/^Address [0-9]+: / { ip = $4; if (ip ~ /^[0-9.]+$/) { print ip; exit } }
	/^Address: / { ip = $2; if (ip ~ /^[0-9.]+$/) { print ip; exit } }
')
[ -n "$yt_ip" ] || { echo 'FAIL direct_dns'; exit 1; }
direct_code=$(curl -4 --noproxy '*' --interface "$ADDR4" --resolve "www.youtube.com:443:$yt_ip" \
	-L -sS -o /dev/null -w '%{http_code}' --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
	https://www.youtube.com/generate_204 2>/dev/null)
case "$direct_code" in 200|204) ;; *) echo "FAIL ${global_result:-global_ok} direct_http_$direct_code"; exit 1 ;; esac
[ "$MODE" = direct ] || [ -z "$global_result" ] || { echo "FAIL $global_result direct_ok"; exit 1; }

end=$(date +%s%3N 2>/dev/null || date +%s000)
after=$(awg show "$IFACE" transfer 2>/dev/null | awk 'NR == 1 { print $2 ":" $3 }')
handshake=$(awg show "$IFACE" latest-handshakes 2>/dev/null | awk 'NR == 1 { print $2 }')
[ -n "$handshake" ] && [ "$handshake" -gt 0 ] 2>/dev/null || { echo 'FAIL handshake'; exit 1; }
[ "$before" != "$after" ] || { echo 'FAIL transfer'; exit 1; }
latency=$((end - start))
[ "$latency" -ge 0 ] 2>/dev/null || latency=0
echo "OK $latency"

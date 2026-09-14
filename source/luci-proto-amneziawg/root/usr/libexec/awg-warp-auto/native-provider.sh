#!/bin/sh
# Native Cloudflare WARP registrar. Writes one strict AWG profile to $1.
# No remote generator, JavaScript, or external I1 service is used.
set -eu

out=${1:?output path required}
explicit_endpoint=${2:-}
endpoint=''
sni=${3:-}
quic_mode=${4:-dynamic}
awg_version=${5:-v3_hybrid}
tmp=${out}.json
meta=${out%.conf}.meta.json
umask 077
tmp_hdr=${out}.hdr
trap 'rm -f "$tmp" "$tmp_hdr"' EXIT

parse_retry_after() {
	awk -F: '
		BEGIN { IGNORECASE = 1 }
		/^[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:/ {
			gsub(/[^0-9]/, "", $2)
			if ($2 != "") {
				print $2
				exit
			}
		}
	' "$tmp_hdr" 2>/dev/null || true
}

key=$(awg genkey)
pub=$(printf '%s' "$key" | awg pubkey)
tos=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
body=$(printf '{"install_id":"","tos":"%s","key":"%s","fcm_token":"","type":"ios","locale":"en_US"}' "$tos" "$pub")
base='https://api.cloudflareclient.com/v0i1909051800/reg'

# Use direct Cloudflare Anycast IPs to bypass any DNS block, timeout, or Fake-IP
cf_curl() {
	local out_file=$1
	shift
	rm -f "$tmp_hdr"
	local code
	code=$(curl -sS -k -D "$tmp_hdr" -o "$out_file" -w '%{http_code}' --connect-timeout 8 --max-time 15 \
		-A 'okhttp/3.12.1' -H 'Content-Type: application/json' \
		--resolve api.cloudflareclient.com:443:162.159.192.1 "$@" 2>/dev/null || true)
	code=$(printf '%s' "$code" | tail -c 3)
	case "$code" in
		000|'')
			rm -f "$tmp_hdr"
			code=$(curl -sS -k -D "$tmp_hdr" -o "$out_file" -w '%{http_code}' --connect-timeout 8 --max-time 15 \
				-A 'okhttp/3.12.1' -H 'Content-Type: application/json' \
				--resolve api.cloudflareclient.com:443:162.159.193.1 "$@" 2>/dev/null || true)
			code=$(printf '%s' "$code" | tail -c 3)
			;;
	esac
	printf '%s' "$code"
}

http_code=$(cf_curl "$tmp" -d "$body" "$base")

if [ "$http_code" = "429" ]; then
	ra=$(parse_retry_after)
	case "$ra" in ''|*[!0-9]*) ra=300 ;; esac
	[ "$ra" -ge 60 ] 2>/dev/null || ra=60
	[ "$ra" -le 86400 ] 2>/dev/null || ra=86400
	logger -p user.warn -t awg-warp-auto "native registration rate-limited (HTTP 429), retry after ${ra}s"
	cat > "$meta" <<EOF
{
  "rate_limited": true,
  "retry_after": $ra
}
EOF
	exit 2
fi

[ "$http_code" -ge 200 ] 2>/dev/null && [ "$http_code" -lt 300 ] 2>/dev/null || exit 1

id=$(jsonfilter -i "$tmp" -e '@.result.id')
token=$(jsonfilter -i "$tmp" -e '@.result.token')
[ -n "$id" ] && [ -n "$token" ] || exit 1

http_code=$(cf_curl "$tmp" -H "Authorization: Bearer $token" -X PATCH -d '{"warp_enabled":true}' "$base/$id")

if [ "$http_code" = "429" ]; then
	ra=$(parse_retry_after)
	case "$ra" in ''|*[!0-9]*) ra=300 ;; esac
	[ "$ra" -ge 60 ] 2>/dev/null || ra=60
	[ "$ra" -le 86400 ] 2>/dev/null || ra=86400
	logger -p user.warn -t awg-warp-auto "native registration rate-limited (HTTP 429) during PATCH, retry after ${ra}s"
	cat > "$meta" <<EOF
{
  "rate_limited": true,
  "retry_after": $ra
}
EOF
	exit 2
fi

[ "$http_code" -ge 200 ] 2>/dev/null && [ "$http_code" -lt 300 ] 2>/dev/null || exit 1
peer=$(jsonfilter -i "$tmp" -e '@.result.config.peers[0].public_key')
v4=$(jsonfilter -i "$tmp" -e '@.result.config.interface.addresses.v4')
v6=$(jsonfilter -i "$tmp" -e '@.result.config.interface.addresses.v6')
raw_v4=$(jsonfilter -i "$tmp" -e '@.result.config.peers[0].endpoint.v4')
ports=$(jsonfilter -i "$tmp" -e '@.result.config.peers[0].endpoint.ports[*]')

[ -n "$peer" ] && [ -n "$v4" ] || exit 1

# Extract numeric IPv4 and strip trailing port (e.g. 162.159.192.4:0 -> 162.159.192.4)
v4_ip=${raw_v4%:*}
case "$v4_ip" in
	198.18.*|198.19.*)
		logger -p user.err -t awg-warp-auto "native registration rejected Fake-IP endpoint: $v4_ip"
		exit 1
		;;
	*[!0-9.]*|'')
		logger -p user.err -t awg-warp-auto "native registration response missing usable numeric IPv4: $raw_v4"
		exit 1
		;;
esac

# Validate IPv4 octets
o1=$(printf '%s' "$v4_ip" | cut -d. -f1)
o2=$(printf '%s' "$v4_ip" | cut -d. -f2)
o3=$(printf '%s' "$v4_ip" | cut -d. -f3)
o4=$(printf '%s' "$v4_ip" | cut -d. -f4)
[ -n "$o1" ] && [ -n "$o2" ] && [ -n "$o3" ] && [ -n "$o4" ] || exit 1
[ "$o1" -ge 0 ] 2>/dev/null && [ "$o1" -le 255 ] 2>/dev/null || exit 1
[ "$o2" -ge 0 ] 2>/dev/null && [ "$o2" -le 255 ] 2>/dev/null || exit 1
[ "$o3" -ge 0 ] 2>/dev/null && [ "$o3" -le 255 ] 2>/dev/null || exit 1
[ "$o4" -ge 0 ] 2>/dev/null && [ "$o4" -le 255 ] 2>/dev/null || exit 1

# Prioritize ports: 500 -> 1701 -> 4500 -> arbitrary -> 2408, with deduplication
sort_ports() {
	printf '%s\n' "$1" | awk '
	{
		for (i = 1; i <= NF; i++) {
			p = $i
			if (p !~ /^[0-9]+$/ || p < 1 || p > 65535 || seen[p]++) continue
			if (p == 500) prio = 10
			else if (p == 1701) prio = 20
			else if (p == 4500) prio = 30
			else if (p == 2408) prio = 90
			else prio = 40
			print prio, i, p
		}
	}' | sort -k1,1n -k2,2n | awk '{printf "%s%s", (NR>1 ? " " : ""), $3} END {print ""}'
}

valid_ports=$(sort_ports "$ports")
if [ -z "$valid_ports" ]; then
	logger -p user.err -t awg-warp-auto "native registration response missing usable ports"
	exit 1
fi

first_port=$(printf '%s' "$valid_ports" | awk '{print $1}')

if [ -n "$explicit_endpoint" ]; then
	case "$explicit_endpoint" in
		198.18.*|198.19.*)
			logger -p user.err -t awg-warp-auto "explicit endpoint is Fake-IP: $explicit_endpoint"
			exit 1
			;;
		*:[0-9]*)
			ep_port=${explicit_endpoint##*:}
			[ "$ep_port" -ge 1 ] 2>/dev/null && [ "$ep_port" -le 65535 ] 2>/dev/null || exit 1
			endpoint="$explicit_endpoint"
			candidates="$explicit_endpoint"
			;;
		*) exit 1 ;;
	esac
else
	# Fast Cloudflare Anycast subnets and ports for latency and block evasion
	rnd_anycast_candidates() {
		# 1. Registered endpoint from Cloudflare API
		echo "${v4_ip}:${first_port}"

		# 2. Regional Anycast IPs dynamically resolved from client's ISP
		local resolved_ips
		resolved_ips=$(nslookup engage.cloudflareclient.com 2>/dev/null | awk '/^Address:|^Address [0-9]+:/ { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $i !~ /^198\.18\./ && $i !~ /^198\.19\./) print $i }' | head -n 4 || true)
		for rip in $resolved_ips; do
			echo "${rip}:${first_port}"
			echo "${rip}:500"
			echo "${rip}:1701"
			echo "${rip}:4500"
		done

		# 3. Random hosts across verified fast Cloudflare Anycast subnets
		local prefixes="188.114.97. 162.159.195. 8.6.112. 162.159.192. 188.114.96. 162.159.193."
		local fast_ports="1070 2408 1701 7559 500 854 880 4500"
		for pfx in $prefixes; do
			rh=$(hexdump -n 2 -e '/2 "%u"' /dev/urandom 2>/dev/null || echo 1)
			h_num=$(( (rh % 15) + 1 ))
			for p in $fast_ports; do
				echo "${pfx}${h_num}:${p}"
			done
		done
	}
	candidates=$(rnd_anycast_candidates | awk 'BEGIN{srand()} {print rand(), $0}' | sort -k1,1n | cut -d' ' -f2 | head -n 15 | tr '\n' ' ' | sed 's/[[:space:]]*$//')
	endpoint=$(printf '%s\n' "$candidates" | awk '{print $1}')
fi

logger -p user.notice -t awg-warp-auto "native registration: endpoint=$endpoint candidates=$candidates"

# Write metadata companion file for provider-fetch
ports_json=$(printf '%s' "$valid_ports" | sed 's/ /,/g')
candidates_json=$(for c in $candidates; do printf '"%s",' "$c"; done | sed 's/,$//')
cat > "$meta" <<EOF
{
  "v4": "$v4_ip",
  "ports": [$ports_json],
  "candidates": [$candidates_json]
}
EOF

# Compatibility preset fallback if quic-i1 fails, is missing, or SNI invalid.
fallback_i1=$(printf '%s' 'STEgPSA8YiAweGNlMDAwMDAwMDEwODk3YTI5N2VjYzM0Y2Q2ZGQwMDAwNDRkMGVjMmUyZTFlYTI5OTFmNDY3YWNlNDIyMjEyOWI1YTA5ODgyMzc4NDY5NGI0ODk3Yjk5ODZhZTBiNzI4MDEzNWZhODVlMTk2ZDlhZDk4MGIxNTAxMjIxMjljZTJhOTM3OTUzMWIwZmQzZTg3MWNhNWZkYjg4M2MzNjk4MzJmNzMwZTI3MmQ3YjhiNzRmMzkzZjlmMGZhNDNmMTFlNTEwZWNiMjIxOWE1Mjk4NDQxMGMyMDRjZjg3NTU4NTM0MGM2MjIzOGUxNGFkMDRkZmYzODJmMmMyMDBlMGVlMjJmZTc0M2I5YzZiOGIwNDMxMjFjNTcxMGVjMjg5ZjQ3MWM5MWVlNDE0ZmNhOGI4YmU4NDE5YWU4Y2U3ZmZjNTM4MzdmNmFkZTI2Mjg5MTg5NWYzZjRjZWNkMzFiYzkzYWM1NTk5ZTE4ZTRmMDFiNDcyMzYyYjgwNTZjMzE3MmI1MTMwNTFmODMyMmQxMDYyOTk3ZWY0YTM4M2IwMTcwNjU5OGQwOGQ0OGMyMjFkMzBlNzRjN2NlMDAwY2RhZDM2YjcwNmIxYmY5YjA2MDdjMzJlYzRiMzIwM2E0ZWUyMWFiNjRkZjMzNjIxMmI5NzU4MjgwODAzZmNhYjE0OTMzYjBlN2VlMWUwNGE3YmVjY2UzZTI2MzNmNDg1MjU4NWM1Njc4OTRhNWY5ZWZlOTcwNmExNTFiNjE1ODU2NjQ3ZThiN2RiYTY5YWIzNTdiMzk4MmY1NTQ1NDliZWY5MjU2MTExYjJkNjdhZmRlMGI0OTZmMTY5NjJkNDk1N2ZmNjU0MjMyYWE5ZTg0NWI2MTQ2MzkwODMwOWNmZDlkZTBhNmFiZjVmNDI1ZjU3N2Q3ZTVmNjQ0MDY1MmFhOGRhNWY3MzU4OGU4MmU5NDcwZjNiMjFiMjdiMjhjNjQ5NTA2YWUxYTdmNWYxNWI4NzZmNTZhYmM0NjE1ZjQ5OTExNTQ5YjliYjM5ZGQ4MDRmZGUxODJiZDJkY2VjMGMzM2JhZDliMTM4Y2EwN2Q0YTRhMTY1MGEyYzI2ODZhY2VhMDU3MjdlMmE3ODk2MmE4NDBhZTQyOGY1NTYyNzUxNmU3M2M4M2RkODg5M2IwMjM1OGU4MWI1MjRiNGQ5OWZkYTZkZjUyYjNhOGQ3YTUyOTEzMjZlN2FjOWQ3NzNjNWI0M2I4NDQ0NTU0ZWY1YWVhMTA0YTczOGVkNjUwYWE5Nzk2NzRiYmVkMzhkYTU4YWMyOWQ4N2MyOWQzODdkODBiNTI2MDY1YmFlYjA3M2NlNjVmMDc1Y2NiNTZlNDc1MzNhZWYzNTdkY2VhYTgyOTNhNTIzYzVmNmY3OTBiZTkwZTQ3MzExMjNkM2M2MTUyYTcwNTc2ZTkwYjRhYjViYzVlYWQwMTU3NmM2OGFiNjMzZmY3ZDM2ZGNkZTJhMGIyYzY4ODk3ZTFhY2ZjNGQ2NDgzYWFhZWI2MzVkZDYzYzk2YjJiNmE3YTJiZmUwNDJmNmFlZDgyZTUzNjNhYTg1MGFhY2UxMmVlM2IxYTkzZjMwZDhhYjk1MzdkZjQ4MzE1MmE1NTI3ZmFjYTIxZWZjOTk4MWIzMDRmMTFmYzk1MzM2ZjViOTYzN2IxNzRjNWEwNjU5ZTJiMjJlMTU5YTlmZWQ0YjhlOTMwNDczNzExNzViMWQ2ZDljYzhhYjc0NWYzYjIyODE1MzdkMWM3NWZiOTQ1MTg3MTg2NGVmYTVkMTg0YzM4YzE4NWZkMjAzZGUyMDY3NTFiOTI2MjBmN2MzNjllMDMxZDIwNDFlMTUyMDQwOTIwYWMyYzVhYjUzNDBiZmM5ZDA1NjExNzZhYmYxMGExNDcyODdlYTkwNzU4NTc1YWM2YTlmNWFjOWYzOTBkMGQ1YjIzZWUxMmFmNTgzMzgzZDk5NGUyMmMwY2Y0MjM4MzgzNGJjZDNhZGExYjM4MjVhMDY2NGQ4ZjNmYjY3ODI2MWQ1NzYwMWRkZjk0YThhNjhhN2MyNzNhMThjMDhhYTk5YzdhZDhjNmM0MmVhYjY3NzE4ODQzNTk3ZWM5OTMwNDU3MzU5ZGZkZmJjZTAyNGFmYzJkY2Y5MzQ4NTc5YTU3ZDhkMzQ5MGIyZmE5OWYyNzhmMWMzN2Q4N2RhZDliMjIxYWNkNTc1MTkyZmZhZTE3ODRmOGU2MGVjN2NlZTQwNjhiNmI5ODhmMDQzM2Q5NmQ2YTFiMTg2NWY0ZTE1NWU5ZmUwMjAyNzlmNDM0ZjNiZjFiZDExN2I3MTdiOTJmNmNkMWNjOWJlYTdkNDU5NzhiY2MzZjI0YmRhNjMxYTM2OTEwMTEwYTZlYzA2ZGEzNWY4OTY2YzkyNzlkMTMwMzQ3NTk0ZjEzZTllMDc1MTRmYTM3MDc1NGQxNDI0YzBhMTU0NWM1MDcwZWY5ZmIyYWNkMTQyMzNlOGE1MGJmYzU5NzhiNWJkZjhiYzE3MTQ3MzFmNzk4ZDIxZTIwMDQxMTdjNjFmMjk4OWRkNDRmMGNmMDI3YjI3ZDQwMTllODFlZDRiNWMzMWRiMzQ3YzRhM2E0ZDg1MDQ4ZDcwOTNjZjE2NzUzZDdiMGQxNWUwNzhmNWM3YTUyMDVkYzJmODdlMzMwYTFmNzE2NzM4ZGNlMWM2MTgwZTlkMDI4NjliNTU0NmYxYzRkMjc0OGY4YzkwZDk2OTNjYmE0ZTAwNzkyOTdkMjJmZDYxNDAyZGVhMzJmZjBlYjY5ZWJkNjVhNWQwYjY4N2Q4N2UzYThiMmM0MmI2NDhhYTcyM2M3YzdkYWYzN2FiY2M0YmI4NWNhZWEyZWU4ZjU1YmVjMjBlOTEzYjMzMjRhYjhmNWMzMzA0ZjgyMGQ0MmFkMWI5ZjJmZmMxYTNhZjk5MjcxMzZiNDQxOWUxZTU3OWFiNGMyYWUzYzc3NmQyOTNkMzk3ZDU3NWRmMTgxZTZjYWUwYTRhZGE1ZDY3ZWNlYTE3MWNjYTMyODhkNTdjN2JiZGFlZTNiZWZlNzQ1ZmI3ZDYzNGY3MDM4NmQ4NzNiOTBjNGQ2YzY1OTZiYjY1YWY2OGY5ZTUxMjFlNjdlYmYwZDg5ZDNjOTA5Y2VlZGZiMzJjZTk1NzVhNzc1OGZmMDgwNzI0ZTFhYjVkNWY0MzA3NGVjYjUzYTQ3OWFmMjFlZDAzZDdiNjg5OWMzNjYzMWMwMTY2ZjlkNDdlNWUxZDQ1MjhhNWQzZDNmNzQ0MDI5YzRiMWMxOTBjYmZiYWQwNmY1ZjgzZjdhZDA0MjlmYTlhMjcxOWM1NmZmZTM3ODM0NjBlMTY2ZGUyZDg+' | base64 -d)
i1="$fallback_i1"

# Primary path: dynamic local quic-i1 binary. Fallback path: compatibility preset.
if [ "$quic_mode" != fallback ]; then
	effective_sni=${sni:-w3.org}
	if command -v quic-i1 >/dev/null 2>&1 && printf '%s' "$effective_sni" | grep -Eq '^[A-Za-z0-9.-]{1,253}$'; then
		dynamic_i1=$(quic-i1 --sni "$effective_sni" 2>/dev/null || true)
		case "$dynamic_i1" in
			'I1 = <b 0x'*'>') i1="$dynamic_i1" ;;
			'<b 0x'*'>') i1="I1 = $dynamic_i1" ;;
			'I1 = <b 0x'*'<r 16>') i1="$dynamic_i1" ;;
			'<b 0x'*'<r 16>') i1="I1 = $dynamic_i1" ;;
			*)
				logger -p user.warn -t awg-warp-auto "quic-i1 generation failed or invalid for $effective_sni; using compatibility preset"
				;;
		esac
	else
		logger -p user.warn -t awg-warp-auto "quic-i1 helper unavailable or SNI '$sni' invalid; using compatibility preset"
	fi
fi

{
	printf '%s\n' '[Interface]' "PrivateKey = $key" "Address = $v4${v6:+, $v6}" 'MTU = 1280'
	printf '%s\n' 'S1 = 0' 'S2 = 0' 'S3 = 0' 'S4 = 0' 'Jc = 4' 'Jmin = 40' 'Jmax = 70' 'H1 = 1' 'H2 = 2' 'H3 = 3' 'H4 = 4' "$i1"
	case "$awg_version" in
		v3_0|v3_hybrid)
			rand_range() {
				min_l=$1; min_h=$2; sp_l=$3; sp_h=$4
				r1=$(hexdump -n 2 -e '/2 "%u"' /dev/urandom 2>/dev/null || echo 1234)
				r2=$(hexdump -n 2 -e '/2 "%u"' /dev/urandom 2>/dev/null || echo 5678)
				st=$(( min_l + (r1 % (min_h - min_l + 1)) ))
				sp=$(( sp_l + (r2 % (sp_h - sp_l + 1)) ))
				printf '%d-%d' "$st" "$(( st + sp ))"
			}
			printf 'ContentPaddingAddition = %s\n' "$(rand_range 20 50 15 45)"
			printf 'RekeyAfterTime = %s\n' "$(rand_range 80 110 15 40)"
			printf 'RekeyTimeout = %s\n' "$(rand_range 3 6 5 12)"
			printf 'RejectAfterTime = %s\n' "$(rand_range 90 130 20 50)"
			printf 'KeepaliveTimeout = %s\n' "$(rand_range 5 12 8 18)"
			printf 'MaxHandshakeAttempts = %s\n' "$(rand_range 10 18 8 18)"
			;;
	esac
	case "$awg_version" in
		v3_1|v3_hybrid)
			printf '%s\n' 'RandomTrailers = on' 'DisableCookies = on'
			;;
	esac
	printf '%s\n' '' '[Peer]' "PublicKey = $peer" 'AllowedIPs = 0.0.0.0/0, ::/0' "Endpoint = $endpoint"
} > "$out"

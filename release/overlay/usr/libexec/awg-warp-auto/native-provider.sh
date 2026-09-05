#!/bin/sh
# Native Cloudflare WARP registrar. Writes one strict AWG profile to $1.
# No remote generator, JavaScript, or external I1 service is used.
set -eu

out=${1:?output path required}
endpoint=''
sni=${3:-}
quic_mode=${4:-fallback}
tmp=${out}.json
umask 077
trap 'rm -f "$tmp"' EXIT

key=$(awg genkey)
pub=$(printf '%s' "$key" | awg pubkey)
tos=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
body=$(printf '{"install_id":"","tos":"%s","key":"%s","fcm_token":"","type":"ios","locale":"en_US"}' "$tos" "$pub")
base='https://api.cloudflareclient.com/v0i1909051800/reg'
curl -fSs --connect-timeout 10 --max-time 20 \
	-A 'okhttp/3.12.1' -H 'Content-Type: application/json' \
	-d "$body" "$base" > "$tmp"
id=$(jsonfilter -i "$tmp" -e '@.result.id')
token=$(jsonfilter -i "$tmp" -e '@.result.token')
[ -n "$id" ] && [ -n "$token" ] || exit 1
curl -fSs --connect-timeout 10 --max-time 20 \
	-A 'okhttp/3.12.1' -H 'Content-Type: application/json' \
	-H "Authorization: Bearer $token" -X PATCH -d '{"warp_enabled":true}' \
	"$base/$id" > "$tmp"
peer=$(jsonfilter -i "$tmp" -e '@.result.config.peers[0].public_key')
v4=$(jsonfilter -i "$tmp" -e '@.result.config.interface.addresses.v4')
v6=$(jsonfilter -i "$tmp" -e '@.result.config.interface.addresses.v6')
endpoint=$(jsonfilter -i "$tmp" -e '@.result.config.peers[0].endpoint.host')
if [ -z "$endpoint" ]; then
	endpoint=$(jsonfilter -i "$tmp" -e '@.result.config.peers[0].endpoint.v4')
fi
[ -n "$peer" ] && [ -n "$v4" ] || exit 1
case "$endpoint" in
	*[!A-Za-z0-9.:-]*|*:) exit 1 ;;
	*:[0-9]*)
		port=${endpoint##*:}
		[ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || exit 1
		;;
	*) exit 1 ;;
esac

# Bundled full QUIC preset, retained as an explicit compatibility fallback.
i1=$(printf '%s' 'STEgPSA8YiAweGNlMDAwMDAwMDEwODk3YTI5N2VjYzM0Y2Q2ZGQwMDAwNDRkMGVjMmUyZTFlYTI5OTFmNDY3YWNlNDIyMjEyOWI1YTA5ODgyMzc4NDY5NGI0ODk3Yjk5ODZhZTBiNzI4MDEzNWZhODVlMTk2ZDlhZDk4MGIxNTAxMjIxMjljZTJhOTM3OTUzMWIwZmQzZTg3MWNhNWZkYjg4M2MzNjk4MzJmNzMwZTI3MmQ3YjhiNzRmMzkzZjlmMGZhNDNmMTFlNTEwZWNiMjIxOWE1Mjk4NDQxMGMyMDRjZjg3NTU4NTM0MGM2MjIzOGUxNGFkMDRkZmYzODJmMmMyMDBlMGVlMjJmZTc0M2I5YzZiOGIwNDMxMjFjNTcxMGVjMjg5ZjQ3MWM5MWVlNDE0ZmNhOGI4YmU4NDE5YWU4Y2U3ZmZjNTM4MzdmNmFkZTI2Mjg5MTg5NWYzZjRjZWNkMzFiYzkzYWM1NTk5ZTE4ZTRmMDFiNDcyMzYyYjgwNTZjMzE3MmI1MTMwNTFmODMyMmQxMDYyOTk3ZWY0YTM4M2IwMTcwNjU5OGQwOGQ0OGMyMjFkMzBlNzRjN2NlMDAwY2RhZDM2YjcwNmIxYmY5YjA2MDdjMzJlYzRiMzIwM2E0ZWUyMWFiNjRkZjMzNjIxMmI5NzU4MjgwODAzZmNhYjE0OTMzYjBlN2VlMWUwNGE3YmVjY2UzZTI2MzNmNDg1MjU4NWM1Njc4OTRhNWY5ZWZlOTcwNmExNTFiNjE1ODU2NjQ3ZThiN2RiYTY5YWIzNTdiMzk4MmY1NTQ1NDliZWY5MjU2MTExYjJkNjdhZmRlMGI0OTZmMTY5NjJkNDk1N2ZmNjU0MjMyYWE5ZTg0NWI2MTQ2MzkwODMwOWNmZDlkZTBhNmFiZjVmNDI1ZjU3N2Q3ZTVmNjQ0MDY1MmFhOGRhNWY3MzU4OGU4MmU5NDcwZjNiMjFiMjdiMjhjNjQ5NTA2YWUxYTdmNWYxNWI4NzZmNTZhYmM0NjE1ZjQ5OTExNTQ5YjliYjM5ZGQ4MDRmZGUxODJiZDJkY2VjMGMzM2JhZDliMTM4Y2EwN2Q0YTRhMTY1MGEyYzI2ODZhY2VhMDU3MjdlMmE3ODk2MmE4NDBhZTQyOGY1NTYyNzUxNmU3M2M4M2RkODg5M2IwMjM1OGU4MWI1MjRiNGQ5OWZkYTZkZjUyYjNhOGQ3YTUyOTEzMjZlN2FjOWQ3NzNjNWI0M2I4NDQ0NTU0ZWY1YWVhMTA0YTczOGVkNjUwYWE5Nzk2NzRiYmVkMzhkYTU4YWMyOWQ4N2MyOWQzODdkODBiNTI2MDY1YmFlYjA3M2NlNjVmMDc1Y2NiNTZlNDc1MzNhZWYzNTdkY2VhYTgyOTNhNTIzYzVmNmY3OTBiZTkwZTQ3MzExMjNkM2M2MTUyYTcwNTc2ZTkwYjRhYjViYzVlYWQwMTU3NmM2OGFiNjMzZmY3ZDM2ZGNkZTJhMGIyYzY4ODk3ZTFhY2ZjNGQ2NDgzYWFhZWI2MzVkZDYzYzk2YjJiNmE3YTJiZmUwNDJmNmFlZDgyZTUzNjNhYTg1MGFhY2UxMmVlM2IxYTkzZjMwZDhhYjk1MzdkZjQ4MzE1MmE1NTI3ZmFjYTIxZWZjOTk4MWIzMDRmMTFmYzk1MzM2ZjViOTYzN2IxNzRjNWEwNjU5ZTJiMjJlMTU5YTlmZWQ0YjhlOTMwNDczNzExNzViMWQ2ZDljYzhhYjc0NWYzYjIyODE1MzdkMWM3NWZiOTQ1MTg3MTg2NGVmYTVkMTg0YzM4YzE4NWZkMjAzZGUyMDY3NTFiOTI2MjBmN2MzNjllMDMxZDIwNDFlMTUyMDQwOTIwYWMyYzVhYjUzNDBiZmM5ZDA1NjExNzZhYmYxMGExNDcyODdlYTkwNzU4NTc1YWM2YTlmNWFjOWYzOTBkMGQ1YjIzZWUxMmFmNTgzMzgzZDk5NGUyMmMwY2Y0MjM4MzgzNGJjZDNhZGExYjM4MjVhMDY2NGQ4ZjNmYjY3ODI2MWQ1NzYwMWRkZjk0YThhNjhhN2MyNzNhMThjMDhhYTk5YzdhZDhjNmM0MmVhYjY3NzE4ODQzNTk3ZWM5OTMwNDU3MzU5ZGZkZmJjZTAyNGFmYzJkY2Y5MzQ4NTc5YTU3ZDhkMzQ5MGIyZmE5OWYyNzhmMWMzN2Q4N2RhZDliMjIxYWNkNTc1MTkyZmZhZTE3ODRmOGU2MGVjN2NlZTQwNjhiNmI5ODhmMDQzM2Q5NmQ2YTFiMTg2NWY0ZTE1NWU5ZmUwMjAyNzlmNDM0ZjNiZjFiZDExN2I3MTdiOTJmNmNkMWNjOWJlYTdkNDU5NzhiY2MzZjI0YmRhNjMxYTM2OTEwMTEwYTZlYzA2ZGEzNWY4OTY2YzkyNzlkMTMwMzQ3NTk0ZjEzZTllMDc1MTRmYTM3MDc1NGQxNDI0YzBhMTU0NWM1MDcwZWY5ZmIyYWNkMTQyMzNlOGE1MGJmYzU5NzhiNWJkZjhiYzE3MTQ3MzFmNzk4ZDIxZTIwMDQxMTdjNjFmMjk4OWRkNDRmMGNmMDI3YjI3ZDQwMTllODFlZDRiNWMzMWRiMzQ3YzRhM2E0ZDg1MDQ4ZDcwOTNjZjE2NzUzZDdiMGQxNWUwNzhmNWM3YTUyMDVkYzJmODdlMzMwYTFmNzE2NzM4ZGNlMWM2MTgwZTlkMDI4NjliNTU0NmYxYzRkMjc0OGY4YzkwZDk2OTNjYmE0ZTAwNzkyOTdkMjJmZDYxNDAyZGVhMzJmZjBlYjY5ZWJkNjVhNWQwYjY4N2Q4N2UzYThiMmM0MmI2NDhhYTcyM2M3YzdkYWYzN2FiY2M0YmI4NWNhZWEyZWU4ZjU1YmVjMjBlOTEzYjMzMjRhYjhmNWMzMzA0ZjgyMGQ0MmFkMWI5ZjJmZmMxYTNhZjk5MjcxMzZiNDQxOWUxZTU3OWFiNGMyYWUzYzc3NmQyOTNkMzk3ZDU3NWRmMTgxZTZjYWUwYTRhZGE1ZDY3ZWNlYTE3MWNjYTMyODhkNTdjN2JiZGFlZTNiZWZlNzQ1ZmI3ZDYzNGY3MDM4NmQ4NzNiOTBjNGQ2YzY1OTZiYjY1YWY2OGY5ZTUxMjFlNjdlYmYwZDg5ZDNjOTA5Y2VlZGZiMzJjZTk1NzVhNzc1OGZmMDgwNzI0ZTFhYjVkNWY0MzA3NGVjYjUzYTQ3OWFmMjFlZDAzZDdiNjg5OWMzNjYzMWMwMTY2ZjlkNDdlNWUxZDQ1MjhhNWQzZDNmNzQ0MDI5YzRiMWMxOTBjYmZiYWQwNmY1ZjgzZjdhZDA0MjlmYTlhMjcxOWM1NmZmZTM3ODM0NjBlMTY2ZGUyZDg+' | base64 -d)
if [ "$quic_mode" = dynamic ] && command -v quic-i1 >/dev/null 2>&1 && printf '%s' "$sni" | grep -Eq '^[A-Za-z0-9.-]{1,253}$'; then
	dynamic_i1=$(quic-i1 --sni "$sni" 2>/dev/null || true)
	case "$dynamic_i1" in 'I1 = '*|I1=*) i1=$dynamic_i1 ;; esac
fi

{
	printf '%s\n' '[Interface]' "PrivateKey = $key" "Address = $v4${v6:+, $v6}" 'MTU = 1280'
	printf '%s\n' 'S1 = 0' 'S2 = 0' 'S3 = 0' 'S4 = 0' 'Jc = 4' 'Jmin = 40' 'Jmax = 70' 'H1 = 1' 'H2 = 2' 'H3 = 3' 'H4 = 4' "$i1"
	printf '%s\n' '' '[Peer]' "PublicKey = $peer" 'AllowedIPs = 0.0.0.0/0, ::/0' "Endpoint = $endpoint"
} > "$out"

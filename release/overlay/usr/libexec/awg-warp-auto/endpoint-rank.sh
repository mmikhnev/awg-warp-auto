#!/bin/sh
# Fast parallel Cloudflare Anycast subnet ranker.
# Discovers live Anycast prefixes and measures RTT to adapt dynamically
# to local ISP routing and censorship blocks without hardcoded geographic bias.

set -u

CACHE_DIR="/tmp/awg-warp-auto"
RANKED_TXT="$CACHE_DIR/ranked_subnets.txt"
RANKED_JSON="$CACHE_DIR/ranked_subnets.json"
PERSIST_TXT="/etc/awg-warp-auto/ranked_subnets.txt"

mkdir -p "$CACHE_DIR" "/etc/awg-warp-auto"
TMPDIR=$(mktemp -d /tmp/awg_rank.XXXXXX)

cleanup() {
	rm -rf "$TMPDIR"
}
trap cleanup EXIT INT TERM

# Cloudflare Anycast prefixes used globally for WARP
# 188.114.96.0/24, 188.114.97.0/24, 8.6.112.0/24, 162.159.192.0/24, 162.159.193.0/24, 162.159.195.0/24
KNOWN_PREFIXES="188.114.96 188.114.97 8.6.112 162.159.192 162.159.193 162.159.195"

for pfx in $KNOWN_PREFIXES; do
	(
		ip="${pfx}.1"
		out=$(ping -c 2 -W 1 "$ip" 2>/dev/null || true)
		rtt=$(printf '%s\n' "$out" | awk -F'/' '/min\/avg\/max/{split($5, a, "."); print a[1]}')
		if [ -n "$rtt" ] && [ "$rtt" -ge 0 ] 2>/dev/null; then
			echo "$rtt ${pfx}. ok" > "$TMPDIR/$pfx"
		else
			echo "99999 ${pfx}. blocked" > "$TMPDIR/$pfx"
		fi
	) &
done
wait

# Sort prefixes by RTT (lowest latency first, blocked last)
SORTED=$(cat "$TMPDIR"/* 2>/dev/null | sort -k1,1n -k2,2)

# Write human/script-readable ranked text file
printf '%s\n' "$SORTED" > "$RANKED_TXT"
cp "$RANKED_TXT" "$PERSIST_TXT" 2>/dev/null || true

# Generate structured JSON for LuCI UI
{
	printf '[\n'
	first=1
	printf '%s\n' "$SORTED" | while read -r rtt pfx status; do
		[ -n "$pfx" ] || continue
		if [ "$first" -eq 1 ]; then
			first=0
		else
			printf ',\n'
		fi
		subnet="${pfx}0/24"
		if [ "$status" = "ok" ]; then
			printf '  {"subnet":"%s","prefix":"%s","rtt_ms":%s,"status":"ok"}' "$subnet" "$pfx" "$rtt"
		else
			printf '  {"subnet":"%s","prefix":"%s","rtt_ms":null,"status":"blocked"}' "$subnet" "$pfx"
		fi
	done
	printf '\n]\n'
} > "$RANKED_JSON"

# Output ranked live prefixes (space-separated) to stdout for easy shell consumption
LIVE_PREFIXES=$(awk '$3 == "ok" {printf "%s ", $2}' "$RANKED_TXT" | sed 's/[[:space:]]*$//')
if [ -n "$LIVE_PREFIXES" ]; then
	logger -p user.info -t awg-warp-auto "ranked subnets: $LIVE_PREFIXES"
	printf '%s\n' "$LIVE_PREFIXES"
else
	logger -p user.warn -t awg-warp-auto "all candidate subnets blocked or unreachable; using default list"
	printf '188.114.96. 188.114.97. 8.6.112. 162.159.195.\n'
fi

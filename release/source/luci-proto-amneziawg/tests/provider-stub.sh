#!/bin/sh
set -eu
count=$(cat "$TESTROOT/registrations" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s' "$count" > "$TESTROOT/registrations"
if [ -e "$TESTROOT/fail_registration" ]; then
	printf '{"ok":false,"error":{"code":"SIMULATED_FAILURE"}}\n'
	exit 1
fi
path="$GENERATED/generated-native-$count.conf"
printf '[Interface]\n# fake device %s\n[Peer]\nEndpoint = %s\n' "$count" "$3" > "$path"
printf '{"ok":true,"configs":[{"path":"%s"}]}\n' "$path"

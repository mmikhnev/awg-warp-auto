#!/bin/sh
# Offline coordinator behavior: no router, credentials, network, or root.
set -eu
TESTROOT=$(mktemp -d)
trap 'rm -rf "$TESTROOT"' EXIT
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
eval "$(sed '/^case "${1:-run}" in/,$d' "$SCRIPT_DIR/../root/usr/libexec/awg-warp-auto/daemon.sh")"
POOL="$TESTROOT/pool"
GENERATED="$TESTROOT/generated"
RUNTIME="$TESTROOT/runtime"
mkdir -p "$POOL" "$GENERATED" "$RUNTIME" "$TESTROOT/main" "$TESTROOT/entries"
export TESTROOT GENERATED
cp "$SCRIPT_DIR/provider-stub.sh" "$RUNTIME/provider-fetch.sh"
chmod +x "$RUNTIME/provider-fetch.sh"
option() { cat "$TESTROOT/main/$1" 2>/dev/null || true; }
set_main() { printf '%s' "$2" > "$TESTROOT/main/$1"; }
commit() { :; }
log() { :; }
now() { printf 100000; }
prepare_dirs() { :; }
entry() { cat "$TESTROOT/entries/$1/$2" 2>/dev/null || true; }
set_entry() { mkdir -p "$TESTROOT/entries/$1"; printf '%s' "$3" > "$TESTROOT/entries/$1/$2"; }
entries() { for dir in "$TESTROOT/entries"/p_*; do [ -d "$dir" ] && basename "$dir"; done; return 0; }
prune_pool() { :; }
remove_entry() { rm -rf "$TESTROOT/entries/$1"; rm -f "$(entry_file "$1")"; }
read_json() {
	case "$2" in
		'@.ok') sed -n 's/.*"ok":\(true\|false\).*/\1/p' "$1" ;;
		'@.configs[0].path') sed -n 's/.*"path":"\([^"]*\)".*/\1/p' "$1" ;;
	esac
}
rpc_stage_file() {
	test_serial=$(( ${test_serial:-0} + 1 ))
	id=$(printf 'p_%024x' "$test_serial")
	cp "$1" "$(entry_file "$id")"
	set_entry "$id" status NEW
	printf '%s' "$id"
}
test_one() {
	printf '%s\n' "$1" >> "$TESTROOT/probes"
	if grep -q 'good.example:443' "$(entry_file "$1")"; then set_entry "$1" status READY; return 0; fi
	remove_entry "$1"
	return 1
}
assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
set_main minimum_ready 1
set_main native_endpoint_mode auto_custom
set_main native_endpoint 'bad.example:443 good.example:443'
set_main native_batch_limit 2
set_main native_min_interval 60
set_main native_backoff_base 120
set_main native_backoff_max 960
native_replenish
assert test "$(cat "$TESTROOT/registrations")" = 1
assert test "$(ready_count)" = 1
assert test "$(entries | wc -l | tr -d ' ')" = 1
assert test "$(wc -l < "$TESTROOT/probes" | tr -d ' ')" = 3
assert test "$(option native_next_attempt)" = 100060
# Enough READY suppresses registration even after resetting the budget.
set_main native_next_attempt 0
native_replenish
assert test "$(cat "$TESTROOT/registrations")" = 1
# Empty READY + persisted future budget suppresses registration across restart.
set_main minimum_ready 2
set_main native_next_attempt 100060
native_replenish
assert test "$(cat "$TESTROOT/registrations")" = 1
# Network failure schedules exponential retries; each attempt is bounded.
set_main native_next_attempt 0
touch "$TESTROOT/fail_registration"
if native_replenish; then echo 'FAIL expected registration error'; exit 1; fi
assert test "$(option native_failures)" = 1
assert test "$(option native_next_attempt)" = 100120
set_main native_next_attempt 0
if native_replenish; then echo 'FAIL expected registration error'; exit 1; fi
assert test "$(option native_failures)" = 2
assert test "$(option native_next_attempt)" = 100240
assert test "$(cat "$TESTROOT/registrations")" = 3
printf 'PASS: endpoint reuse/health, READY suppression, persisted budget, bounded failures/backoff\n'

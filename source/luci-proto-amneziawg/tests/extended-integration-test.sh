#!/bin/sh
# Extended offline integration test suite for WARP Auto coordinator,
# health resolver configuration, force replenishment, and recovery flows.
set -eu

TESTROOT=$(mktemp -d)
trap 'rm -rf "$TESTROOT"' EXIT
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)

# Source coordinator logic without running the CLI case dispatcher
eval "$(sed '/^case "${1:-run}" in/,$d' "$SCRIPT_DIR/../root/usr/libexec/awg-warp-auto/daemon.sh")"

POOL="$TESTROOT/pool"
GENERATED="$TESTROOT/generated"
RUNTIME="$TESTROOT/runtime"
mkdir -p "$POOL" "$GENERATED" "$RUNTIME" "$TESTROOT/main" "$TESTROOT/entries"
export TESTROOT GENERATED POOL RUNTIME

cp "$SCRIPT_DIR/provider-stub.sh" "$RUNTIME/provider-fetch.sh"
chmod +x "$RUNTIME/provider-fetch.sh"

option() { cat "$TESTROOT/main/$1" 2>/dev/null || true; }
set_main() { printf '%s' "$2" > "$TESTROOT/main/$1"; }
commit() { :; }
log() { :; }
uci() {
	case "${1:-}" in -q) shift ;; esac
	case "${1:-}" in
		get)
			local key="${2#$CONFIG.$MAIN.}"
			option "$key"
			;;
		set)
			local kv="${2#$CONFIG.$MAIN.}"
			local k="${kv%%=*}"
			local v="${kv#*=}"
			set_main "$k" "$v"
			;;
		delete)
			local key="${2#$CONFIG.$MAIN.}"
			rm -f "$TESTROOT/main/$key"
			;;
		show)
			local target="${2#$CONFIG.}"
			if [ -z "$target" ] || [ -d "$TESTROOT/entries/$target" ] || [ "$target" = "$MAIN" ]; then
				return 0
			fi
			return 1
			;;
		commit) : ;;
	esac
}
now() { cat "$TESTROOT/current_time" 2>/dev/null || printf 100000; }
set_time() { printf '%s' "$1" > "$TESTROOT/current_time"; }
prepare_dirs() { mkdir -p "$POOL" "$GENERATED"; }
entry() { cat "$TESTROOT/entries/$1/$2" 2>/dev/null || true; }
set_entry() { mkdir -p "$TESTROOT/entries/$1"; printf '%s' "$3" > "$TESTROOT/entries/$1/$2"; }
entries() { for dir in "$TESTROOT/entries"/p_*; do [ -d "$dir" ] && basename "$dir"; done; return 0; }
remove_entry() { rm -rf "$TESTROOT/entries/$1"; rm -f "$(entry_file "$1")"; pool_pruned=1; }

read_json() {
	case "$2" in
		'@.ok') sed -n 's/.*"ok":\(true\|false\).*/\1/p' "$1" ;;
		'@.configs[0].path') sed -n 's/.*"path":"\([^"]*\)".*/\1/p' "$1" ;;
		'@.latency_ms') sed -n 's/.*"latency_ms":\([0-9]*\).*/\1/p' "$1" ;;
		'@.error') sed -n 's/.*"error":"\([^"]*\)".*/\1/p' "$1" ;;
	esac
}

rpc_stage_file() {
	local serial
	serial=$(cat "$TESTROOT/serial" 2>/dev/null || echo 0)
	serial=$((serial + 1))
	printf '%s' "$serial" > "$TESTROOT/serial"
	local id
	id=$(printf 'p_%024x' "$serial")
	cp "$1" "$(entry_file "$id")"
	set_entry "$id" status NEW
	printf '%s' "$id"
}

test_one() {
	safe_id "$1" || return 2
	printf '%s\n' "$1" >> "$TESTROOT/probes"
	local file
	file="$(entry_file "$1")"
	if [ -r "$file" ] && grep -q 'good.example' "$file"; then
		set_entry "$1" status READY
		set_entry "$1" latency_ms 15
		set_entry "$1" failure_count 0
		return 0
	fi
	set_entry "$1" status FAILED
	set_entry "$1" last_error probe_failed
	if [ "$(option retain_failed_profiles)" != 1 ]; then
		remove_entry "$1"
	fi
	return 1
}

assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }

echo "=== Test 1: Stale active_id pruned when stored profile is deleted ==="
set_time 100000
set_main active_id "p_111111111111111111111111"
set_main previous_active_id "p_111111111111111111111111"
# File does not exist in $POOL
prune_pool
assert test -z "$(option active_id)"
assert test -z "$(option previous_active_id)"
echo "PASS: Test 1"

echo "=== Test 2: Native replenish budget & interval suppression ==="
set_time 100000
set_main minimum_ready 1
set_main native_endpoint_mode auto_custom
set_main native_endpoint 'bad.example:443 good.example:443'
set_main native_batch_limit 2
set_main native_min_interval 900
set_main native_next_attempt 100900
set_main native_last_attempt 100000
# With READY count = 0, but future budget and last_attempt < 60s ago:
assert test "$(native_replenish 0 0; echo $?)" = 0
assert test "$(ready_count)" = 0
echo "PASS: Test 2"

echo "=== Test 3: Emergency replenish triggered when READY count = 0 and >= 60s elapsed ==="
set_time 100070
set_main active_id "p_222222222222222222222222"
touch "$(entry_file "p_222222222222222222222222")"
set_entry "p_222222222222222222222222" status ACTIVE
# Now emergency replenishment should run even though next_attempt is 100900
native_replenish 0 0
assert test "$(ready_count)" = 1
echo "PASS: Test 3"

echo "=== Test 4: Manual force replenish with 30s cooldown ==="
set_time 100080
# Under 30s since last attempt (100070): force is suppressed
set_main native_next_attempt 101000
set_main native_last_attempt 100070
before_regs=$(cat "$TESTROOT/registrations" 2>/dev/null || echo 0)
native_replenish 1 1
after_regs=$(cat "$TESTROOT/registrations" 2>/dev/null || echo 0)
assert test "$before_regs" = "$after_regs"

# At 35s since last attempt: force succeeds
set_time 100105
native_replenish 1 1
after_force_regs=$(cat "$TESTROOT/registrations" 2>/dev/null || echo 0)
assert test "$after_force_regs" -gt "$before_regs"
echo "PASS: Test 4"

echo "=== Test 5: Candidate test script syntax and resolver handling ==="
sh -n "$SCRIPT_DIR/../root/usr/libexec/awg-warp-auto/candidate-test.sh"
sh -n "$SCRIPT_DIR/../root/usr/libexec/awg-warp-auto/health-check.sh"
sh -n "$SCRIPT_DIR/../root/usr/libexec/awg-warp-auto/daemon.sh"
echo "PASS: Test 5"

echo "=== Test 6: delete_one and clean_replenish_unlocked ==="
set_main active_id "p_active1111111111111111"
touch "$(entry_file "p_active1111111111111111")"
set_entry "p_active1111111111111111" status ACTIVE

set_entry "p_dead1111111111111111" status FAILED
touch "$(entry_file "p_dead1111111111111111")"

set_entry "p_ready1111111111111111" status READY
touch "$(entry_file "p_ready1111111111111111")"

# Deleting active must fail
if delete_one "p_active1111111111111111"; then
	echo "FAIL: delete_one active should have failed" >&2
	exit 1
fi

# Deleting p_dead1111111111111111 must succeed
delete_one "p_dead1111111111111111"
assert test ! -d "$TESTROOT/entries/p_dead1111111111111111"

# Clean replenish must keep only active
set_main minimum_ready 2
clean_replenish_unlocked
assert test -d "$TESTROOT/entries/p_active1111111111111111"
assert test ! -d "$TESTROOT/entries/p_ready1111111111111111"
echo "PASS: Test 6"

echo "ALL EXTENDED INTEGRATION TESTS PASSED!"

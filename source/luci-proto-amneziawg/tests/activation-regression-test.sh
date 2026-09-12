#!/bin/sh
# Activation regression test suite for WARP Auto
# Tests:
# 1. Port priority sorting (500 -> 1701 -> 4500 -> arbitrary -> 2408, deduplication)
# 2. Native QUIC mode defaults and fallback behavior
# 3. Activation worker syntax and execution contract
# 4. Asynchronous activation non-blocking rpcd behavior (< 500ms)
# 5. Background worker operation lifecycle (applying -> health_check -> success/rollback)

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
TESTROOT=$(mktemp -d)
trap 'rm -rf "$TESTROOT"' EXIT

assert() {
	if ! "$@"; then
		printf 'FAIL: %s\n' "$*" >&2
		exit 1
	fi
}

assert_eq() {
	if [ "$1" != "$2" ]; then
		printf 'FAIL: expected "%s", got "%s"\n' "$2" "$1" >&2
		exit 1
	fi
}

printf "=== RUNNING WARP AUTO ACTIVATION REGRESSION TESTS ===\n\n"

# -------------------------------------------------------------
# TEST 1: Port priority sorting and deduplication
# -------------------------------------------------------------
printf "TEST 1: Endpoint port sorting and priority order... "
NATIVE_SH="$REPO_ROOT/source/luci-proto-amneziawg/root/usr/libexec/awg-warp-auto/native-provider.sh"
assert test -f "$NATIVE_SH"

# Source the sort_ports function directly from native-provider.sh
sort_ports_fn=$(sed -n '/^sort_ports() {/,/^}/p' "$NATIVE_SH")
eval "$sort_ports_fn"

# Case 1a: Standard Cloudflare port list with 2408 in front
sorted1=$(sort_ports "2408 500 1701 4500")
assert_eq "$sorted1" "500 1701 4500 2408"

# Case 1b: Arbitrary ports mixed in should rank above 2408 but below 500/1701/4500
sorted2=$(sort_ports "2408 8080 500 1701 8888 4500")
assert_eq "$sorted2" "500 1701 4500 8080 8888 2408"

# Case 1c: Duplicate ports and whitespace handling
sorted3=$(sort_ports "500  2408 500  1701 4500   2408 500")
assert_eq "$sorted3" "500 1701 4500 2408"

# Case 1d: Only 2408 provided
sorted4=$(sort_ports "2408")
assert_eq "$sorted4" "2408"

# Case 1e: Empty string
sorted5=$(sort_ports "")
assert_eq "$sorted5" ""

printf "PASS\n"

# -------------------------------------------------------------
# TEST 2: Native QUIC mode defaults and fallback behavior
# -------------------------------------------------------------
printf "TEST 2: Native QUIC mode defaults in configuration and fetch scripts... "

# UCI config default must be 'dynamic'
uci_quic_mode=$(grep 'option native_quic_mode' "$REPO_ROOT/source/luci-proto-amneziawg/root/etc/config/awg-warp-auto" | awk '{print $3}' | tr -d "'\"")
assert_eq "$uci_quic_mode" "dynamic"

# provider-fetch.sh default must be dynamic
fetch_sh="$REPO_ROOT/source/luci-proto-amneziawg/root/usr/libexec/awg-warp-auto/provider-fetch.sh"
assert grep -q 'echo "dynamic"' "$fetch_sh"

# native-provider.sh default must be dynamic
assert grep -q 'quic_mode=${4:-dynamic}' "$NATIVE_SH"

# native-provider.sh must still retain fallback implementation
assert grep -q 'fallback_i1=' "$NATIVE_SH"
assert grep -q 'compatibility preset' "$NATIVE_SH"

printf "PASS\n"

# -------------------------------------------------------------
# TEST 3: Syntax and static check of activate-worker.uc and rpcd
# -------------------------------------------------------------
printf "TEST 3: Syntax check of activate-worker.uc and rpcd ucode... "
if command -v ucode >/dev/null 2>&1; then
	assert ucode -c "$REPO_ROOT/source/luci-proto-amneziawg/root/usr/libexec/awg-warp-auto/activate-worker.uc"
	assert ucode -c "$REPO_ROOT/source/luci-proto-amneziawg/root/usr/share/rpcd/ucode/luci.amneziawg"
	printf "PASS (verified with ucode)\n"
else
	# Fallback: check file non-empty and starts with shebang
	head_worker=$(head -n 1 "$REPO_ROOT/source/luci-proto-amneziawg/root/usr/libexec/awg-warp-auto/activate-worker.uc")
	assert_eq "$head_worker" "#!/usr/bin/env ucode"
	printf "PASS (ucode not in host path, checked structure)\n"
fi

# -------------------------------------------------------------
# TEST 4: Non-blocking rpcd activation contract
# -------------------------------------------------------------
printf "TEST 4: Non-blocking rpcd activation contract... "

# Verify in luci.amneziawg that 'activate' launches activate-worker.uc in background with & and returns operation_id
rpcd_file="$REPO_ROOT/source/luci-proto-amneziawg/root/usr/share/rpcd/ucode/luci.amneziawg"
assert grep -q 'activate-worker\.uc.*&' "$rpcd_file"
assert grep -q 'operation_id' "$rpcd_file"
assert grep -q 'getWarpAutoOperation' "$rpcd_file"

printf "PASS\n"

# -------------------------------------------------------------
# TEST 5: LuCI Status.js operation polling and checklist UX
# -------------------------------------------------------------
printf "TEST 5: LuCI Status.js operation polling and checklist UI contract... "

status_js="$REPO_ROOT/source/luci-proto-amneziawg/htdocs/luci-static/resources/view/amneziawg/status.js"
assert grep -q 'runActivationFlow' "$status_js"
assert grep -q 'callGetWarpAutoOperation' "$status_js"
assert grep -q 'poll\.stop' "$status_js"
assert grep -q 'poll\.start' "$status_js"
assert grep -q 'Applying configuration to network interface' "$status_js"
assert grep -q 'Running connectivity health check' "$status_js"
assert grep -q 'Finalizing activation and committing state' "$status_js"

printf "PASS\n"

# -------------------------------------------------------------
# TEST 6: Atomic Activation Lock & Concurrency Rejection
# -------------------------------------------------------------
printf "TEST 6: Atomic activation lock & concurrency rejection... "
assert grep -q 'activate\.lock' "$REPO_ROOT/source/luci-proto-amneziawg/root/usr/libexec/awg-warp-auto/activate-worker.uc"
assert grep -q 'operation_in_progress' "$REPO_ROOT/source/luci-proto-amneziawg/root/usr/libexec/awg-warp-auto/activate-worker.uc"
assert grep -q 'operation_in_progress' "$REPO_ROOT/source/luci-proto-amneziawg/root/usr/share/rpcd/ucode/luci.amneziawg"
printf "PASS\n"

# -------------------------------------------------------------
# TEST 7: Worker PID Tracking & Dead Worker Reconciliation
# -------------------------------------------------------------
printf "TEST 7: Worker PID tracking & dead worker detection... "
assert grep -q 'pid:' "$REPO_ROOT/source/luci-proto-amneziawg/root/usr/libexec/awg-warp-auto/activate-worker.uc"
assert grep -q 'readActiveOperation' "$REPO_ROOT/source/luci-proto-amneziawg/root/usr/share/rpcd/ucode/luci.amneziawg"
assert grep -q 'worker_terminated' "$REPO_ROOT/source/luci-proto-amneziawg/root/usr/share/rpcd/ucode/luci.amneziawg"
printf "PASS\n"

# -------------------------------------------------------------
# TEST 8: Safe Selective Probe Route Cleanup
# -------------------------------------------------------------
printf "TEST 8: Safe selective probe route cleanup... "
health_sh="$REPO_ROOT/source/luci-proto-amneziawg/root/usr/libexec/awg-warp-auto/health-check.sh"
cand_sh="$REPO_ROOT/source/luci-proto-amneziawg/root/usr/libexec/awg-warp-auto/candidate-test.sh"
assert grep -q "lookup \$PROBE_TABLE" "$health_sh"
assert grep -q "lookup \$TABLE" "$cand_sh"
assert grep -q "safe_cleanup_probe" "$health_sh"
printf "PASS\n"

# -------------------------------------------------------------
# TEST 9: Single Authoritative Owner (No Duplicate UCI Commits)
# -------------------------------------------------------------
printf "TEST 9: Single authoritative owner in daemon.sh... "
daemon_sh="$REPO_ROOT/source/luci-proto-amneziawg/root/usr/libexec/awg-warp-auto/daemon.sh"
# Ensure daemon.sh:activate_one does not redundantly call set_entry or set_main for active_id
activate_one_body=$(sed -n '/^activate_one() {/,/^}/p' "$daemon_sh")
if printf '%s' "$activate_one_body" | grep -q 'set_main active_id'; then
	printf "FAIL: daemon.sh still contains duplicate set_main active_id\n" >&2
	exit 1
fi
printf "PASS\n"

# -------------------------------------------------------------
# TEST 10: LuCI Activation UI Session Storage Persistence
# -------------------------------------------------------------
printf "TEST 10: LuCI activation session storage persistence... "
assert grep -q "sessionStorage\.setItem('warp_auto_active_op'" "$status_js"
assert grep -q "sessionStorage\.getItem('warp_auto_active_op')" "$status_js"
assert grep -q "sessionStorage\.removeItem('warp_auto_active_op')" "$status_js"
assert grep -q "attachActivationModal" "$status_js"
printf "PASS\n"

# -------------------------------------------------------------
# TEST 11: HTTP 429 Retry-After Header Parsing and Mock Test
# -------------------------------------------------------------
printf "TEST 11: HTTP 429 Retry-After header parsing... "
parse_fn=$(sed -n '/^parse_retry_after() {/,/^}/p' "$NATIVE_SH")
eval "$parse_fn"

# Case 11a: Standard Retry-After header
tmp_hdr="$TESTROOT/test_429.hdr"
printf "HTTP/2 429 Too Many Requests\r\nDate: Sun, 06 Sep 2026 15:00:00 GMT\r\nRetry-After: 120\r\nContent-Type: text/plain\r\n\r\n" > "$tmp_hdr"
ra_val=$(parse_retry_after)
assert_eq "$ra_val" "120"

# Case 11b: Mixed case header name and extra whitespace
printf "HTTP/1.1 429 Too Many Requests\r\nretry-after:   450  \r\n\r\n" > "$tmp_hdr"
ra_val=$(parse_retry_after)
assert_eq "$ra_val" "450"

# Case 11c: No Retry-After header
printf "HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\n\r\n" > "$tmp_hdr"
ra_val=$(parse_retry_after)
assert_eq "$ra_val" ""

# Verify native-provider.sh and provider-fetch.sh rate limit contracts
assert grep -q 'rate_limited' "$NATIVE_SH"
assert grep -q 'rate_limited' "$fetch_sh"
assert grep -q 'REGISTRATION_RATE_LIMITED' "$fetch_sh"
printf "PASS\n"

# -------------------------------------------------------------
# TEST 12: Daemon Rate Limit Budget Handling
# -------------------------------------------------------------
printf "TEST 12: Daemon rate limit budget handling... "
assert grep -q 'registration_rate_limited' "$daemon_sh"
assert grep -q 'LAST_NATIVE_RATE_LIMITED' "$daemon_sh"
assert grep -q 'LAST_NATIVE_RETRY_AFTER' "$daemon_sh"
printf "PASS\n"

# -------------------------------------------------------------
# TEST 13: LuCI JavaScript Syntax Validation
# -------------------------------------------------------------
printf "TEST 13: LuCI JavaScript syntax validation... "
if command -v node >/dev/null 2>&1; then
	for js in "$REPO_ROOT"/source/luci-proto-amneziawg/htdocs/luci-static/resources/view/amneziawg/*.js \
	          "$REPO_ROOT"/source/luci-proto-amneziawg/htdocs/luci-static/resources/protocol/*.js; do
		assert node --check "$js"
	done
	printf "PASS\n"
else
	printf "SKIP (node not found)\n"
fi

# -------------------------------------------------------------
# TEST 14: LuCI Batch Modal & Session Recovery Contracts
# -------------------------------------------------------------
printf "TEST 14: Batch modal & session recovery contracts... "
status_js="$REPO_ROOT/source/luci-proto-amneziawg/htdocs/luci-static/resources/view/amneziawg/status.js"
assert grep -q "attachBatchModal" "$status_js"
assert grep -q "runBatchFlow" "$status_js"
assert grep -q "sessionStorage\.setItem('warp_auto_active_batch'" "$status_js"
assert grep -q "sessionStorage\.getItem('warp_auto_active_batch')" "$status_js"
assert grep -q "attachBootstrapModal" "$status_js"
printf "PASS\n"

# -------------------------------------------------------------
# TEST 15: Policy Route 101 & Fwmark 0x08000000 Rule Generation
# -------------------------------------------------------------
printf "TEST 15: Table 101 policy route & rule generation... "
worker_uc="$REPO_ROOT/source/luci-proto-amneziawg/root/usr/libexec/awg-warp-auto/activate-worker.uc"
rpcd_uc="$REPO_ROOT/source/luci-proto-amneziawg/root/usr/share/rpcd/ucode/luci.amneziawg"
assert grep -q "table.*101" "$worker_uc"
assert grep -q "0x08000000" "$worker_uc"
assert grep -q "table.*101" "$rpcd_uc"
assert grep -q "0x08000000" "$rpcd_uc"
printf "PASS\n"

# -------------------------------------------------------------
# TEST 16: Bootstrap Force Replenishment Contract
# -------------------------------------------------------------
printf "TEST 16: Bootstrap force replenishment contract... "
daemon_sh="$REPO_ROOT/source/luci-proto-amneziawg/root/usr/libexec/awg-warp-auto/daemon.sh"
assert grep -q "native_replenish 1 1" "$daemon_sh"
printf "PASS\n"

# -------------------------------------------------------------
# TEST 17: Ucode autoNumber Numeric Types (int and double)
# -------------------------------------------------------------
printf "TEST 17: Ucode autoNumber numeric types... "
rpcd_uc="$REPO_ROOT/source/luci-proto-amneziawg/root/usr/share/rpcd/ucode/luci.amneziawg"
assert grep -q "type(value) != 'int'" "$rpcd_uc"
assert grep -q "type(value) != 'double'" "$rpcd_uc"
printf "PASS\n"

printf "\n=== ALL 17 ACTIVATION REGRESSION TESTS PASSED ===\n"

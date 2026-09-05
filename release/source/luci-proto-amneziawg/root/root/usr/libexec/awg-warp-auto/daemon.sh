#!/bin/sh

# WARP Auto coordinator.  It keeps a small root-only pool, probes candidates
# in a disposable interface, and delegates validation/activation to the same
# luci.amneziawg RPC core used by the manual importer.
set -u

TAG=awg-warp-auto
CONFIG=awg-warp-auto
MAIN=main
POOL=/etc/awg-warp-auto/pool
GENERATED=/tmp/awg-warp-auto/generated
RUNTIME=/usr/libexec/awg-warp-auto
LOCK=/var/run/awg-warp-auto.lock
POOL_LIMIT=10

log_rank() {
	case "$1" in debug) printf 0 ;; info) printf 1 ;; warning) printf 2 ;; error) printf 3 ;; *) printf 1 ;; esac
}

log_level() {
	case "$(option log_level)" in debug|info|warning|error) option log_level ;; *) printf info ;; esac
}

log() {
	local level=info threshold
	case "${1:-}" in debug|info|warning|error) level=$1; shift ;; esac
	threshold=$(log_rank "$(log_level)")
	[ "$(log_rank "$level")" -ge "$threshold" ] || return 0
	logger -p "user.$level" -t "$TAG" "$*"
}
now() { date +%s; }

safe_id() {
	case "${1:-}" in p_*) ;; *) return 1 ;; esac
	case "${1#p_}" in ''|*[!A-Fa-f0-9]*) return 1 ;; esac
	[ "${#1}" -ge 10 ]
}

option() { uci -q get "$CONFIG.$MAIN.$1" 2>/dev/null || true; }

interface_name() {
	local value
	value=$(option interface)
	case "$value" in
		''|[!A-Za-z]*|*[!A-Za-z0-9_]* ) ;;
		* ) [ "${#value}" -le 15 ] && { printf '%s' "$value"; return; } ;;
	esac
	printf '%s' awg_warp
}
entry() { safe_id "$1" || return 1; uci -q get "$CONFIG.$1.$2" 2>/dev/null || true; }
entries() { uci -q show "$CONFIG" 2>/dev/null | sed -n "s/^$CONFIG\.\([A-Za-z0-9_]*\)=entry$/\1/p"; }
entry_file() { printf '%s/%s.conf' "$POOL" "$1"; }

number() {
	case "${1:-}" in *[!0-9]*|'') printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}

bounded() {
	local value
	value=$(number "$1" "$2")
	[ "$value" -ge "$3" ] && [ "$value" -le "$4" ] || value=$2
	printf '%s' "$value"
}

provider_name() {
	case "$(option provider)" in native) printf native ;; *) printf remote ;; esac
}

native_endpoints() {
	local endpoint count=0
	for endpoint in $(option native_endpoint); do
		case "$endpoint" in *[!A-Za-z0-9.:-]*|'') continue ;; esac
		printf '%s\n' "$endpoint"
		count=$((count + 1))
		[ "$count" -lt 8 ] || break
	done
	[ "$count" -gt 0 ] || printf '%s\n' '8.6.112.6:987' '8.34.70.3:3581' '188.114.98.8:890'
}

native_budget_result() {
	local success=$1 failures delay maximum interval
	interval=$(bounded "$(option native_min_interval)" 900 60 86400)
	if [ "$success" = 1 ]; then
		set_main native_failures 0
		set_main native_last_error ''
		delay=$interval
	else
		failures=$(( $(bounded "$(option native_failures)" 0 0 20) + 1 ))
		[ "$failures" -le 20 ] || failures=20
		delay=$(bounded "$(option native_backoff_base)" 300 30 86400)
		maximum=$(bounded "$(option native_backoff_max)" 3600 60 86400)
		local n=1
		while [ "$n" -lt "$failures" ] && [ "$delay" -lt "$maximum" ]; do delay=$((delay * 2)); n=$((n + 1)); done
		[ "$delay" -le "$maximum" ] || delay=$maximum
		[ "$delay" -ge "$interval" ] || delay=$interval
		set_main native_failures "$failures"
		set_main native_last_error registration_or_endpoint_health_failed
	fi
	set_main native_next_attempt "$(( $(now) + delay ))"
	commit
}

health_mode() {
	case "$(option health_mode)" in direct|strict) option health_mode ;; *) printf '%s' strict ;; esac
}

prepare_dirs() {
	umask 077
	mkdir -p "$POOL" "$GENERATED" || return 1
	chmod 700 "${POOL%/pool}" "$POOL" "$GENERATED" 2>/dev/null || true
}

set_main() { uci -q set "$CONFIG.$MAIN.$1=$2"; }
set_entry() { safe_id "$1" || return 1; uci -q set "$CONFIG.$1.$2=$3"; }
commit() { uci -q commit "$CONFIG"; }

set_bootstrap_state() {
	set_main bootstrap_state "$1"
	set_main bootstrap_error "${2:-}"
	set_main bootstrap_updated "$(now)"
	commit
}

with_lock() {
	local attempts=0 owner
	while ! mkdir "$LOCK" 2>/dev/null; do
		attempts=$((attempts + 1))
		owner=$(cat "$LOCK/pid" 2>/dev/null || true)
		case "$owner" in
			''|*[!0-9]*) [ "$attempts" -lt 5 ] || rmdir "$LOCK" 2>/dev/null || true ;;
			*) if ! kill -0 "$owner" 2>/dev/null; then rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true; fi ;;
		esac
		# A full candidate probe can take several tens of seconds. Keep the lock
		# wait longer than one probe so a requested bootstrap does not vanish.
		[ "$attempts" -lt 90 ] || { log warning 'operation skipped: lock busy'; return 75; }
		sleep 1
	done
	printf '%s\n' "$$" > "$LOCK/pid"
	trap 'cleanup_lock' EXIT
	trap 'cleanup_lock; exit 143' TERM
	trap 'cleanup_lock; exit 130' INT
	"$@"
	local code=$?
	cleanup_lock
	trap - EXIT TERM INT
	return "$code"
}

cleanup_lock() {
	[ "$(cat "$LOCK/pid" 2>/dev/null || true)" = "$$" ] || return 0
	rm -f "$LOCK/pid"
	rmdir "$LOCK" 2>/dev/null || true
}

read_json() {
	# Avoid echo: JSON may contain a protected config only before it is staged.
	jsonfilter -i "$1" -e "$2" 2>/dev/null || true
}

rpc_stage_file() {
	local path=$1 filename=$2 reply id
	reply=$(ubus call luci.amneziawg stageWarpAutoFile "{\"path\":\"$path\",\"filename\":\"$filename\"}" 2>/dev/null) || return 1
	printf '%s' "$reply" > "$GENERATED/reply.$$.json"
	id=$(read_json "$GENERATED/reply.$$.json" '@.id')
	rm -f "$GENERATED/reply.$$.json"
	[ -n "$id" ] && safe_id "$id" || return 1
	printf '%s' "$id"
}

mark_test_result() {
	local id=$1 reply=$2 file ok latency reason
	file="$GENERATED/test.$$.json"
	printf '%s' "$reply" > "$file"
	ok=$(read_json "$file" '@.ok')
	latency=$(read_json "$file" '@.latency_ms')
	reason=$(read_json "$file" '@.error')
	rm -f "$file"
	set_entry "$id" last_test "$(now)"
	if [ "$ok" = 'true' ]; then
		set_entry "$id" status READY
		set_entry "$id" latency_ms "$(number "$latency" 0)"
		set_entry "$id" failure_count 0
		set_entry "$id" last_error ''
		commit
		log debug "candidate $id is READY"
		return 0
	fi
	set_entry "$id" status FAILED
	set_entry "$id" last_error "${reason:-candidate_test_failed}"
	set_entry "$id" failure_count "$(( $(number "$(entry "$id" failure_count)" 0) + 1 ))"
	commit
	log warning "candidate $id failed isolated YouTube test"
	return 1
}

test_one() {
	local id=$1 timeout reply
	safe_id "$id" || return 2
	[ "$id" != "$(option active_id)" ] || { log warning 'retest refused for ACTIVE profile; use active health check'; return 2; }
	[ -r "$(entry_file "$id")" ] || return 2
	timeout=$(number "$(option health_timeout)" 10)
	reply=$(ubus call luci.amneziawg testWarpAutoCandidate "{\"id\":\"$id\",\"timeout\":\"$timeout\"}" 2>/dev/null) || reply='{"ok":false,"error":"rpc"}'
	mark_test_result "$id" "$reply"
}

test_candidates() {
	local mode=${1:-all} id status
	for id in $(entries); do
		status=$(entry "$id" status)
		case "$mode:$status" in
			new:NEW|all:NEW|all:READY|all:FAILED) test_one "$id" || true ;;
		esac
	done
	prune_pool
}

ready_count() {
	local id status count=0 current blacklist
	current=$(now)
	for id in $(entries); do
		status=$(entry "$id" status)
		blacklist=$(number "$(entry "$id" blacklist_until)" 0)
		[ "$status" = READY ] && [ -r "$(entry_file "$id")" ] && [ "$blacklist" -le "$current" ] && count=$((count + 1))
	done
	printf '%s' "$count"
}

entry_count() { entries | wc -w; }

remove_entry() {
	local id=$1 previous
	safe_id "$id" || return 1
	uci -q delete "$CONFIG.$id"
	rm -f "$(entry_file "$id")"
	previous=$(option previous_active_id)
	[ "$previous" = "$id" ] && uci -q delete "$CONFIG.$MAIN.previous_active_id"
	pool_pruned=1
}

prune_pool() {
	local active previous id status file candidates count
	prepare_dirs || return 1
	active=$(option active_id)
	previous=$(option previous_active_id)
	pool_pruned=0

	# Keep FAILED profiles for explicit Retest, evicting them first at the cap.
	# ACTIVE and the previous profile remain protected for recovery/rollback.
	for id in $(entries); do
		status=$(entry "$id" status)
		file=$(entry_file "$id")
		if [ "$id" != "$active" ] && [ ! -r "$file" ]; then
			remove_entry "$id"
		fi
	done

	# Remove private files left behind by interrupted staging or old releases.
	for file in "$POOL"/p_*.conf; do
		[ -f "$file" ] || continue
		id=${file##*/}
		id=${id%.conf}
		safe_id "$id" && uci -q show "$CONFIG.$id" >/dev/null 2>&1 || rm -f "$file"
	done

	count=$(entry_count)
	for status in FAILED NEW READY; do
		[ "$count" -le "$POOL_LIMIT" ] && break
		candidates=$(for id in $(entries); do
			[ "$id" = "$active" ] && continue
			[ "$id" = "$previous" ] && continue
			[ "$(entry "$id" status)" = "$status" ] || continue
			printf '%010d %s\n' "$(number "$(entry "$id" created_at)" 0)" "$id"
		done | sort -n | sed 's/^[0-9]* //')
		for id in $candidates; do
			[ "$count" -le "$POOL_LIMIT" ] && break
			remove_entry "$id"
			count=$((count - 1))
		done
	done

	[ "$pool_pruned" = 1 ] && { commit; log info "pool pruned to $(entry_count) profiles"; }
}

generate_candidates() {
	prepare_dirs || return 1
	local source limit result index path profile id provider
	provider=${2:-$(provider_name)}
	source=$(option source_url)
	limit=$(number "$1" 2)
	[ "$limit" -ge 1 ] && [ "$limit" -le 8 ] || limit=2
	rm -f "$GENERATED"/generated-*.conf "$GENERATED"/provider.$$.json
	umask 077
	"$RUNTIME/provider-fetch.sh" "$provider" "$limit" "${3:-8.6.112.6:987}" > "$GENERATED/provider.$$.json" 2>/dev/null || true
	result="$GENERATED/provider.$$.json"
	[ "$(read_json "$result" '@.ok')" = true ] || { log "provider refresh failed: $(read_json "$result" '@.error.code')"; rm -f "$result"; return 1; }
	index=0
	while [ "$index" -lt "$limit" ]; do
		path=$(read_json "$result" "@.configs[$index].path")
		profile=$(read_json "$result" "@.configs[$index].profile")
		[ -n "$path" ] || break
		case "$path" in "$GENERATED"/generated-*.conf) ;; *) log 'provider returned unsafe path'; rm -f "$result"; return 1 ;; esac
		profile=$(printf '%s' "$profile" | tr -cd 'A-Za-z0-9_.-' | cut -c1-60)
		[ -n "$profile" ] || profile=warp-auto
		id=$(rpc_stage_file "$path" "$profile.conf") || { rm -f "$path"; index=$((index + 1)); continue; }
		rm -f "$path"
		set_entry "$id" source_url "$source"
		set_entry "$id" source_provider "$provider"
		set_entry "$id" status NEW
		commit
		log debug "provider staged candidate $id"
		index=$((index + 1))
	done
	rm -f "$result"
	return 0
}

# Phase-one native registrar: one deliberate operator request only. It reuses
# pool staging and isolated YouTube probing; it never activates or replenishes.
native_test_unlocked() {
	native_replenish 1
}

# Each registration is budgeted persistently before the network request. The
# same fresh device is tried against rotated endpoints; only its winning
# profile remains, so candidate probes never reuse an ACTIVE device's key.
native_replenish() {
	local manual=${1:-0} minimum need batch next current endpoints cursor endpoint ordered
	local attempt result path id old_id candidate success=0 count offset
	prepare_dirs || return 1
	minimum=$(bounded "$(option minimum_ready)" 2 1 8)
	need=$((minimum - $(ready_count)))
	[ "$manual" = 1 ] && need=1
	[ "$need" -gt 0 ] || return 0
	current=$(now)
	next=$(number "$(option native_next_attempt)" 0)
	[ "$current" -ge "$next" ] || { log debug '[native] registration budget/backoff active'; return 0; }
	batch=$(bounded "$(option native_batch_limit)" 2 1 2)
	[ "$need" -le "$batch" ] || need=$batch
	set_main native_last_attempt "$current"
	set_main native_next_attempt "$((current + $(bounded "$(option native_min_interval)" 900 60 86400)))"
	commit || return 1
	endpoints=$(native_endpoints)
	count=$(printf '%s\n' "$endpoints" | wc -l)
	cursor=$(number "$(option native_endpoint_cursor)" 0)
	attempt=0
	while [ "$attempt" -lt "$need" ]; do
		offset=$((cursor % count))
		ordered=$(printf '%s\n' "$endpoints" | awk -v offset="$offset" 'NR>offset{print} NR<=offset{tail=tail $0 "\n"} END{printf "%s",tail}')
		endpoint=$(printf '%s\n' "$ordered" | sed -n '1p')
		cursor=$((cursor + 1))
		set_main native_endpoint_cursor "$cursor"
		commit
		result="$GENERATED/native-provider.$$.json"
		"$RUNTIME/provider-fetch.sh" native 1 "$endpoint" > "$result" 2>/dev/null || true
		path=$(read_json "$result" '@.configs[0].path')
		if [ "$(read_json "$result" '@.ok')" != true ]; then rm -f "$result"; native_budget_result 0; log warning '[native] registration failed; retry delayed'; return 1; fi
		rm -f "$result"
		case "$path" in "$GENERATED"/generated-native-*.conf) ;; *) native_budget_result 0; return 1 ;; esac
		old_id=''
		for endpoint in $ordered; do
			candidate="$GENERATED/generated-endpoint-$$.conf"
			awk -v ep="$endpoint" '/^Endpoint[[:space:]]*=/{print "Endpoint = " ep; next} {print}' "$path" > "$candidate"
			id=$(rpc_stage_file "$candidate" WARP_native.conf) || continue
			[ -z "$old_id" ] || [ "$old_id" = "$id" ] || { remove_entry "$old_id"; commit; }
			old_id=$id
			set_entry "$id" source_provider native
			set_entry "$id" source_url native
			set_entry "$id" status NEW
			commit
			if test_one "$id"; then
				success=$((success + 1))
				log info "[native] $id READY after endpoint health check"
				break
			fi
		done
		rm -f "$path" "$GENERATED/generated-endpoint-$$.conf"
		attempt=$((attempt + 1))
	done
	set_main last_refresh "$(now)"
	[ "$success" -gt 0 ] && native_budget_result 1 || native_budget_result 0
	prune_pool
	[ "$success" -gt 0 ]
}

refresh_unlocked() {
	local minimum ready need fetch_count
	if [ "$(provider_name)" = native ]; then native_replenish; return $?; fi
	minimum=$(number "$(option minimum_ready)" 2)
	ready=$(ready_count)
	need=$((minimum - ready))
	[ "$need" -gt 0 ] || need=1
	[ "$need" -le 8 ] || need=8
	# Endpoint is randomized by source. Keep a bounded spread: one bad endpoint
	# must not reject all otherwise valid WARP templates.
	fetch_count=8
	generate_candidates "$fetch_count" || return 1
	test_candidates new
	set_main last_refresh "$(now)"
	commit
}

bootstrap_unlocked() {
	local has_interface=0 has_peer=0 id iface
	iface=$(interface_name)
	uci -q show "network.$iface" >/dev/null 2>&1 && has_interface=1
	uci -q show network 2>/dev/null | grep -q "=amneziawg_$iface$" && has_peer=1
	case "$has_interface:$has_peer" in
		0:0) ;;
		1:1) set_bootstrap_state failed already_exists; log "bootstrap refused: $iface already exists"; return 3 ;;
		*) set_bootstrap_state failed partial_configuration; log "bootstrap refused: partial $iface configuration"; return 3 ;;
	esac

	for binary in awg curl ucode resolveip; do
		command -v "$binary" >/dev/null 2>&1 || { set_bootstrap_state failed missing_runtime; log "bootstrap refused: missing $binary"; return 4; }
	done
	[ -e /lib/netifd/proto/amneziawg.sh ] || { set_bootstrap_state failed missing_runtime; log 'bootstrap refused: AmneziaWG netifd protocol is missing'; return 4; }

	set_bootstrap_state running
	log 'bootstrap requested: fetching and testing a first WARP profile'
	refresh_unlocked || { set_bootstrap_state failed prepare_failed; log 'bootstrap failed: no candidate could be prepared'; return 1; }
	for id in $(entries); do
		[ "$(entry "$id" status)" = READY ] || continue
		if activate_one "$id" direct; then
			set_main last_bootstrap "$(now)"
			set_bootstrap_state ready
			log "bootstrap created $iface from candidate $id"
			return 0
		fi
	done
	set_bootstrap_state failed activation_failed
	log 'bootstrap failed: no READY candidate passed active-interface health check'
	return 1
}

bootstrap() {
	local code
	with_lock bootstrap_unlocked
	code=$?
	if [ "$code" -eq 0 ] && [ "$(option enabled)" = 1 ]; then
		/etc/init.d/awg-warp-auto enable
		/etc/init.d/awg-warp-auto start
	fi
	return "$code"
}

activate_one() {
	local id=$1 mode old reply file ok
	mode=${2:-$(health_mode)}
	safe_id "$id" || return 2
	case "$mode" in direct|strict) ;; *) return 2 ;; esac
	[ "$(entry "$id" status)" = READY ] || { log warning "candidate $id is not READY"; return 1; }
	old=$(option active_id)
	reply=$(ubus -t 60 call luci.amneziawg activateWarpAutoCandidate "{\"id\":\"$id\",\"health_mode\":\"$mode\"}" 2>/dev/null) || reply='{"ok":false}'
	file="$GENERATED/activate.$$.json"
	printf '%s' "$reply" > "$file"
	ok=$(read_json "$file" '@.ok')
	rm -f "$file"
	if [ "$ok" = true ]; then
		if safe_id "$old" && [ "$old" != "$id" ]; then
			set_entry "$old" status READY
			set_main previous_active_id "$old"
		else
			uci -q delete "$CONFIG.$MAIN.previous_active_id"
		fi
		set_entry "$id" status ACTIVE
		set_entry "$id" failure_count 0
		set_entry "$id" health_state OK
		set_entry "$id" last_health "$(now)"
		set_main active_id "$id"
		set_main last_activation "$(now)"
		commit
		prune_pool
		log info "activated candidate $id after YouTube verification"
		return 0
	fi
	set_entry "$id" status FAILED
	set_entry "$id" last_error activation_health_failed
	set_entry "$id" failure_count "$(( $(number "$(entry "$id" failure_count)" 0) + 1 ))"
	commit
	prune_pool
	log warning "candidate $id activation rolled back by core health gate"
	return 1
}

rollback_unlocked() {
	local previous current
	previous=$(option previous_active_id)
	current=$(option active_id)
	safe_id "$previous" || { log warning 'rollback unavailable: no previous pool entry'; return 1; }
	[ "$(entry "$previous" status)" = READY ] || set_entry "$previous" status READY
	commit
	activate_one "$previous" || return 1
	set_main previous_active_id "$current"
	commit
}

failover_unlocked() {
	local id active current cooldown last
	active=$(option active_id)
	current=$(now)
	cooldown=$(number "$(option failover_cooldown)" 300)
	last=$(number "$(option last_failover)" 0)
	[ $((current - last)) -ge "$cooldown" ] || { log info 'failover cooldown active'; return 1; }
	for id in $(entries); do
		[ "$id" = "$active" ] && continue
		[ "$(entry "$id" status)" = READY ] || continue
		[ "$(number "$(entry "$id" blacklist_until)" 0)" -le "$current" ] || continue
		if test_one "$id" && activate_one "$id"; then
			set_main last_failover "$current"
			commit
			return 0
		fi
		set_entry "$id" blacklist_until "$((current + $(number "$(option blacklist_cooldown)" 3600)))"
		commit
	done
	log warning 'no READY candidate survived failover test; rebuilding pool'
	refresh_unlocked || true
	for id in $(entries); do
		[ "$id" = "$active" ] && continue
		[ "$(entry "$id" status)" = READY ] || continue
		test_one "$id" && activate_one "$id" && { set_main last_failover "$current"; commit; return 0; }
	done
	return 1
}

health_unlocked() {
	local active reply file ok failures threshold resources timeout mode
	active=$(option active_id)
	resources=$(uci -q get "$CONFIG.$MAIN.critical_resource" 2>/dev/null | tr ' \n' ',')
	resources=${resources%,}
	[ -n "$resources" ] || resources=youtube.com
	timeout=$(number "$(option health_timeout)" 10)
	mode=$(health_mode)
	reply=$(ubus call luci.amneziawg getWarpAutoHealth "{\"timeout\":\"$timeout\",\"resources\":\"$resources\",\"mode\":\"$mode\"}" 2>/dev/null) || reply='{"ok":false}'
	file="$GENERATED/health.$$.json"
	printf '%s' "$reply" > "$file"
	ok=$(read_json "$file" '@.ok')
	rm -f "$file"
	# A manually selected existing interface has no pool active_id yet. Keep it
	# untouched while healthy, but seed failover when its real YouTube check
	# fails. Previously this path returned early forever.
	if ! safe_id "$active"; then
		[ "$ok" = true ] && return 0
		if [ "$(option automatic_failover)" = 1 ]; then
			log warning 'unmanaged target health failed; starting failover'
			failover_unlocked || true
		fi
		return 1
	fi
	if [ "$ok" = true ]; then
		set_entry "$active" failure_count 0
		set_entry "$active" health_state OK
		set_entry "$active" status ACTIVE
		set_entry "$active" last_health "$(now)"
		commit
		log debug "active health OK for $active"
		return 0
	fi
	failures=$(( $(number "$(entry "$active" failure_count)" 0) + 1 ))
	threshold=$(number "$(option failure_threshold)" 3)
	set_entry "$active" failure_count "$failures"
	set_entry "$active" health_state FAIL
	set_entry "$active" last_health "$(now)"
	commit
	log warning "active health failure $failures/$threshold"
	if [ "$failures" -ge "$threshold" ] && [ "$(option automatic_failover)" = 1 ]; then
		set_entry "$active" status FAILED
		commit
		failover_unlocked || true
	fi
	return 1
}

cycle_unlocked() {
	local interval last current
	interval=$(number "$(option refresh_interval)" 86400)
	last=$(number "$(option last_refresh)" 0)
	current=$(now)
	health_unlocked || true
	if [ $((current - last)) -ge "$interval" ] || [ "$(ready_count)" -lt "$(number "$(option minimum_ready)" 2)" ]; then
		refresh_unlocked || true
	fi
	prune_pool || true
}

run_daemon() {
	prepare_dirs || exit 1
	prune_pool
	log info 'service started'
	while :; do
		"$0" cycle || true
		sleep "$(number "$(option health_interval)" 60)"
	done
}

activate_and_replenish() {
	activate_one "$1" || return $?
	[ "$(provider_name)" != native ] || native_replenish || true
}

failover_and_replenish() {
	failover_unlocked || return $?
	[ "$(provider_name)" != native ] || native_replenish || true
}

case "${1:-run}" in
	run) run_daemon ;;
	cycle) with_lock cycle_unlocked ;;
	refresh) with_lock refresh_unlocked ;;
	test_all) with_lock test_candidates all ;;
	bootstrap) bootstrap ;;
	activate) [ "$#" -eq 2 ] && with_lock activate_and_replenish "$2" || exit 2 ;;
	retest) [ "$#" -eq 2 ] && with_lock test_one "$2" || exit 2 ;;
	rollback) with_lock rollback_unlocked ;;
	failover) with_lock failover_and_replenish ;;
	native_test) with_lock native_test_unlocked ;;
	*) echo "Usage: $0 {run|cycle|refresh|test_all|bootstrap|native_test|retest ID|activate ID|rollback|failover}" >&2; exit 2 ;;
esac

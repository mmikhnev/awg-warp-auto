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

sorted_ready_entries() {
	local id lat spd current active
	active=$(option active_id)
	current=$(now)
	for id in $(entries); do
		[ "$id" = "$active" ] && continue
		[ "$(entry "$id" status)" = READY ] || continue
		[ "$(number "$(entry "$id" blacklist_until)" 0)" -le "$current" ] || continue
		lat=$(number "$(entry "$id" latency_ms)" 9999)
		spd=$(number "$(entry "$id" speed_mbps)" 0)
		echo "$spd $lat $id"
	done | sort -k1,1nr -k2,2n | awk '{print $3}'
}

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

custom_endpoints() {
	local endpoint count=0
	for endpoint in $(option native_endpoint); do
		case "$endpoint" in *[!A-Za-z0-9.:-]*|'') continue ;; esac
		printf '%s\n' "$endpoint"
		count=$((count + 1))
		[ "$count" -lt 8 ] || break
	done
}

native_endpoint_mode() {
	case "$(option native_endpoint_mode)" in custom|auto_custom) option native_endpoint_mode ;; *) printf '%s' auto ;; esac
}

native_budget_result() {
	local success=$1 err_code=${2:-} retry_after=${3:-} failures delay maximum interval
	interval=$(bounded "$(option native_min_interval)" 900 60 86400)
	if [ "$success" = 1 ]; then
		set_main native_failures 0
		set_main native_last_error ''
		delay=$interval
	else
		failures=$(( $(bounded "$(option native_failures)" 0 0 20) + 1 ))
		[ "$failures" -le 20 ] || failures=20
		if [ "$err_code" = "registration_rate_limited" ] && [ -n "$retry_after" ] && [ "$retry_after" -gt 0 ] 2>/dev/null; then
			delay=$(bounded "$retry_after" 300 60 86400)
			set_main native_last_error registration_rate_limited
			set_main native_retry_after "$delay"
		else
			delay=$(bounded "$(option native_backoff_base)" 300 30 86400)
			maximum=$(bounded "$(option native_backoff_max)" 3600 60 86400)
			local n=1
			while [ "$n" -lt "$failures" ] && [ "$delay" -lt "$maximum" ]; do delay=$((delay * 2)); n=$((n + 1)); done
			[ "$delay" -le "$maximum" ] || delay=$maximum
			[ "$delay" -ge "$interval" ] || delay=$interval
			set_main native_last_error registration_or_endpoint_health_failed
		fi
		set_main native_failures "$failures"
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

batch_size() {
	local val
	val=$(option batch_size)
	[ -n "$val" ] || val=$(option native_batch_limit)
	bounded "$val" 5 1 10
}

set_bootstrap_state() {
	set_main bootstrap_state "$1"
	set_main bootstrap_error "${2:-}"
	set_main bootstrap_updated "$(now)"
	commit
}

set_batch_state() {
	set_main batch_state "$1"
	set_main batch_provider "${2:-}"
	set_main batch_requested "${3:-0}"
	set_main batch_generated "${4:-0}"
	set_main batch_ready "${5:-0}"
	set_main batch_failed "${6:-0}"
	set_main batch_message "${7:-}"
	set_main batch_updated "$(now)"
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

test_one() {
	local id=$1 timeout resolvers iface result ok=false latency=0 speed=0 reason=''
	safe_id "$id" || return 2
	[ -r "$(entry_file "$id")" ] || return 2
	timeout=$(number "$(option health_timeout)" 10)
	resolvers=$(option health_resolvers)
	[ -n "$resolvers" ] || resolvers='1.1.1.1 8.8.8.8 9.9.9.9 77.88.8.8 77.88.8.1'

	if [ "$id" = "$(option active_id)" ]; then
		iface=$(interface_name)
		result=$(/usr/libexec/awg-warp-auto/health-check.sh "$iface" "$timeout" "youtube.com" "strict" "$resolvers" 1 2>/dev/null) || result='FAIL'
	else
		result=$(/usr/libexec/awg-warp-auto/candidate-test.sh "$(entry_file "$id")" "$timeout" 51822 "$resolvers" 2>/dev/null) || result='FAIL'
	fi

	case "$result" in
		OK\ *)
			ok=true
			latency=$(echo "$result" | awk '{print $2}')
			speed=$(echo "$result" | awk '{print $3}')
			;;
		*)
			reason="$result"
			;;
	esac

	set_entry "$id" last_test "$(now)"
	if [ "$ok" = 'true' ]; then
		if [ "$id" = "$(option active_id)" ]; then
			set_entry "$id" status ACTIVE
			set_entry "$id" health_state OK
		else
			set_entry "$id" status READY
		fi
		set_entry "$id" latency_ms "$(number "$latency" 0)"
		set_entry "$id" speed_mbps "$(number "$speed" 0)"
		set_entry "$id" failure_count 0
		set_entry "$id" last_error ''
		commit
		log info "candidate $id test OK (latency=${latency}ms, speed=${speed}Mbps)"
		return 0
	fi

	set_entry "$id" status FAILED
	set_entry "$id" last_error "${reason:-candidate_test_failed}"
	set_entry "$id" failure_count "$(( $(number "$(entry "$id" failure_count)" 0) + 1 ))"
	commit
	log warning "candidate $id failed test"
	if [ "$(option retain_failed_profiles)" != 1 ] && [ "$id" != "$(option active_id)" ]; then
		remove_entry "$id"
		commit
	fi
	return 1
}

test_candidates() {
	local mode=${1:-all} id status total=0 current=0 ready=0 failed=0 ep prof
	for id in $(entries); do
		status=$(entry "$id" status)
		case "$mode:$status" in
			new:NEW|all:NEW|all:READY|all:FAILED|all:ACTIVE) total=$((total + 1)) ;;
		esac
	done
	[ "$total" -gt 0 ] || {
		[ "$mode" = all ] && set_batch_state complete "retest" 0 0 0 0 "No profiles to test in pool."
		return 0
	}
	[ "$mode" = all ] && set_batch_state running "retest" "$total" 0 0 0 "Starting retest of $total profiles…"
	for id in $(entries); do
		status=$(entry "$id" status)
		case "$mode:$status" in
			new:NEW|all:NEW|all:READY|all:FAILED|all:ACTIVE)
				current=$((current + 1))
				ep=$(entry "$id" endpoint)
				prof=$(entry "$id" profile)
				short_id=${id#p_}
				short_id=${short_id:0:4}
				case "$prof" in
					WARP_native*|WARP|'') prof="WARP #$short_id" ;;
				esac
				[ "$mode" = all ] && set_batch_state running "retest" "$total" "$((current - 1))" "$ready" "$failed" "Testing $current of $total: ${prof:-$id} ($ep)…"
				if test_one "$id"; then
					ready=$((ready + 1))
				else
					failed=$((failed + 1))
				fi
				[ "$mode" = all ] && set_batch_state running "retest" "$total" "$current" "$ready" "$failed" "Tested $current of $total: ${prof:-$id} ($ep)"
				;;
		esac
	done
	prune_pool
	[ "$mode" = all ] && set_batch_state complete "retest" "$total" "$current" "$ready" "$failed" "Retest complete: $ready OK, $failed FAILED of $total."
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
	local active previous id status file candidates count provider endpoint_source mode
	prepare_dirs || return 1
	active=$(option active_id)
	previous=$(option previous_active_id)
	mode=$(native_endpoint_mode)
	pool_pruned=0
	# Never advertise an ACTIVE profile whose protected source file is gone.
	# The live interface is intentionally left untouched; it becomes an
	# unmanaged target until a surviving READY profile is explicitly activated
	# or a real health failure requires failover.
	if safe_id "$active" && [ ! -r "$(entry_file "$active")" ]; then
		uci -q delete "$CONFIG.$MAIN.active_id"
		[ "$previous" = "$active" ] && uci -q delete "$CONFIG.$MAIN.previous_active_id"
		active=''
		pool_pruned=1
		log warning 'cleared stale active profile reference with missing stored config'
	fi

	# FAILED profiles are removed by default; opt-in retention is diagnostic only.
	# ACTIVE and previous profile remain protected for recovery/rollback.
	for id in $(entries); do
		status=$(entry "$id" status)
		file=$(entry_file "$id")
		provider=$(entry "$id" source_provider)
		endpoint_source=$(entry "$id" endpoint_source)
		# An ACTIVE profile may be marked FAILED before failover probes finish.
		# It remains the currently applied configuration and must survive both
		# the download/rollback path and a later recovered health check.
		if [ "$status" = FAILED ] && [ "$id" != "$active" ] && [ "$(option retain_failed_profiles)" != 1 ]; then
			remove_entry "$id"
			continue
		fi
		# Auto mode must not silently keep legacy hardcoded Native candidates.
		if [ "$mode" = auto ] && [ "$provider" = native ] && [ "$endpoint_source" != cloudflare_registration ] && [ "$id" != "$active" ]; then
			remove_entry "$id"
			continue
		fi
		# Prune any non-active candidates with Fake-IP or unresolvable hostname endpoints
		ep_val=$(entry "$id" endpoint)
		case "$ep_val" in
			198.18.*|198.19.*|*engage.cloudflareclient.com*)
				if [ "$id" != "$active" ]; then
					remove_entry "$id"
					continue
				fi
				;;
		esac
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
	return 0
}

generate_candidates() {
	prepare_dirs || return 1
	local source limit result index path profile id provider
	provider=${2:-$(provider_name)}
	source=$(option source_url)
	limit=$(number "$1" 2)
	[ "$limit" -ge 1 ] && [ "$limit" -le 10 ] || limit=2
	rm -f "$GENERATED"/generated-*.conf "$GENERATED"/provider.$$.json
	umask 077
	"$RUNTIME/provider-fetch.sh" "$provider" "$limit" "${3:-}" > "$GENERATED/provider.$$.json" 2>/dev/null || true
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
	native_replenish 1 1
}

force_replenish_unlocked() {
	if [ "$(provider_name)" = native ]; then
		native_replenish 1 1
	else
		refresh_unlocked
	fi
}

delete_one() {
	local id=$1 active
	safe_id "$id" || return 1
	prepare_dirs || return 1
	active=$(option active_id)
	if [ "$id" = "$active" ]; then
		log error "cannot delete active profile $id"
		return 1
	fi
	remove_entry "$id"
	commit
	log info "deleted profile $id"
}

clean_replenish_unlocked() {
	local active id removed=0 min_ready ready need provider requested=${1:-}
	prepare_dirs || return 1
	provider=$(provider_name)
	set_batch_state running "$provider" 0 0 0 0 "Deleting inactive profiles…"
	active=$(option active_id)
	log info "cleaning pool except active profile ($active)"
	for id in $(entries); do
		[ "$id" != "$active" ] || continue
		remove_entry "$id"
		removed=$((removed + 1))
	done
	commit
	log info "deleted $removed inactive profiles"
	if [ -n "$requested" ]; then
		need=$(bounded "$requested" 0 0 10)
	else
		min_ready=$(bounded "$(option minimum_ready)" 2 0 10)
		ready=$(ready_count)
		need=$((min_ready - ready))
	fi
	if [ "$need" -gt 0 ]; then
		log info "auto-replenishing pool with $need profile(s)"
		generate_batch_unlocked "$need"
	else
		set_batch_state complete "$provider" 0 0 0 0 "Deleted $removed inactive profiles."
	fi
}

# Each registration is budgeted persistently before the network request. The
# same fresh device is tried against rotated endpoints; only its winning
# profile remains, so candidate probes never reuse an ACTIVE device's key.
# Generate and test a single native profile. Returns 0 if candidate is READY, 1 on test fail, 2 on registration error.
generate_one_native() {
	local mode endpoints custom_count cursor offset ordered endpoint candidate id path auto_ok reg_candidates reg_v4 reg_ports ep_in_file
	mode=$(native_endpoint_mode)
	endpoints=$(custom_endpoints)
	custom_count=$(printf '%s\n' "$endpoints" | sed '/^$/d' | wc -l)
	cursor=$(number "$(option native_endpoint_cursor)" 0)

	result="$GENERATED/native-provider.$$.json"
	# Native provider writes Endpoint directly from Cloudflare registration.
	"$RUNTIME/provider-fetch.sh" native 1 > "$result" 2>/dev/null || true
	path=$(read_json "$result" '@.configs[0].path')
	LAST_NATIVE_RATE_LIMITED=$(read_json "$result" '@.rate_limited')
	LAST_NATIVE_RETRY_AFTER=$(read_json "$result" '@.retry_after')
	if [ "$(read_json "$result" '@.ok')" != true ]; then
		rm -f "$result"
		return 2
	fi
	reg_candidates=$(read_json "$result" '@.candidates[*]')
	reg_v4=$(read_json "$result" '@.v4')
	reg_ports=$(read_json "$result" '@.ports[*]')
	rm -f "$result"
	case "$path" in "$GENERATED"/generated-native-*.conf) ;; *) return 2 ;; esac
	auto_ok=0

	if [ "$mode" != custom ]; then
		if [ -z "$reg_candidates" ] && [ -n "$reg_v4" ] && [ -n "$reg_ports" ]; then
			for p in $reg_ports; do
				reg_candidates="${reg_candidates:+${reg_candidates} }${reg_v4}:${p}"
			done
		fi
		if [ -n "$reg_candidates" ]; then
			log debug "[native] testing registration candidates: $reg_candidates"
			for endpoint in $reg_candidates; do
				case "$endpoint" in
					198.18.*|198.19.*)
						log warning "[native] skipping Fake-IP candidate endpoint $endpoint"
						continue
						;;
				esac
				candidate="$GENERATED/generated-reg-$$.conf"
				awk -v ep="$endpoint" '/^Endpoint[[:space:]]*=/{print "Endpoint = " ep; next} {print}' "$path" > "$candidate"
				id=$(rpc_stage_file "$candidate" WARP_native_cloudflare.conf) || { rm -f "$candidate"; continue; }
				rm -f "$candidate"
				set_entry "$id" source_provider native
				set_entry "$id" source_url cloudflare_registration
				set_entry "$id" endpoint_source cloudflare_registration
				set_entry "$id" endpoint "$endpoint"
				set_entry "$id" status NEW
				[ -n "${gen_total:-}" ] && set_batch_state running "${provider:-native}" "${count:-1}" "${gen_total:-0}" "${gen_ready:-0}" "${gen_failed:-0}" "Profile $(( ${gen_total:-0} + 1 )) of ${count:-1}: testing endpoint $endpoint…"
				if test_one "$id"; then
					auto_ok=1
					log info "[native] $id READY using Cloudflare registration endpoint $endpoint"
					break
				else
					remove_entry "$id"
				fi
			done
		else
			id=$(rpc_stage_file "$path" WARP_native_cloudflare.conf) || id=''
			if [ -n "$id" ]; then
				ep_in_file=$(awk -F= '/^Endpoint[[:space:]]*=/{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$path")
				case "$ep_in_file" in
					198.18.*|198.19.*|*engage.cloudflareclient.com*)
						log warning "[native] rejected invalid/Fake-IP endpoint in staged template: $ep_in_file"
						remove_entry "$id"
						id=''
						;;
					*)
						set_entry "$id" source_provider native
						set_entry "$id" source_url cloudflare_registration
						set_entry "$id" endpoint_source cloudflare_registration
						set_entry "$id" status NEW
						commit
						if test_one "$id"; then
							auto_ok=1
							log info "[native] $id READY using Cloudflare registration endpoint $ep_in_file"
						fi
						;;
				esac
			fi
		fi
	fi

	if [ "$auto_ok" = 1 ]; then
		rm -f "$path"
		return 0
	fi

	if [ "$mode" = auto ] || [ "$custom_count" -eq 0 ]; then
		rm -f "$path"
		return 1
	fi

	offset=$((cursor % custom_count))
	ordered=$(printf '%s\n' "$endpoints" | awk -v offset="$offset" 'NR>offset{print} NR<=offset{tail=tail $0 "\n"} END{printf "%s",tail}')
	cursor=$((cursor + 1))
	set_main native_endpoint_cursor "$cursor"
	commit
	for endpoint in $ordered; do
		candidate="$GENERATED/generated-endpoint-$$.conf"
		awk -v ep="$endpoint" '/^Endpoint[[:space:]]*=/{print "Endpoint = " ep; next} {print}' "$path" > "$candidate"
		id=$(rpc_stage_file "$candidate" WARP_native.conf) || continue
		set_entry "$id" source_provider native
		set_entry "$id" source_url custom_endpoint_pool
		set_entry "$id" endpoint_source custom
		set_entry "$id" status NEW
		commit
		[ -n "${gen_total:-}" ] && set_batch_state running "${provider:-native}" "${count:-1}" "${gen_total:-0}" "${gen_ready:-0}" "${gen_failed:-0}" "Profile $(( ${gen_total:-0} + 1 )) of ${count:-1}: testing fallback $endpoint…"
		if test_one "$id"; then
			log info "[native] $id READY after endpoint health check"
			rm -f "$path" "$GENERATED/generated-endpoint-$$.conf"
			return 0
		else
			remove_entry "$id"
		fi
	done
	rm -f "$path" "$GENERATED/generated-endpoint-$$.conf"
	return 1
}

# Unified batch generation: generates N profiles for configured provider.
generate_batch_unlocked() {
	local requested count provider gen_ready=0 gen_failed=0 gen_total=0 code
	requested=${1:-$(batch_size)}
	count=$(bounded "$requested" 5 1 10)
	provider=$(provider_name)
	prepare_dirs || return 1
	prune_pool

	log info "batch generation started provider=$provider requested=$count"
	set_batch_state running "$provider" "$count" 0 0 0 "Generating $count $provider profiles…"

	if [ "$provider" = remote ]; then
		if generate_candidates "$count" remote; then
			for id in $(entries); do
				[ "$(entry "$id" status)" = NEW ] || continue
				gen_total=$((gen_total + 1))
				if test_one "$id"; then
					gen_ready=$((gen_ready + 1))
				else
					gen_failed=$((gen_failed + 1))
				fi
				set_batch_state running "$provider" "$count" "$gen_total" "$gen_ready" "$gen_failed" "Testing candidates ($gen_total/$count)…"
			done
		else
			log warning "remote batch generation failed during fetch"
		fi
	else
		local current next last_attempt
		current=$(now)
		next=$(number "$(option native_next_attempt)" 0)
		last_attempt=$(number "$(option native_last_attempt)" 0)
		if [ "$current" -lt "$next" ] && [ $((current - last_attempt)) -lt 10 ]; then
			log warning '[native] batch generation throttled (anti-flood cooldown)'
			set_batch_state complete "$provider" "$count" 0 0 0 "Batch generation throttled (wait 10s between requests)."
			return 1
		fi
		set_main native_last_attempt "$current"
		set_main native_next_attempt "$((current + $(bounded "$(option native_min_interval)" 900 60 86400)))"
		commit

		while [ "$gen_total" -lt "$count" ]; do
			set_batch_state running "$provider" "$count" "$gen_total" "$gen_ready" "$gen_failed" "Registering device $((gen_total + 1)) of $count…"
			generate_one_native
			code=$?
			if [ "$code" -eq 2 ]; then
				if [ "$LAST_NATIVE_RATE_LIMITED" = true ]; then
					log warning "[native] registration rate-limited (HTTP 429) at device $((gen_total + 1)), retry after ${LAST_NATIVE_RETRY_AFTER:-300}s"
					native_budget_result 0 registration_rate_limited "${LAST_NATIVE_RETRY_AFTER:-300}"
				else
					log warning "[native] registration failed at device $((gen_total + 1))"
					native_budget_result 0
				fi
				break
			fi
			gen_total=$((gen_total + 1))
			if [ "$code" -eq 0 ]; then
				gen_ready=$((gen_ready + 1))
			else
				gen_failed=$((gen_failed + 1))
			fi
			set_batch_state running "$provider" "$count" "$gen_total" "$gen_ready" "$gen_failed" "Generated $gen_total of $count (READY: $gen_ready, FAILED: $gen_failed)…"
		done
		[ "$gen_ready" -gt 0 ] && native_budget_result 1 || native_budget_result 0
	fi

	set_main last_refresh "$(now)"
	commit
	prune_pool
	log info "batch generation completed provider=$provider requested=$count generated=$gen_total ready=$gen_ready failed=$gen_failed"
	set_batch_state complete "$provider" "$count" "$gen_total" "$gen_ready" "$gen_failed" "Batch generation complete: $gen_ready READY, $gen_failed FAILED of $count requested."
	return 0
}

# Each registration is budgeted persistently before the network request. The
# same fresh device is tried against rotated endpoints; only its winning
# profile remains, so candidate probes never reuse an ACTIVE device's key.
native_replenish() {
	local manual=${1:-0} force=${2:-0} minimum ready need batch next current last_attempt emergency
	local attempt success=0 code
	prepare_dirs || return 1
	prune_pool
	minimum=$(bounded "$(option minimum_ready)" 2 0 10)
	ready=$(ready_count)
	need=$((minimum - ready))
	[ "$manual" = 1 ] && need=1
	[ "$need" -gt 0 ] || return 0
	current=$(now)
	next=$(number "$(option native_next_attempt)" 0)
	emergency=0
	[ "$ready" -eq 0 ] && safe_id "$(option active_id)" && emergency=1
	last_attempt=$(number "$(option native_last_attempt)" 0)
	if [ "$current" -lt "$next" ]; then
		if [ "$force" = 1 ] || { [ "$ready" -eq 0 ] && ! safe_id "$(option active_id)"; }; then
			log info '[native] initial bootstrap or manual replenishment allowed'
		elif [ "$emergency" = 1 ] && [ $((current - last_attempt)) -ge 60 ]; then
			log warning '[native] emergency replenishment after empty failover pool'
		else
			log debug '[native] registration budget/backoff active'
			return 0
		fi
	fi
	batch=$(bounded "$(option batch_size)" 2 1 10)
	[ "$manual" = 1 ] && batch=1
	[ "$need" -le "$batch" ] || need=$batch
	set_main native_last_attempt "$current"
	set_main native_next_attempt "$((current + $(bounded "$(option native_min_interval)" 900 60 86400)))"
	commit || return 1
	attempt=0
	while [ "$attempt" -lt "$need" ]; do
		generate_one_native
		code=$?
		if [ "$code" -eq 2 ]; then
			if [ "$LAST_NATIVE_RATE_LIMITED" = true ]; then
				log warning "[native] registration rate-limited (HTTP 429), retry after ${LAST_NATIVE_RETRY_AFTER:-300}s"
				native_budget_result 0 registration_rate_limited "${LAST_NATIVE_RETRY_AFTER:-300}"
			else
				native_budget_result 0
				log warning '[native] registration failed; retry delayed'
			fi
			return 1
		elif [ "$code" -eq 0 ]; then
			success=$((success + 1))
		fi
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
	[ "$need" -le 10 ] || need=10
	fetch_count=$(batch_size)
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
	if [ "$(ready_count)" -eq 0 ]; then
		if [ "$(provider_name)" = native ]; then
			native_replenish 1 1 || true
		else
			generate_candidates "$(batch_size)" || true
			test_candidates new
		fi
	fi
	for id in $(sorted_ready_entries); do
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
	if [ -x /usr/libexec/awg-warp-auto/activate-worker.uc ]; then
		reply=$(/usr/libexec/awg-warp-auto/activate-worker.uc "$id" "$mode" "op_daemon_$$" 2>/dev/null) || reply='{"ok":false}'
	else
		reply=$(ubus -t 60 call luci.amneziawg activateWarpAutoCandidate "{\"id\":\"$id\",\"health_mode\":\"$mode\"}" 2>/dev/null) || reply='{"ok":false}'
	fi
	file="$GENERATED/activate.$$.json"
	printf '%s' "$reply" > "$file"
	ok=$(read_json "$file" '@.ok')
	rm -f "$file"
	if [ "$ok" = true ]; then
		prune_pool
		log info "activated candidate $id after YouTube verification"
		return 0
	fi
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
	cooldown=$(number "$(option failover_cooldown)" 10)
	last=$(number "$(option last_failover)" 0)
	[ $((current - last)) -ge "$cooldown" ] || { log info 'failover cooldown active'; return 1; }
	for id in $(sorted_ready_entries); do
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
	for id in $(sorted_ready_entries); do
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
	batch) with_lock generate_batch_unlocked "${2:-}" ;;
	native_test) with_lock generate_batch_unlocked 1 ;;
	force_replenish) with_lock force_replenish_unlocked ;;
	clean_replenish) with_lock clean_replenish_unlocked "${2:-}" ;;
	delete) [ "$#" -eq 2 ] && with_lock delete_one "$2" || exit 2 ;;
	*) echo "Usage: $0 {run|cycle|refresh|batch [N]|test_all|bootstrap|native_test|force_replenish|clean_replenish|delete ID|retest ID|activate ID|rollback|failover}" >&2; exit 2 ;;
esac

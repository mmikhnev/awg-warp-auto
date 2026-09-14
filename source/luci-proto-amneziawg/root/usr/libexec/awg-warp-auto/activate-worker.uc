#!/usr/bin/env ucode
'use strict';

import { readfile, writefile, popen, open, stat, unlink } from 'fs';
import { connect } from 'ubus';
import { cursor } from 'uci';

const AUTO_CONFIG = 'awg-warp-auto';
const AUTO_MAIN = 'main';
const AUTO_POOL = '/etc/awg-warp-auto/pool';
const OP_FILE = '/tmp/awg-warp-auto/operation.json';
const LOCK_FILE = '/tmp/awg-warp-auto/activate.lock';
const MAX_CONFIG_SIZE = 64 * 1024;

function shellquote(s) {
	return `'${replace(s ?? "", "'", "'\\''")}'`;
}

function command(cmd) {
	return trim(popen(cmd)?.read?.('all'));
}

function validAutoId(id) {
	return type(id) == 'string' && match(id, /^p_[0-9a-f]{24}$/);
}

function validInterfaceName(name) {
	return type(name) == 'string' && match(name, /^[A-Za-z0-9_]{1,15}$/) ? name : null;
}

function autoNumber(value, fallback, min, max) {
	if (value == null || value === "") return fallback;
	const n = +value;
	if (n != n) return fallback;
	if (min != null && n < min) return fallback;
	if (max != null && n > max) return fallback;
	return n;
}

function autoHealthMode(mode, fallback) {
	return mode == 'direct' || mode == 'strict' ? mode : (fallback ?? 'strict');
}

function autoResources(value) {
	const raw = type(value) == 'array' ? value : split(value ?? "", /[,\s]+/);
	const list = [];
	const seen = {};
	for (let item in raw) {
		const host = trim(item);
		if (!length(host) || length(host) > 253 || index(host, "/") >= 0 || seen[host])
			continue;
		if (match(host, /^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$/)) {
			seen[host] = true;
			push(list, host);
		}
	}
	return length(list) ? list : null;
}

function autoResolvers(value) {
	const raw = type(value) == 'array' ? value : split(value ?? "", /[,\s]+/);
	const list = [];
	const seen = {};
	for (let item in raw) {
		const ip = trim(item);
		if (!length(ip) || seen[ip]) continue;
		if (match(ip, /^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/)) {
			seen[ip] = true;
			push(list, ip);
		}
	}
	return length(list) ? list : [ '77.88.8.8', '77.88.8.1', '8.8.8.8', '1.1.1.1', '9.9.9.9' ];
}

function targetInterface() {
	const uci = cursor();
	if (uci.load(AUTO_CONFIG)) {
		const main = uci.get_all(AUTO_CONFIG, AUTO_MAIN);
		const configured = validInterfaceName(main?.interface);
		if (configured) return configured;
	}
	return 'YTwarp';
}

function managedPeerSection(iface) {
	return `warp_auto_peer_${lc(iface)}`;
}

function peerSectionFor(uci, iface) {
	const targetType = `amneziawg_${iface}`;
	const managed = managedPeerSection(iface);
	let fallback = null;
	let found = null;
	uci.foreach('network', targetType, (section) => {
		const name = section['.name'];
		if (name == managed) found = name;
		else if (!fallback) fallback = name;
	});
	return found ?? fallback;
}

function restoreSection(uci, sectionName, saved) {
	if (!sectionName) return;
	uci.delete('network', sectionName);
	if (!saved || type(saved) != 'object') return;
	const sectionType = saved['.type'];
	if (!sectionType) return;
	uci.set('network', sectionName, sectionType);
	for (let key in saved) {
		if (substr(key, 0, 1) == ".") continue;
		uci.set('network', sectionName, key, saved[key]);
	}
}

function parseList(value, field, requirePrefix) {
	const result = [];
	for (let item in split(value, ",")) {
		item = trim(item);
		if (!length(item) || !match(item, /^[0-9A-Fa-f:.]+(\/[0-9]{1,3})?$/))
			return { ok: false, error: `Invalid ${field}` };
		if (requirePrefix && index(item, "/") < 0)
			return { ok: false, error: `${field} entries must include a prefix` };
		if (!requirePrefix && index(item, "/") < 0)
			item += index(item, ":") >= 0 ? "/128" : "/32";
		push(result, item);
	}
	return { ok: true, values: result };
}

function parseEndpoint(value) {
	let host, port;
	if (substr(value, 0, 1) == "[") {
		const end = index(value, "]");
		if (end < 2 || substr(value, end + 1, 1) != ":")
			return { ok: false, error: "Endpoint must be host:port or [IPv6]:port" };
		host = substr(value, 1, end - 1);
		port = substr(value, end + 2);
	} else {
		const colon = rindex(value, ":");
		if (colon < 1)
			return { ok: false, error: "Endpoint must include a port" };
		host = substr(value, 0, colon);
		port = substr(value, colon + 1);
	}
	if (!length(host) || length(host) > 253 || !match(port, /^[0-9]+$/) || +port < 1 || +port > 65535)
		return { ok: false, error: "Invalid endpoint" };
	return { ok: true, host, port };
}

function parseAwgConfig(text, filename) {
	if (type(text) != 'string' || !length(text))
		return { ok: false, error: "Choose a non-empty AmneziaWG configuration" };
	if (length(text) > MAX_CONFIG_SIZE)
		return { ok: false, error: "Configuration is larger than 64 KiB" };
	if (index(text, "\0") >= 0)
		return { ok: false, error: "Configuration contains a NUL byte" };

	text = replace(text, /^\uFEFF/, "");
	text = replace(text, /\r\n?/g, "\n");

	const sections = { interface: {}, peer: {} };
	const seen = { interface: 0, peer: 0 };
	let current = null;

	for (let raw in split(text, "\n")) {
		const line = trim(raw);
		if (!length(line) || substr(line, 0, 1) == "#" || substr(line, 0, 1) == ";")
			continue;

		if (substr(line, 0, 1) == "[" && substr(line, -1) == "]") {
			const name = lc(trim(substr(line, 1, length(line) - 2)));
			if (name != "interface" && name != "peer")
				return { ok: false, error: `Unsupported section [${name}]` };
			if (++seen[name] != 1)
				return { ok: false, error: `Duplicate [${name}] section` };
			current = name;
			continue;
		}

		const equals = index(line, "=");
		if (!current || equals < 1)
			return { ok: false, error: "Malformed line in configuration" };

		const key = lc(trim(substr(line, 0, equals)));
		const value = trim(substr(line, equals + 1));
		if (!length(key) || !length(value))
			return { ok: false, error: "Empty option name or value" };
		if (sections[current][key] != null)
			return { ok: false, error: `Duplicate option ${key}` };
		sections[current][key] = value;
	}

	if (seen.interface != 1 || seen.peer != 1)
		return { ok: false, error: "Configuration must contain one [Interface] and one [Peer]" };

	const allowedInterface = {
		privatekey: true, address: true, dns: true, mtu: true, listenport: true,
		s1: true, s2: true, s3: true, s4: true, jc: true, jmin: true, jmax: true,
		h1: true, h2: true, h3: true, h4: true,
		i1: true, i2: true, i3: true, i4: true, i5: true,
		headerprotectionkey: true,
		contentpaddingaddition: true, rekeyaftertime: true, rekeytimeout: true,
		rejectaftertime: true, keepalivetimeout: true, maxhandshakeattempts: true,
		randomtrailers: true, disablecookies: true
	};
	const allowedPeer = {
		publickey: true, presharedkey: true, allowedips: true, endpoint: true,
		persistentkeepalive: true
	};
	for (let key in sections.interface)
		if (!allowedInterface[key]) return { ok: false, error: `Unsupported Interface option ${key}` };
	for (let key in sections.peer)
		if (!allowedPeer[key]) return { ok: false, error: `Unsupported Peer option ${key}` };

	const requiredInterface = [ 'privatekey', 'address' ];
	const requiredPeer = [ 'publickey', 'allowedips', 'endpoint' ];
	for (let key in requiredInterface)
		if (!sections.interface[key]) return { ok: false, error: `Missing Interface option ${key}` };
	for (let key in requiredPeer)
		if (!sections.peer[key]) return { ok: false, error: `Missing Peer option ${key}` };

	for (let field in [ 'privatekey', 'publickey' ]) {
		const value = field == 'privatekey' ? sections.interface[field] : sections.peer[field];
		if (!match(value, /^[A-Za-z0-9+\/]{43}=$/))
			return { ok: false, error: `Invalid ${field}` };
	}
	if (sections.peer.presharedkey && !match(sections.peer.presharedkey, /^[A-Za-z0-9+\/]{43}=$/))
		return { ok: false, error: "Invalid presharedkey" };

	const addresses = parseList(sections.interface.address, "Address", false);
	if (!addresses.ok) return addresses;
	const allowedIps = parseList(sections.peer.allowedips, "AllowedIPs", true);
	if (!allowedIps.ok) return allowedIps;
	const endpoint = parseEndpoint(sections.peer.endpoint);
	if (!endpoint.ok) return endpoint;

	return {
		ok: true,
		profile: replace(filename ?? "imported.conf", /\.[^.]+$/, ""),
		interface: sections.interface,
		peer: sections.peer,
		addresses: addresses.values,
		allowed_ips: allowedIps.values,
		endpoint: { host: endpoint.host, port: endpoint.port }
	};
}

function activateAwg(iface) {
	iface = validInterfaceName(iface) ?? targetInterface();
	const bus = connect();
	if (!bus) return false;

	bus.call('network', 'reload', {});
	command(`ifup ${shellquote(iface)} 2>/dev/null`);

	for (let attempt = 0; attempt < 15; attempt++) {
		const status = bus.call(`network.interface.${iface}`, 'status', {});
		if (status?.available == true && status?.up == true) return true;

		bus.call(`network.interface.${iface}`, 'up', {});
		command(`ifup ${shellquote(iface)} 2>/dev/null`);
		command('sleep 1');
	}

	const awgCheck = trim(command(`awg show ${shellquote(iface)} 2>/dev/null`));
	if (length(awgCheck)) return true;

	const devStatus = trim(command(`ip link show dev ${shellquote(iface)} 2>/dev/null`));
	if (length(devStatus) && index(devStatus, 'state UP') >= 0) return true;

	return false;
}

function runtimeHealthCheck(mode, iface) {
	iface = validInterfaceName(iface) ?? targetInterface();
	let timeout = 10;
	let resources = [ 'youtube.com' ];
	let attempts = 2;
	let resolvers = '77.88.8.8 77.88.8.1 8.8.8.8 1.1.1.1 9.9.9.9';
	mode = autoHealthMode(mode, 'strict');
	const uci = cursor();
	if (uci.load(AUTO_CONFIG)) {
		const main = uci.get_all(AUTO_CONFIG, AUTO_MAIN);
		if (main) {
			timeout = autoNumber(main.health_timeout, 10, 3, 30);
			attempts = 1 + autoNumber(main.health_retries, 1, 0, 4);
			const parsed = autoResources(main.critical_resource ?? [ 'youtube.com' ]);
			if (parsed) resources = parsed;
			resolvers = join(" ", autoResolvers(main.health_resolvers));
		}
	}
	let result = "no health-check result";
	for (let attempt = 0; attempt < attempts; attempt++) {
		result = command(`sleep 2; /usr/libexec/awg-warp-auto/health-check.sh ${shellquote(iface)} ${timeout} ${shellquote(join(resources, ","))} ${mode} ${shellquote(resolvers)} 2>&1`);
		const parts = split(trim(result), ' ');
		if (parts[0] == 'OK' && parts[1])
			return { ok: true, detail: result };
	}
	return { ok: false, detail: length(result) ? result : "no health-check result" };
}

/* Main Execution */
const id = ARGV[0];
const configured_health = cursor().get(AUTO_CONFIG, AUTO_MAIN, "health_mode");
const health_mode = autoHealthMode(ARGV[1] ?? configured_health, "direct");
const op_id = ARGV[2] ?? sprintf("op_act_%d", time());

if (!validAutoId(id)) {
	print(sprintf("{\"ok\":false,\"error\":\"Invalid candidate ID %s\"}\n", id ?? ""));
	exit(1);
}

command("mkdir -p /tmp/awg-warp-auto");

/* Atomic activation lock */
const lock_handle = open(LOCK_FILE, "w");
if (!lock_handle || !lock_handle.lock("nx")) {
	print("{\"ok\":false,\"error\":\"Another activation is already in progress\",\"code\":\"operation_in_progress\"}\n");
	exit(1);
}

/* Worker PID */
const my_pid = int(trim(popen("echo $PPID")?.read?.("all")));

function releaseLock() {
	if (lock_handle) {
		try { lock_handle.lock("u"); } catch(e) {}
		try { lock_handle.close(); } catch(e) {}
	}
	try { unlink(LOCK_FILE); } catch(e) {}
}

function writeOp(status, step, error) {
	const doc = {
		operation_id: op_id,
		action: "activate",
		candidate_id: id,
		status: status,
		step: step,
		error: error,
		pid: my_pid,
		updated_at: time()
	};
	writefile(OP_FILE, sprintf("%J\n", doc));
}

const confPath = `${AUTO_POOL}/${id}.conf`;
const confText = readfile(confPath);
if (!confText) {
	writeOp("failed", "completed", "Candidate configuration file missing");
	releaseLock();
	print("{\"ok\":false,\"error\":\"Candidate configuration file missing\"}\n");
	exit(1);
}

const parsed = parseAwgConfig(confText, `${id}.conf`);
if (!parsed.ok) {
	writeOp("failed", "completed", parsed.error);
	releaseLock();
	print(sprintf("{\"ok\":false,\"error\":%s}\n", sprintf("%J", parsed.error)));
	exit(1);
}

const iface = targetInterface();
const uci = cursor();
uci.load("network");
const peerSection = peerSectionFor(uci, iface);
const managedPeer = managedPeerSection(iface);
const oldInterface = uci.get_all("network", iface);
const oldPeer = peerSection ? uci.get_all("network", peerSection) : null;

writeOp("running", "applying", null);

uci.delete("network", iface);
if (peerSection) uci.delete("network", peerSection);
if (managedPeer != peerSection) uci.delete("network", managedPeer);

uci.set("network", iface, "interface");
uci.set("network", iface, "proto", "amneziawg");
uci.set("network", iface, "auto", "1");
uci.set("network", iface, "nohostroute", "1");
uci.set("network", iface, "defaultroute", "0");
uci.set("network", iface, "peerdns", "0");
uci.set("network", iface, "private_key", parsed.interface.privatekey);
uci.set("network", iface, "listen_port", "51821");
uci.set("network", iface, "fwmark", "0x01000000");
uci.set("network", iface, "mtu", parsed.interface.mtu);
uci.set("network", iface, "addresses", parsed.addresses);
for (let field in [ "jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5",
                    "headerprotectionkey",
                    "contentpaddingaddition", "rekeyaftertime", "rekeytimeout", "rejectaftertime", "keepalivetimeout", "maxhandshakeattempts",
                    "randomtrailers", "disablecookies" ])
	if (parsed.interface[field] != null) uci.set("network", iface, `awg_${field}`, parsed.interface[field]);

uci.set("network", managedPeer, `amneziawg_${iface}`);
uci.set("network", managedPeer, "description", parsed.profile);
uci.set("network", managedPeer, "public_key", parsed.peer.publickey);
uci.set("network", managedPeer, "route_allowed_ips", "0");
uci.set("network", managedPeer, "endpoint_host", parsed.endpoint.host);
uci.set("network", managedPeer, "endpoint_port", parsed.endpoint.port);
uci.set("network", managedPeer, "allowed_ips", parsed.allowed_ips);
if (parsed.peer.presharedkey) uci.set("network", managedPeer, "preshared_key", parsed.peer.presharedkey);
if (parsed.peer.persistentkeepalive) uci.set("network", managedPeer, "persistent_keepalive", parsed.peer.persistentkeepalive);

const egressName = `${lc(iface)}_ipv4_egress`;
const markName = `${lc(iface)}_ipv4_mark`;
if (!uci.get("network", egressName)) {
	uci.set("network", egressName, "route");
	uci.set("network", egressName, "interface", iface);
	uci.set("network", egressName, "target", "0.0.0.0/0");
	uci.set("network", egressName, "table", "101");
}
if (!uci.get("network", markName)) {
	uci.set("network", markName, "rule");
	uci.set("network", markName, "priority", "104");
	uci.set("network", markName, "mark", "0x08000000/0x08000000");
	uci.set("network", markName, "lookup", "101");
}

if (!uci.commit("network")) {
	restoreSection(uci, iface, oldInterface);
	restoreSection(uci, managedPeer, oldPeer);
	uci.commit("network");
	writeOp("failed", "completed", "Unable to commit network configuration");
	releaseLock();
	print("{\"ok\":false,\"error\":\"Unable to commit network configuration\"}\n");
	exit(1);
}

const activated = activateAwg(iface);
if (!activated) {
	writeOp("running", "rolling_back", "Interface did not become available");
	const rollback = cursor();
	rollback.load("network");
	restoreSection(rollback, iface, oldInterface);
	restoreSection(rollback, managedPeer, oldPeer);
	rollback.commit("network");
	activateAwg(iface);

	const autoUci = cursor();
	autoUci.load(AUTO_CONFIG);
	const prev_fails = autoNumber(autoUci.get(AUTO_CONFIG, id, "failure_count"), 0);
	autoUci.set(AUTO_CONFIG, id, "status", "FAILED");
	autoUci.set(AUTO_CONFIG, id, "last_error", "interface_activation_failed");
	autoUci.set(AUTO_CONFIG, id, "failure_count", sprintf("%d", prev_fails + 1));
	autoUci.commit(AUTO_CONFIG);

	writeOp("rolled_back", "completed", "Interface did not become available");
	releaseLock();
	print("{\"ok\":false,\"error\":\"Interface did not become available; previous profile restored\",\"rolled_back\":true}\n");
	exit(1);
}

writeOp("running", "health_check", null);
const health = runtimeHealthCheck(health_mode, iface);

if (health.ok) {
	const autoUci = cursor();
	autoUci.load(AUTO_CONFIG);
	const old_active = autoUci.get(AUTO_CONFIG, AUTO_MAIN, "active_id");
	if (validAutoId(old_active) && old_active != id) {
		autoUci.set(AUTO_CONFIG, old_active, "status", "READY");
		autoUci.set(AUTO_CONFIG, AUTO_MAIN, "previous_active_id", old_active);
	}
	const now_ts = sprintf("%d", time());
	autoUci.set(AUTO_CONFIG, id, "status", "ACTIVE");
	autoUci.set(AUTO_CONFIG, id, "failure_count", "0");
	autoUci.set(AUTO_CONFIG, id, "health_state", "OK");
	autoUci.set(AUTO_CONFIG, id, "last_health", now_ts);
	autoUci.set(AUTO_CONFIG, AUTO_MAIN, "active_id", id);
	autoUci.set(AUTO_CONFIG, AUTO_MAIN, "last_activation", now_ts);
	autoUci.commit(AUTO_CONFIG);

	writeOp("success", "completed", null);
	releaseLock();
	print(sprintf("{\"ok\":true,\"id\":\"%s\",\"profile\":\"%s\",\"endpoint\":\"%s:%s\"}\n", id, parsed.profile, parsed.endpoint.host, parsed.endpoint.port));
	exit(0);
}

/* Health check failed -> Rollback */
writeOp("running", "rolling_back", health.detail);

const rollback = cursor();
rollback.load("network");
restoreSection(rollback, iface, oldInterface);
restoreSection(rollback, managedPeer, oldPeer);
rollback.commit("network");
activateAwg(iface);

const autoUci = cursor();
autoUci.load(AUTO_CONFIG);
const prev_fails = autoNumber(autoUci.get(AUTO_CONFIG, id, "failure_count"), 0);
if (prev_fails >= 2) {
	autoUci.set(AUTO_CONFIG, id, "status", "FAILED");
} else {
	autoUci.set(AUTO_CONFIG, id, "status", "READY");
}
autoUci.set(AUTO_CONFIG, id, "last_error", "activation_health_failed");
autoUci.set(AUTO_CONFIG, id, "failure_count", sprintf("%d", prev_fails + 1));
autoUci.commit(AUTO_CONFIG);

writeOp("rolled_back", "completed", health.detail);
releaseLock();
print(sprintf("{\"ok\":false,\"error\":%s,\"rolled_back\":true}\n", sprintf("%J", `Health check failed (${health.detail}); the previous profile was restored`)));
exit(1);

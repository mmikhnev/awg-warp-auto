#!/usr/bin/env ucode

/*
 * Command entrypoint for warp-gen-provider.uc.
 *
 * The daemon passes only validated -D variables.  Candidate configs are
 * written into the private output directory and never placed on stdout; the
 * JSON response contains metadata and safe file paths only.
 */
'use strict';

let fs = require('fs');

function safe_string(value, fallback) {
	return value == null ? fallback : '' + value;
}

function safe_number(value, fallback, minimum, maximum) {
	value = safe_string(value, '');
	if (!match(value, /^[0-9]+$/))
		return fallback;
	value = int(value, 10);
	return value < minimum || value > maximum ? fallback : value;
}

function fail(code, message) {
	print(sprintf('%J', { ok: false, error: { code, message } }));
}

let directory = safe_string(outdir, '');
if (!match(directory, /^\/tmp\/awg-warp-auto\/generated$/)) {
	fail('INVALID_OUTPUT_DIR', 'Invalid private output directory');
	return;
}

let result = warpgen.fetch_configs({
	source_url: safe_string(source_url, ''),
	timeout: safe_number(timeout, 12, 3, 60),
	limit: safe_number(limit, 3, 1, 8),
	include_ipv6: safe_string(include_ipv6, '0'),
	allowed_ips: '0.0.0.0/0, ::/0'
});

if (!result.ok) {
	print(sprintf('%J', result));
	return;
}

let entries = [];
for (let index = 0; index < length(result.configs); index++) {
	let candidate = result.configs[index];
	let name = 'generated-' + index + '.conf';
	let path = directory + '/' + name;
	if (!fs.writefile(path, candidate.config)) {
		fail('WRITE_FAILED', 'Unable to store generated candidate privately');
		return;
	}
	push(entries, {
		profile: candidate.profile,
		endpoint: candidate.endpoint,
		source: candidate.source,
		source_id: candidate.source_id,
		path
	});
}

print(sprintf('%J', {
	ok: true,
	provider: result.provider,
	source_url: result.source_url,
	script_url: result.script_url,
	configs: entries
}));

/*
 * WARP generator provider.
 *
 * This module deliberately never evaluates downloaded JavaScript.  It reads the
 * public page and its declared script as data, extracts the WARP API list plus
 * AWG templates, then returns in-memory .conf candidates to the caller.
 * Callers must not log the `config` member returned by fetch_configs().
 */

'use strict';

let fs = require('fs');

let DEFAULT_SOURCE_URL = 'https://warp-generation.github.io/';
let DEFAULT_TIMEOUT_SECONDS = 12;
let MAX_SOURCE_BYTES = 512 * 1024;
let MAX_SCRIPT_BYTES = 2 * 1024 * 1024;
let MAX_API_BYTES = 64 * 1024;
let MAX_SCRIPT_CANDIDATES = 8;

function as_string(value) {
	return value == null ? '' : '' + value;
}

function option(options, name, fallback) {
	if (type(options) != 'object' || options[name] == null)
		return fallback;
	return options[name];
}

function failure(code, message, extra) {
	let error = { code, message };
	if (type(extra) == 'object')
		for (let key in extra)
			error[key] = extra[key];
	return { ok: false, provider: 'warp-gen', error };
}

function contains(values, value) {
	for (let item in values)
		if (item == value)
			return true;
	return false;
}

function push_unique(values, value) {
	if (!contains(values, value))
		push(values, value);
}

function find_from(text, needle, offset) {
	let relative = index(substr(text, offset), needle);
	return relative < 0 ? -1 : offset + relative;
}

function clamp_number(value, fallback, minimum, maximum) {
	value = as_string(value);
	if (!match(value, /^[0-9]+$/))
		return fallback;
	value = int(value, 10);
	if (value < minimum)
		return minimum;
	if (value > maximum)
		return maximum;
	return value;
}

function shellquote(value) {
	/* source_url() admits only shell-safe URL characters */
	return '"' + as_string(value) + '"';
}

function is_space(character) {
	return index(' \t\r\n\f', character) >= 0;
}

function is_name_character(character) {
	return index('abcdefghijklmnopqrstuvwxyz0123456789:_-', lc(character)) >= 0;
}

function is_authority_character(character) {
	return index('abcdefghijklmnopqrstuvwxyz0123456789.-:[]', lc(character)) >= 0;
}

function is_url_character(character) {
	return index('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]/_?&=%,#', character) >= 0;
}

function first_url_delimiter(url, offset) {
	let result = -1;
	for (let delimiter in [ '/', '?', '#' ]) {
		let found = find_from(url, delimiter, offset);
		if (found >= 0 && (result < 0 || found < result))
			result = found;
	}
	return result;
}

function source_url(value) {
	let url = trim(as_string(value));
	if (!length(url))
		url = DEFAULT_SOURCE_URL;

	/* HTTPS is intentional: a source script controls the generated tunnel data. */
	if (lc(substr(url, 0, length('https://'))) != 'https://')
		return failure('INVALID_SOURCE_URL', 'Config source URL must be an absolute HTTPS URL');
	for (let position = 0; position < length(url); position++)
		if (!is_url_character(substr(url, position, 1)))
			return failure('INVALID_SOURCE_URL', 'Config source URL contains unsafe characters');

	let authority_start = length('https://');
	let path_start = first_url_delimiter(url, authority_start);
	let authority = path_start < 0 ? substr(url, authority_start) : substr(url, authority_start, path_start - authority_start);
	if (!length(authority) || index(authority, '@') >= 0)
		return failure('INVALID_SOURCE_URL', 'Config source URL has an invalid authority');
	for (let position = 0; position < length(authority); position++)
		if (!is_authority_character(substr(authority, position, 1)))
			return failure('INVALID_SOURCE_URL', 'Config source URL has an invalid authority');

	let host = lc(authority);
	if (substr(host, 0, 1) == '[') {
		let close = index(host, ']');
		if (close < 0)
			return failure('INVALID_SOURCE_URL', 'Config source URL has an invalid IPv6 host');
		host = substr(host, 1, close - 1);
	}
	else {
		let colon = rindex(host, ':');
		if (colon >= 0)
			host = substr(host, 0, colon);
	}

	if (host == 'localhost' || host == '::1' || host == '::' ||
		match(host, /^(fc|fd|fe80:)/i) ||
		match(host, /^(0|10|127)\./) ||
		match(host, /^169\.254\./) ||
		match(host, /^192\.168\./) ||
		match(host, /^172\.(1[6-9]|2[0-9]|3[0-1])\./))
		return failure('UNSAFE_SOURCE_URL', 'Config source URL must not target a local or private address');

	return { ok: true, url };
}

function url_origin(url) {
	let authority_start = index(url, '://') + 3;
	let path_start = first_url_delimiter(url, authority_start);
	return path_start < 0 ? url : substr(url, 0, path_start);
}

function resolve_url(base, reference) {
	reference = trim(as_string(reference));
	if (!length(reference) || match(reference, /^(data|javascript):/i))
		return null;
	if (match(reference, /^https:\/\//i))
		return source_url(reference).ok ? reference : null;
	if (substr(reference, 0, 2) == '//')
		return source_url('https:' + reference).ok ? 'https:' + reference : null;
	if (substr(reference, 0, 1) == '/')
		return source_url(url_origin(base) + reference).ok ? url_origin(base) + reference : null;

	let suffix = -1;
	for (let delimiter in [ '?', '#' ]) {
		let found = index(base, delimiter);
		if (found >= 0 && (suffix < 0 || found < suffix))
			suffix = found;
	}
	let clean_base = suffix < 0 ? base : substr(base, 0, suffix);
	let origin = url_origin(clean_base);
	let slash = rindex(clean_base, '/');
	let directory = slash < length(origin) ? origin + '/' : substr(clean_base, 0, slash + 1);
	let candidate = directory + reference;
	return source_url(candidate).ok ? candidate : null;
}

function fetch_text(url, max_bytes, timeout) {
	let checked = source_url(url);
	if (!checked.ok)
		return checked;

	timeout = clamp_number(timeout, DEFAULT_TIMEOUT_SECONDS, 3, 60);
	max_bytes = clamp_number(max_bytes, MAX_SOURCE_BYTES, 1024, 4 * 1024 * 1024);
	let marker = '__AWG_WARP_AUTO_EFFECTIVE_URL__';
	let command = 'curl -f -sS -L --proto \"=https\" --proto-redir \"=https\" ' +
		'--connect-timeout ' + timeout + ' --max-time ' + timeout +
		' --max-redirs 3 --max-filesize ' + max_bytes +
		' -A ' + shellquote('OpenWrt-AWG-WARP-Auto/1.0') +
		' -H ' + shellquote('X-Client: WARP') +
		' -w ' + shellquote(marker + '%{url_effective}') +
		' ' + shellquote(checked.url) + ' 2>/dev/null';
	let pipe = fs.popen(command, 'r');
	let data = pipe ? pipe.read('all') : null;
	if (pipe)
		pipe.close();
	if (data == null)
		return failure('FETCH_FAILED', 'Source request failed');

	let marker_at = rindex(data, marker);
	if (marker_at < 0)
		return failure('FETCH_FAILED', 'Source request returned no usable response');
	let body = substr(data, 0, marker_at);
	let effective_url = trim(substr(data, marker_at + length(marker)));
	let effective_check = source_url(effective_url);
	if (!effective_check.ok)
		return failure('UNSAFE_REDIRECT', 'Source request redirected to an unsafe URL');
	if (!length(body))
		return failure('EMPTY_RESPONSE', 'Source request returned an empty response');
	if (length(body) > max_bytes)
		return failure('RESPONSE_TOO_LARGE', 'Source response exceeded its size limit');

	return { ok: true, body, url: effective_check.url };
}

function read_attribute(tag, wanted_name) {
	let position = 0;
	wanted_name = lc(wanted_name);
	while (position < length(tag)) {
		while (position < length(tag) && is_space(substr(tag, position, 1)))
			position++;
		let current = substr(tag, position, 1);
		if (!length(current) || current == '>' || current == '/')
			break;

		let name_start = position;
		while (position < length(tag) && is_name_character(substr(tag, position, 1)))
			position++;
		if (position == name_start) {
			position++;
			continue;
		}
		let name = lc(substr(tag, name_start, position - name_start));
		while (position < length(tag) && is_space(substr(tag, position, 1)))
			position++;
		if (substr(tag, position, 1) != '=')
			continue;
		position++;
		while (position < length(tag) && is_space(substr(tag, position, 1)))
			position++;

		let quote = substr(tag, position, 1);
		let value_start = position;
		let value_end = position;
		if (quote == '\'' || quote == '"') {
			value_start++;
			position++;
			while (position < length(tag) && substr(tag, position, 1) != quote)
				position++;
			value_end = position;
			if (position < length(tag))
				position++;
		}
		else {
			while (position < length(tag) && !is_space(substr(tag, position, 1)) && substr(tag, position, 1) != '>')
				position++;
			value_end = position;
		}

		if (name == wanted_name)
			return substr(tag, value_start, value_end - value_start);
	}
	return null;
}

function discover_script_urls(html, base_url) {
	let urls = [];
	let lower = lc(html);
	let position = 0;
	while (position < length(lower) && length(urls) < MAX_SCRIPT_CANDIDATES) {
		let start = find_from(lower, '<script', position);
		if (start < 0)
			break;
		let end = find_from(lower, '>', start + 7);
		if (end < 0)
			break;
		let src = read_attribute(substr(html, start, end - start + 1), 'src');
		let resolved = src == null ? null : resolve_url(base_url, src);
		if (resolved != null)
			push_unique(urls, resolved);
		position = end + 1;
	}
	return urls;
}

function select_script_urls(urls) {
	let selected = [];
	for (let url in urls)
		if (match(url, /(^|\/)script[.]js([?#]|$)/i))
			push_unique(selected, url);
	for (let url in urls)
		if (match(url, /(warp|amnezia)/i))
			push_unique(selected, url);
	for (let url in urls)
		push_unique(selected, url);
	return selected;
}

function extract_urls(text) {
	let urls = [];
	let position = 0;
	while (position < length(text)) {
		let https_at = find_from(text, 'https://', position);
		let http_at = find_from(text, 'http://', position);
		let start;
		if (https_at < 0)
			start = http_at;
		else if (http_at < 0)
			start = https_at;
		else
			start = https_at < http_at ? https_at : http_at;
		if (start < 0)
			break;

		let end = start;
		while (end < length(text)) {
			let character = substr(text, end, 1);
			if (is_space(character) || index('\'"`<>()[]{};,', character) >= 0)
				break;
			end++;
		}
		let candidate = substr(text, start, end - start);
		let checked = source_url(candidate);
		if (checked.ok)
			push_unique(urls, checked.url);
		position = end + 1;
	}
	return urls;
}

function quoted_strings(text) {
	let values = [];
	let position = 0;
	while (position < length(text)) {
		let quote = substr(text, position, 1);
		if (quote != '\'' && quote != '"') {
			position++;
			continue;
		}
		position++;
		let value = '';
		let escaped = false;
		while (position < length(text)) {
			let character = substr(text, position, 1);
			position++;
			if (escaped) {
				value += character;
				escaped = false;
			}
			else if (character == '\\') {
				escaped = true;
			}
			else if (character == quote) {
				break;
			}
			else {
				value += character;
			}
		}
		if (length(value))
			push(values, value);
	}
	return values;
}

function extract_number_array(text, marker) {
	let marker_at = index(text, marker);
	if (marker_at < 0)
		return [];
	let open = find_from(text, '[', marker_at + length(marker));
	let close = open < 0 ? -1 : find_from(text, ']', open + 1);
	if (open < 0 || close < 0)
		return [];

	let values = [];
	let number = '';
	let contents = substr(text, open + 1, close - open - 1);
	for (let index = 0; index < length(contents); index++) {
		let character = substr(contents, index, 1);
		if (match(character, /^[0-9]$/)) {
			number += character;
		}
		else if (length(number)) {
			let value = int(number, 10);
			if (value > 0 && value <= 65535)
				push_unique(values, value);
			number = '';
		}
	}
	if (length(number)) {
		let value = int(number, 10);
		if (value > 0 && value <= 65535)
			push_unique(values, value);
	}
	return values;
}

function extract_interface_defaults(block) {
	let defaults = {};
	for (let name in [ 'mtu', 's1', 's2', 's3', 's4', 'jc', 'jmin', 'jmax', 'h1', 'h2', 'h3', 'h4' ]) {
		let key = uc(substr(name, 0, 1)) + substr(name, 1);
		let lower = lc(block);
		let marker = lc(key) + ' =';
		let position = 0;
		let found = null;
		while ((position = find_from(lower, marker, position)) >= 0) {
			let start = position + length(marker);
			while (is_space(substr(block, start, 1)))
				start++;
			let end = start;
			while (match(substr(block, end, 1), /^[0-9]$/))
				end++;
			let value = substr(block, start, end - start);
			if (length(value)) {
				found = int(value, 10);
				break;
			}
			position = start + 1;
		}
		if (found == null)
			/* The current source renders MTU through a UI variable (${mtuVal}).
			 * Its AWG profiles use the standard conservative 1280-byte MTU. */
			if (name == 'mtu' && find_from(lower, 'mtu = ${', 0) >= 0)
				found = 1280;
			else
				return null;
		defaults[name] = found;
	}
	return defaults;
}

/* Current generator embeds I1..I5 in quoted iNValue strings, rather than
 * assigning the tags to individual variables. Keep only complete <...> tags. */
function extract_embedded_i_fields(block) {
	let fields = [];
	let lower = lc(block);
	for (let number = 1; number <= 5; number++) {
		let name = 'i' + number;
		let marker = name + ' = <';
		let position = 0;
		while ((position = find_from(lower, marker, position)) >= 0) {
			let begin = position + length(name) + 3;
			let finish = find_from(block, '>', begin);
			if (finish > begin) {
				let value = trim(substr(block, begin, finish - begin + 1));
				if (length(value) <= 16384 && !match(value, /[^\x20-\x7e]/)) {
					push(fields, { name, value });
					break;
				}
			}
			position += length(marker);
		}
	}
	return fields;
}

function extract_i_fields(block) {
	let fields = [];
	let lower = lc(block);
	for (let number = 1; number <= 5; number++) {
		let name = 'i' + number;
		let marker = name + ' =';
		let position = 0;
		let value = null;
		while ((position = find_from(lower, marker, position)) >= 0) {
			let line_end = find_from(block, '\n', position);
			if (line_end < 0)
				line_end = length(block);
			let line = substr(block, position, line_end - position);
			let field_at = rindex(lc(line), name + ' =');
			let start = field_at < 0 ? 0 : field_at + length(name) + 2;
			let begin = find_from(line, '<', start);
			let finish = rindex(line, '>');
			if (field_at >= 0 && begin >= start && finish > begin) {
				let candidate = trim(substr(line, begin, finish - begin + 1));
				if (length(candidate) <= 16384 && !match(candidate, /[^\x20-\x7e]/)) {
					value = candidate;
					break;
				}
			}
			position = line_end + 1;
		}
		if (value != null)
			push(fields, { name, value });
	}
	return fields;
}

/* Current source uses one generateWireGuardConfig(version) function instead
 * of separate WARPv1/WARPv2/WARPv3 blocks. Parse each static branch only. */
function extract_generic_variants(script) {
	let lower = lc(script);
	let start = index(lower, 'function generatewireguardconfig(');
	if (start < 0)
		return [];
	let end = find_from(lower, 'function ', start + length('function generatewireguardconfig('));
	if (end < 0)
		end = start + 131072 < length(script) ? start + 131072 : length(script);
	let block = substr(script, start, end - start);
	let defaults = extract_interface_defaults(block);
	if (defaults == null)
		return [];
	let variants = [];
	for (let version = 1; version <= 3; version++) {
		let marker = `version === ${version}`;
		let branch_start = index(lc(block), marker);
		if (branch_start < 0)
			continue;
		let branch_end = find_from(lc(block), 'version === ', branch_start + length(marker));
		if (branch_end < 0)
			branch_end = find_from(lc(block), 'const keeptoggle', branch_start);
		if (branch_end < 0)
			branch_end = length(block);
		let i_fields = extract_embedded_i_fields(substr(block, branch_start, branch_end - branch_start));
		if (length(i_fields))
			push(variants, { id: 'v' + version, profile: 'WARPv' + version, interface: defaults, i_fields });
	}
	return variants;
}

function extract_variants(script) {
	let variants = [];
	let lower = lc(script);
	let position = 0;
	while ((position = find_from(lower, 'getconfigfilename', position)) >= 0) {
		let search_end = position + 256 < length(script) ? position + 256 : length(script);
		let name_at = find_from(lower, 'warpv', position);
		if (name_at < 0 || name_at >= search_end) {
			position += length('getconfigfilename');
			continue;
		}
		let number_start = name_at + length('warpv');
		let number_end = number_start;
		while (match(substr(script, number_end, 1), /^[0-9]$/))
			number_end++;
		let version = substr(script, number_start, number_end - number_start);
		let profile = 'WARPv' + version;
		let duplicate = false;
		for (let variant in variants)
			if (variant.profile == profile)
				duplicate = true;
		if (!length(version) || duplicate) {
			position = number_end;
			continue;
		}

		let before = substr(script, 0, position);
		let block_start = rindex(before, '// AWG');
		if (block_start < 0)
			block_start = position > 24576 ? position - 24576 : 0;
		let next = find_from(script, '// AWG', position + length('getconfigfilename'));
		let block_end = next < 0 ? (position + 24576 < length(script) ? position + 24576 : length(script)) : next;
		let block = substr(script, block_start, block_end - block_start);
		let defaults = extract_interface_defaults(block);
		let i_fields = extract_i_fields(block);
		if (defaults != null && length(i_fields))
			push(variants, { id: 'v' + version, profile, interface: defaults, i_fields });
		position = number_end;
	}
	return length(variants) ? variants : extract_generic_variants(script);
}

function extract_endpoint_generator(script) {
	let lower = lc(script);
	let start = index(lower, 'function generaterandomendpoint');
	if (start < 0)
		return null;
	let end = find_from(lower, 'function getselectedserver', start);
	if (end < 0)
		end = start + 16384 < length(script) ? start + 16384 : length(script);
	let block = substr(script, start, end - start);
	let ports = extract_number_array(block, 'const ports');
	let prefixes_at = index(block, 'const prefixes');
	let hosts = [];
	if (prefixes_at >= 0) {
		let open = find_from(block, '[', prefixes_at);
		let close = open < 0 ? -1 : find_from(block, ']', open + 1);
		if (open >= 0 && close >= 0) {
			for (let value in quoted_strings(substr(block, open + 1, close - open - 1))) {
				value = trim(value);
				if (match(value, /^([A-Za-z0-9.-]+|[0-9]{1,3}[.])$/))
					push_unique(hosts, value);
			}
		}
	}
	if (!length(ports) || !length(hosts))
		return null;
	return { ports, hosts };
}

function extract_metadata(script) {
	let lower = lc(script);
	let start = index(lower, 'fetchfullconfig');
	if (start < 0)
		return failure('WARP_API_NOT_FOUND', 'Generator script has no WARP config fetch function');
	let end = find_from(lower, 'fetchfullconfigmsq', start + length('fetchfullconfig'));
	if (end < 0)
		end = start + 16384 < length(script) ? start + 16384 : length(script);
	let api_endpoints = extract_urls(substr(script, start, end - start));
	if (!length(api_endpoints))
		return failure('WARP_API_NOT_FOUND', 'Generator script has no usable WARP API endpoint');

	let variants = extract_variants(script);
	if (!length(variants))
		return failure('AWG_TEMPLATE_NOT_FOUND', 'Generator script has no usable AWG 2.0 template');
	let endpoint_generator = extract_endpoint_generator(script);
	if (endpoint_generator == null)
		return failure('ENDPOINT_GENERATOR_NOT_FOUND', 'Generator script has no usable endpoint generator');

	return { ok: true, api_endpoints, variants, endpoint_generator };
}

function discover(options) {
	let source = source_url(option(options, 'source_url', DEFAULT_SOURCE_URL));
	if (!source.ok)
		return source;
	let timeout = clamp_number(option(options, 'timeout', DEFAULT_TIMEOUT_SECONDS), DEFAULT_TIMEOUT_SECONDS, 3, 60);
	let page = fetch_text(source.url, MAX_SOURCE_BYTES, timeout);
	if (!page.ok)
		return failure('SOURCE_FETCH_FAILED', 'Cannot fetch config source', { cause: page.error.code });

	let script_urls = select_script_urls(discover_script_urls(page.body, page.url));
	if (!length(script_urls))
		return failure('SCRIPT_NOT_FOUND', 'Config source declares no external JavaScript');

	let saw_fetch_error = false;
	for (let script_url in script_urls) {
		let script = fetch_text(script_url, MAX_SCRIPT_BYTES, timeout);
		if (!script.ok) {
			saw_fetch_error = true;
			continue;
		}
		let metadata = extract_metadata(script.body);
		if (!metadata.ok)
			continue;
		return {
			ok: true,
			provider: 'warp-gen',
			source_url: page.url,
			script_url: script.url,
			api_endpoints: metadata.api_endpoints,
			variants: metadata.variants,
			endpoint_generator: metadata.endpoint_generator
		};
	}

	return failure(saw_fetch_error ? 'SCRIPT_FETCH_FAILED' : 'SCRIPT_UNRECOGNIZED',
		'Config source script does not expose a supported AWG 2.0 flow');
}

function api_value(data, names) {
	if (type(data) != 'object')
		return null;
	for (let name in names)
		if (data[name] != null && length(trim(as_string(data[name]))))
			return trim(as_string(data[name]));
	return null;
}

function valid_key(value) {
	return value != null && match(value, /^[A-Za-z0-9+\/]{43}=$/);
}

function valid_address(value) {
	return value != null && match(value, /^[0-9A-Fa-f:.]+(\/[0-9]{1,3})?$/);
}

function normalize_api_response(text) {
	let data;
	try {
		data = json(text);
	}
	catch (error) {
		return failure('INVALID_API_RESPONSE', 'WARP API did not return JSON');
	}
	let private_key = api_value(data, [ 'privKey', 'privateKey', 'private_key' ]);
	let public_key = api_value(data, [ 'peer_pub', 'peerPublicKey', 'peer_public_key', 'public_key' ]);
	let ipv4 = api_value(data, [ 'client_ipv4', 'clientIPv4', 'ipv4', 'address' ]);
	let ipv6 = api_value(data, [ 'client_ipv6', 'clientIPv6', 'ipv6' ]);
	if (!valid_key(private_key) || !valid_key(public_key) || !valid_address(ipv4))
		return failure('INVALID_API_RESPONSE', 'WARP API response lacks valid tunnel fields');
	if (ipv6 != null && !valid_address(ipv6))
		ipv6 = null;
	return { ok: true, private_key, public_key, ipv4, ipv6 };
}

function choose_endpoint(generator, index_seed) {
	/* Follow the endpoint pool published by warp-gen. Do not pin one server:
	 * reachability varies by network and the candidate probe decides health. */
	let host = generator.hosts[index_seed % length(generator.hosts)];
	let port = generator.ports[(index_seed * 17 + 11) % length(generator.ports)];
	if (substr(host, -1) == '.')
		host += ((index_seed * 7) % 10) + 1;
	return host + ':' + port;
}

function allowed_ips(options, include_ipv6) {
	let value = trim(as_string(option(options, 'allowed_ips', include_ipv6 ? '0.0.0.0/0, ::/0' : '0.0.0.0/0')));
	if (!match(value, /^[0-9A-Fa-f:.,\/ \t]+$/))
		return null;
	return value;
}

function make_config(api, variant, endpoint, allowed, include_ipv6) {
	let config = '[Interface]\n' +
		'PrivateKey = ' + api.private_key + '\n' +
		'Address = ' + api.ipv4 + (include_ipv6 && api.ipv6 != null ? ', ' + api.ipv6 : '') + '\n' +
		'MTU = ' + variant.interface.mtu + '\n' +
		'S1 = ' + variant.interface.s1 + '\n' +
		'S2 = ' + variant.interface.s2 + '\n' +
		'S3 = ' + variant.interface.s3 + '\n' +
		'S4 = ' + variant.interface.s4 + '\n' +
		'Jc = ' + variant.interface.jc + '\n' +
		'Jmin = ' + variant.interface.jmin + '\n' +
		'Jmax = ' + variant.interface.jmax + '\n' +
		'H1 = ' + variant.interface.h1 + '\n' +
		'H2 = ' + variant.interface.h2 + '\n' +
		'H3 = ' + variant.interface.h3 + '\n' +
		'H4 = ' + variant.interface.h4 + '\n';
	for (let field in variant.i_fields)
		config += uc(substr(field.name, 0, 1)) + substr(field.name, 1) + ' = ' + field.value + '\n';
	return config + '\n[Peer]\n' +
		'PublicKey = ' + api.public_key + '\n' +
		'AllowedIPs = ' + allowed + '\n' +
		'Endpoint = ' + endpoint + '\n';
}

function fetch_configs(options) {
	let metadata = discover(options);
	if (!metadata.ok)
		return metadata;
	let timeout = clamp_number(option(options, 'timeout', DEFAULT_TIMEOUT_SECONDS), DEFAULT_TIMEOUT_SECONDS, 3, 60);
	let include_ipv6 = option(options, 'include_ipv6', false) == true || option(options, 'include_ipv6', false) == '1';
	let allowed = allowed_ips(options, include_ipv6);
	if (allowed == null)
		return failure('INVALID_ALLOWED_IPS', 'AllowedIPs override is invalid');

	let api = null;
	let api_url = null;
	for (let endpoint in metadata.api_endpoints) {
		let response = fetch_text(endpoint, MAX_API_BYTES, timeout);
		if (!response.ok)
			continue;
		let parsed = normalize_api_response(response.body);
		if (parsed.ok) {
			api = parsed;
			api_url = response.url;
			break;
		}
	}
	if (api == null)
		return failure('WARP_API_UNAVAILABLE', 'No discovered WARP API returned a valid config');

	let limit = clamp_number(option(options, 'limit', length(metadata.variants)), length(metadata.variants), 1, 8);
	let configs = [];
	/* The site randomizes endpoint separately from AWG variant. One unlucky
	 * endpoint must not make a whole refresh look invalid, so spread a bounded
	 * pool across its published endpoint set while retaining every template. */
	for (let i = 0; length(configs) < limit; i++) {
		let variant = metadata.variants[i % length(metadata.variants)];
		let endpoint = choose_endpoint(metadata.endpoint_generator, i + length(api_url));
		push(configs, {
			profile: variant.profile + '_auto',
			source: api_url,
			source_id: variant.id + '@' + endpoint,
			endpoint,
			config: make_config(api, variant, endpoint, allowed, include_ipv6)
		});
	}
	if (!length(configs))
		return failure('NO_CONFIGS_GENERATED', 'No AWG configurations were generated');

	return {
		ok: true,
		provider: 'warp-gen',
		source_url: metadata.source_url,
		script_url: metadata.script_url,
		configs
	};
}

return {
	name: 'warp-gen',
	default_source_url: DEFAULT_SOURCE_URL,
	discover,
	fetch_configs
};

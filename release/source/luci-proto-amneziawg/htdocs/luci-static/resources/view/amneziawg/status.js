'use strict';
'require view';
'require rpc';
'require poll';
'require dom';
'require ui';
'require uci';


var callgetAwgInstances = rpc.declare({
	object: 'luci.amneziawg',
	method: 'getAwgInstances'
});

var callValidateAwgConfig = rpc.declare({
	object: 'luci.amneziawg',
	method: 'validateAwgConfig',
	params: [ 'config', 'filename' ]
});

var callImportAwgConfig = rpc.declare({
	object: 'luci.amneziawg',
	method: 'importAwgConfig',
	params: [ 'config', 'filename', 'interface', 'validate_youtube' ]
});

var callCreateInterface = rpc.declare({
	object: 'luci.amneziawg',
	method: 'createInterface',
	params: [ 'name', 'zone', 'config' ]
});

var callDeleteInterface = rpc.declare({
	object: 'luci.amneziawg',
	method: 'deleteInterface',
	params: [ 'name' ]
});

var callRestartInterface = rpc.declare({
	object: 'luci.amneziawg',
	method: 'restartInterface',
	params: [ 'name' ]
});

var callExportInterfaceConfig = rpc.declare({
	object: 'luci.amneziawg',
	method: 'exportInterfaceConfig',
	params: [ 'name' ]
});

var callGetWarpAutoStatus = rpc.declare({
	object: 'luci.amneziawg',
	method: 'getWarpAutoStatus'
});

var callSaveWarpAutoSettings = rpc.declare({
	object: 'luci.amneziawg',
	method: 'saveWarpAutoSettings',
	params: [ 'settings', 'defer_service' ]
});

var callWarpAutoAction = rpc.declare({
	object: 'luci.amneziawg',
	method: 'warpAutoAction',
	params: [ 'action', 'id' ]
});

var callGetWarpAutoOperation = rpc.declare({
	object: 'luci.amneziawg',
	method: 'getWarpAutoOperation',
	params: [ 'operation_id' ]
});

var DEFAULT_WARP_SOURCE_URL = 'https://warp-generation.github.io';

function readTextFile(file) {
	return new Promise(function(resolve, reject) {
		var reader = new FileReader();
		reader.onload = function() { resolve(reader.result); };
		reader.onerror = function() { reject(new Error(_('Unable to read the selected file'))); };
		reader.readAsText(file, 'UTF-8');
	});
}

function boolValue(value) {
	return value === true || value === 1 || value === '1' || value === 'true';
}

function numberValue(value, fallback) {
	var number = +value;
	return isFinite(number) && number >= 0 ? number : fallback;
}

function autoTimestampToStr(value) {
	if (value == null || value === '' || value === 0 || value === '0')
		return '-';

	var timestamp = +value;
	if (isFinite(timestamp) && timestamp > 0) {
		if (timestamp > 100000000000)
			timestamp /= 1000;
		return timestampToStr(timestamp);
	}

	return String(value);
}

function redactAutoLog(value) {
	return String(value == null ? '' : value)
		.replace(/((?:private|preshared)key\s*=\s*)[^\s]+/ig, '$1[redacted]')
		.replace(/(\bi[1-5]\s*=\s*)[^\r\n]+/ig, '$1[redacted]');
}

function formatProfileName(entry) {
	if (!entry) return 'WARP';
	var id = String(entry.id || entry.fingerprint || entry.name || '');
	var shortId = id.replace(/^p_/, '').substring(0, 4);
	var baseName = entry.profile || entry.name || 'WARP';
	if (baseName === 'WARP_native_cloudflare' || baseName === 'WARP_native' || baseName === 'WARP' || !baseName) {
		return 'WARP #' + (shortId || 'auto');
	}
	if (shortId && !baseName.includes(shortId) && baseName.startsWith('WARP')) {
		return baseName + ' #' + shortId;
	}
	return baseName;
}

function timestampToStr(timestamp) {
	if (timestamp < 1)
		return _('Never', 'No AmneziaWG peer handshake yet');

	var seconds = Math.max(0, Math.floor((Date.now() / 1000) - timestamp));
	var ago;

	if (seconds < 60)
		ago = _('%ds ago').format(seconds);
	else if (seconds < 3600)
		ago = _('%dm ago').format(Math.floor(seconds / 60));
	else if (seconds < 86401)
		ago = _('%dh ago').format(Math.floor(seconds / 3600));
	else
		ago = _('over a day ago');

	var date = new Date(timestamp * 1000);
	var zn = null;
	var ts = 0;
	var hc = 0;
	if (typeof uci !== 'undefined' && typeof uci.get === 'function') {
		try {
			zn = uci.get('system', '@system[0]', 'zonename');
			ts = uci.get('system', '@system[0]', 'clock_timestyle') || 0;
			hc = uci.get('system', '@system[0]', 'clock_hourcycle') || 0;
		} catch(e) {}
	}
	if (zn)
		zn = String(zn).trim().replace(/\s+/g, '_');

	var opts = {
		dateStyle: 'medium',
		timeStyle: (ts == 0) ? 'medium' : 'full',
		hourCycle: (hc == 0) ? undefined : hc
	};
	if (zn) {
		try {
			new Intl.DateTimeFormat(undefined, { timeZone: zn });
			opts.timeZone = zn;
		} catch(e) {}
	}

	var formattedDate;
	try {
		formattedDate = new Intl.DateTimeFormat(undefined, opts).format(date);
	} catch(e) {
		formattedDate = date.toLocaleString();
	}

	return formattedDate + ' (' + ago + ')';
}

function handleInterfaceDetails(iface) {
	var isUp = !!iface.is_up || iface.status === 'up';
	var variant = (iface.protocol_variant || iface.variant || 'awg2').toUpperCase();
	var items = [
		_('Name'), iface.name,
		_('Status'), isUp ? E('span', { 'class': 'cbi-badge cbi-badge-positive' }, [ 'UP' ]) : E('span', { 'class': 'cbi-badge cbi-badge-neutral' }, [ 'DOWN' ]),
		_('Protocol Variant'), variant,
		_('Firewall Zone'), iface.zone || E('em', _('none')),
		_('Public Key'), iface.public_key ? E('code', [ iface.public_key ]) : E('em', _('none')),
		_('Listen Port'), iface.listen_port || E('em', _('auto')),
		_('Firewall Mark'), (iface.fwmark && iface.fwmark != 'off') ? iface.fwmark : E('em', _('none'))
	];
	if (Array.isArray(iface.addresses) && iface.addresses.length) {
		items.push(_('IP Addresses'), iface.addresses.join(', '));
	}
	ui.showModal(_('Instance Details: %s').format(iface.name), [
		ui.itemlist(E([]), items),
		E('div', { 'class': 'right' }, [
			E('button', {
				'class': 'btn cbi-button',
				'click': ui.hideModal
			}, [ _('Dismiss') ])
		])
	]);
}

function handlePeerDetails(peer) {
	ui.showModal(_('Peer Details'), [
		ui.itemlist(E([]), [
			_('Description'), peer.name,
			_('Public Key'), E('code', [ peer.public_key ]),
			_('Endpoint'), peer.endpoint,
			_('Allowed IPs'), (Array.isArray(peer.allowed_ips) && peer.allowed_ips.length) ? peer.allowed_ips.join(', ') : E('em', _('none')),
			_('Received Data'), '%1024mB'.format(peer.transfer_rx),
			_('Transmitted Data'), '%1024mB'.format(peer.transfer_tx),
			_('Latest Handshake'), timestampToStr(+peer.latest_handshake),
			_('Keep-Alive'), (peer.persistent_keepalive != 'off') ? _('every %ds', 'AmneziaWG keep alive interval').format(+peer.persistent_keepalive) : E('em', _('none')),
		]),
		E('div', { 'class': 'right' }, [
			E('button', {
				'class': 'btn cbi-button',
				'click': ui.hideModal
			}, [ _('Dismiss') ])
		])
	]);
}


var ERROR_TRANSLATIONS = {
	'http_000': _('Connection timeout / no HTTP response'),
	'http_400': _('HTTP 400 Bad Request'),
	'http_403': _('HTTP 403 Forbidden'),
	'http_404': _('HTTP 404 Not Found'),
	'http_429': _('HTTP 429 Rate Limited'),
	'http_500': _('HTTP 500 Internal Server Error'),
	'http_502': _('HTTP 502 Bad Gateway'),
	'http_503': _('HTTP 503 Service Unavailable'),
	'missing_config': _('Configuration missing'),
	'invalid_config': _('Configuration invalid or corrupted'),
	'candidate_failed': _('Candidate failed isolated validation'),
	'fwmark': _('Firewall routing test failed (port conflict or rule error)'),
	'quic_failed': _('QUIC I1 handshake failed'),
	'handshake_timeout': _('WireGuard handshake timeout'),
	'health_timeout': _('Health check timeout')
};

function formatFriendlyError(err) {
	if (!err) return '';
	var str = String(err).trim();
	if (ERROR_TRANSLATIONS[str]) return ERROR_TRANSLATIONS[str] + ' (' + str + ')';
	return str.replace(/_/g, ' ');
}

function renderStatusBadge(status) {
	status = String(status || '-').toUpperCase();
	var badgeClass = 'cbi-badge';
	if (status === 'ACTIVE') badgeClass += ' cbi-badge-positive';
	else if (status === 'READY') badgeClass += ' cbi-badge-info';
	else if (status === 'FAILED') badgeClass += ' cbi-badge-negative';
	else badgeClass += ' cbi-badge-neutral';
	return E('span', { 'class': badgeClass, 'style': 'font-weight:600; padding:2px 8px; border-radius:3px;' }, [ status ]);
}

function renderHealthBadge(health) {
	if (!health || health === '-') return E('span', [ '-' ]);
	var badgeClass = 'cbi-badge';
	if (health === 'OK' || health === 'running') badgeClass += ' cbi-badge-positive';
	else if (health === 'FAIL' || health === 'failed' || health === 'stopped') badgeClass += ' cbi-badge-negative';
	else badgeClass += ' cbi-badge-neutral';
	return E('span', { 'class': badgeClass, 'style': 'font-weight:600; padding:2px 8px; border-radius:3px;' }, [ health ]);
}

function renderAwgVariantBadge(variant) {
	var label = _('Unknown');
	var badgeClass = 'cbi-badge';
	switch (variant) {
	case 'awg3_hybrid':
		label = 'AWG 3.0+3.1';
		badgeClass += ' cbi-badge-positive';
		break;
	case 'awg3_0':
		label = 'AWG 3.0';
		badgeClass += ' cbi-badge-positive';
		break;
	case 'awg3_1':
		label = 'AWG 3.1';
		badgeClass += ' cbi-badge-positive';
		break;
	case 'awg2':
		label = 'AWG 2.0';
		badgeClass += ' cbi-badge-neutral';
		break;
	case 'wireguard':
		label = 'WireGuard';
		badgeClass += ' cbi-badge-neutral';
		break;
	default:
		label = variant || _('Unknown');
		badgeClass += ' cbi-badge-neutral';
		break;
	}
	return E('span', { 'class': badgeClass, 'style': 'font-size:11px; font-weight:600; padding:2px 6px; border-radius:3px; white-space:nowrap;' }, [ label ]);
}

function handleProfileDetails(entry, profileConfigs) {
	var createdStr = autoTimestampToStr(entry.created_at);
	var testedStr = autoTimestampToStr(entry.last_test);
	var healthStr = autoTimestampToStr(entry.last_health);
	var providerStr = entry.source_provider === 'native' ? _('Native (Cloudflare Registration API)') :
	                  entry.source_provider === 'remote' ? _('Remote (External Generator)') : (entry.source_provider || '-');
	var epSourceStr = entry.endpoint_source === 'cloudflare_registration' ? _('Cloudflare Registration API') :
	                  entry.endpoint_source === 'custom' ? _('Custom Endpoint Pool') : (entry.endpoint_source || '-');

	var conf = (profileConfigs && profileConfigs[entry.id]) || {};

	var iFieldsDesc = '-';
	if (Array.isArray(conf.i_fields) && conf.i_fields.length > 0) {
		iFieldsDesc = conf.i_fields.map(function(f) {
			return (f.name ? f.name.toUpperCase() : 'I') + ' (' + (f.length || 0) + ' bytes)';
		}).join(', ');
	}

	var items = [
		_('Identity'), E('hr', { 'style': 'margin:4px 0 8px 0; border:0; border-top:1px solid var(--border-color-medium);' }),
		_('Profile ID'), entry.id,
		_('Profile Name'), formatProfileName(entry),
		_('Protocol Version'), renderAwgVariantBadge(entry.variant || conf.variant),
		_('Status'), renderStatusBadge(entry.status),
		_('Provider'), providerStr,
		_('Created'), createdStr,

		_('Endpoint & Connectivity'), E('hr', { 'style': 'margin:4px 0 8px 0; border:0; border-top:1px solid var(--border-color-medium);' }),
		_('Endpoint'), entry.endpoint ? E('code', [ entry.endpoint ]) : '-',
		_('Endpoint Source'), epSourceStr,
		_('Download Speed'), entry.speed_mbps ? entry.speed_mbps + ' Mbps' : '-',
		_('Last Test (Latency)'), testedStr + (entry.latency_ms != null ? ' (' + entry.latency_ms + ' ms RTT)' : ''),
		_('Last Health Check'), healthStr,
		_('Consecutive Failures'), String(entry.failure_count || 0)
	];

	if (entry.last_error) {
		items.push(_('Last Error'), E('span', { 'class': 'cbi-badge cbi-badge-negative' }, [ formatFriendlyError(entry.last_error) ]));
	}

	if (conf.mtu || conf.jc || conf.h1 || conf.contentpaddingaddition || conf.randomtrailers) {
		var obfuscation = [];
		if (conf.jc) obfuscation.push('Jc=' + conf.jc + ' (Jmin=' + (conf.jmin || 0) + ', Jmax=' + (conf.jmax || 0) + ')');
		if (conf.s1) obfuscation.push('S1-S4: ' + [conf.s1, conf.s2, conf.s3, conf.s4].filter(Boolean).join('/'));
		if (conf.h1) obfuscation.push('H1-H4: ' + [conf.h1, conf.h2, conf.h3, conf.h4].filter(Boolean).join('/'));

		items.push(
			_('Configuration Parameters'), E('hr', { 'style': 'margin:4px 0 8px 0; border:0; border-top:1px solid var(--border-color-medium);' }),
			_('MTU'), conf.mtu ? String(conf.mtu) : _('default (1280)'),
			_('Obfuscation (J/S/H)'), obfuscation.length ? obfuscation.join(' · ') : _('standard'),
			_('Junk Packet Headers (I1-I5)'), iFieldsDesc
		);

		if (conf.contentpaddingaddition || conf.rekeyaftertime) {
			items.push(
				_('AWG 3.0 Padding'), conf.contentpaddingaddition || '-',
				_('AWG 3.0 Rekey / Reject'), 'Rekey=' + (conf.rekeyaftertime || '-') + ' (timeout ' + (conf.rekeytimeout || '-') + 's), Reject=' + (conf.rejectaftertime || '-'),
				_('AWG 3.0 Keepalive / Attempts'), 'Keepalive=' + (conf.keepalivetimeout || '-') + 's, MaxAttempts=' + (conf.maxhandshakeattempts || '-')
			);
		}
		if (conf.randomtrailers || conf.disablecookies) {
			items.push(
				_('AWG 3.1 Features'), 'RandomTrailers=' + (conf.randomtrailers || 'off') + ', DisableCookies=' + (conf.disablecookies || 'off')
			);
		}
	}

	ui.showModal(_('Profile Details: %s').format(formatProfileName(entry)), [
		ui.itemlist(E([]), items),
		E('div', { 'class': 'right', 'style': 'margin-top:1em' }, [
			E('button', {
				'class': 'btn cbi-button',
				'click': ui.hideModal
			}, [ _('Dismiss') ])
		])
	]);
}

function renderPeerTable(instanceName, peers) {
	var t = new L.ui.Table(
		[
			_('Peer'),
			_('Endpoint'),
			_('Data Received'),
			_('Data Transmitted'),
			_('Latest Handshake')
		],
		{
			id: 'peers-' + instanceName
		},
		E('em', [
			_('No peers connected')
		])
	);

	t.update((peers || []).map(function(peer) {
		return [
			[
				peer.name || '',
				E('div', {
					'style': 'cursor:pointer',
					'click': ui.createHandlerFn(this, handlePeerDetails, peer)
				}, [
					E('p', [
						peer.name ? E('span', [ peer.name ]) : E('em', [ _('Untitled peer') ])
					]),
					E('span', {
						'class': 'ifacebadge hide-sm',
						'data-tooltip': _('Public key: %h', 'Tooltip displaying full AmneziaWG peer public key').format(peer.public_key)
					}, [
						E('code', [ peer.public_key.replace(/^(.{5}).+(.{6})$/, '$1…$2') ])
					])
				])
			],
			peer.endpoint,
			[ +peer.transfer_rx, '%1024mB'.format(+peer.transfer_rx) ],
			[ +peer.transfer_tx, '%1024mB'.format(+peer.transfer_tx) ],
			[ +peer.latest_handshake, timestampToStr(+peer.latest_handshake) ]
		];
	}));

	return t.render();
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('system')
		]);
	},

	showWarpAutoMessage: function(message, isError) {
		if (!this.autoMessageNode)
			return;

		dom.content(this.autoMessageNode, message ? E('span', {
			'class': isError ? 'error' : 'success'
		}, [ message ]) : []);
	},

	showNotification: function(message, type, timeoutMs) {
		if (!message) return;
		type = type || 'info';
		timeoutMs = timeoutMs || (type === 'error' ? 8000 : 5000);

		try {
			var oldNotifs = document.querySelectorAll('#maincontent > .alert-message.warp-auto-notice');
			for (var i = 0; i < oldNotifs.length; i++) {
				if (oldNotifs[i].parentNode) oldNotifs[i].parentNode.removeChild(oldNotifs[i]);
			}
		} catch(e) {}

		var content = typeof message === 'string' ? E('p', [ message ]) : message;
		var notifNode;
		if (typeof ui.addTimeLimitedNotification === 'function') {
			notifNode = ui.addTimeLimitedNotification(null, content, timeoutMs, type, 'warp-auto-notice');
		} else {
			notifNode = ui.addNotification(null, content, type, 'warp-auto-notice');
			setTimeout(function() {
				if (notifNode && notifNode.parentNode) notifNode.parentNode.removeChild(notifNode);
			}, timeoutMs);
		}
		this.currentNotification = notifNode;
		return notifNode;
	},

	switchWarpTab: function(name) {
		Object.keys(this.warpTabs || {}).forEach(L.bind(function(key) {
			var tab = this.warpTabs[key];
			var active = key == name;

			tab.panel.style.display = active ? '' : 'none';
			tab.item.classList.toggle('cbi-tab', active);
			tab.item.classList.toggle('cbi-tab-disabled', !active);
			tab.link.style.fontWeight = active ? 'bold' : 'normal';
		}, this));
		if (this.warpTabHeading && this.warpTabs[name])
			dom.content(this.warpTabHeading, [ _('WARP Auto') + ' - ' + this.warpTabs[name].title ]);
	},

	renderWarpTabs: function(tabs) {
		var items = [];
		var panels = [];

		this.warpTabs = {};
		tabs.forEach(L.bind(function(tab, index) {
			var panel = E('div', {
				'class': 'cbi-section',
				'style': index ? 'display:none' : ''
			}, tab.content);
			var item = E('li', { 'class': index ? 'cbi-tab-disabled' : 'cbi-tab' });
			var link = E('a', {
				'href': '#',
				'style': index ? '' : 'font-weight:bold',
				'click': L.bind(function(event) {
					event.preventDefault();
					this.switchWarpTab(tab.id);
				}, this)
			}, [ tab.title ]);

			item.appendChild(link);
			this.warpTabs[tab.id] = {
				item: item,
				link: link,
				panel: panel,
				title: tab.title
			};

			items.push(item);
			panels.push(panel);
		}, this));

		this.warpTabHeading = E('h2', [ _('WARP Auto') + ' - ' + tabs[0].title ]);
		return E('div', { 'id': 'warp-auto-panel' }, [
			this.warpTabHeading,
			E('p', [ _('WARP profile manager and automatic failover.') ]),
			E('ul', { 'class': 'cbi-tabmenu' }, items),
			E('div', { 'role': 'status', 'aria-live': 'polite', 'style': 'margin-bottom:1em' }, [ this.autoMessageNode ])
		].concat(panels));
	},

	markWarpAutoSettingsDirty: function() {
		this.autoSettingsDirty = true;
	},

	setWarpAutoBusy: function(busy) {
		this.autoBusy = busy;

		if (busy) {
			try {
				var oldNotifs = document.querySelectorAll('#maincontent > .alert-message.warp-auto-notice');
				for (var i = 0; i < oldNotifs.length; i++) {
					if (oldNotifs[i].parentNode) oldNotifs[i].parentNode.removeChild(oldNotifs[i]);
				}
			} catch(e) {}
		}

		(this.autoActionButtons || []).concat(this.autoPoolButtons || []).forEach(function(button) {
			button.disabled = busy;
		});

		if (this.autoSaveButton)
			this.autoSaveButton.disabled = busy;

		if (!busy && this.autoBootstrapButton)
			this.autoBootstrapButton.disabled = this.autoInterfaceState != 'missing';
	},

	getWarpAutoSettings: function() {
		var fields = this.autoFields;
		var resources = [];
		var known = {};

		String(fields.critical_resource.value || '').split(/[\r\n,]+/).forEach(function(value) {
			value = value.trim();
			if (value && !known[value]) {
				known[value] = true;
				resources.push(value);
			}
		});

		if (!resources.length)
			resources.push('youtube.com');

		return {
			interface: (fields.interface && fields.interface.value) || 'YTwarp',
			provider: fields.provider.value,
			awg_version: fields.awg_version ? fields.awg_version.value : 'v3_hybrid',
			batch_size: Math.floor(numberValue(fields.batch_size.value, 5)),
			native_sni: fields.native_sni.value.trim() || 'w3.org',
			native_quic_mode: fields.native_quic_mode.value,
			native_endpoint_mode: fields.native_endpoint_mode.value,
			native_batch_limit: Math.floor(numberValue(fields.batch_size.value, 5)),
			native_min_interval: Math.floor(numberValue(fields.native_min_interval.value, 900)),
			native_endpoints: fields.native_endpoints.value.split(/[\r\n,]+/).map(function(value) { return value.trim(); }).filter(Boolean),
			enabled: fields.enabled.checked ? '1' : '0',
			automatic_failover: fields.automatic_failover.checked ? '1' : '0',
			failover_cooldown: Math.floor(numberValue(fields.failover_cooldown.value, 10)),
			source_url: fields.source_url.value.trim() || DEFAULT_WARP_SOURCE_URL,
			refresh_interval: Math.floor(numberValue(fields.refresh_interval.value, 86400)),
			minimum_ready: Math.floor(numberValue(fields.minimum_ready.value, 2)),
			health_interval: Math.floor(numberValue(fields.health_interval.value, 60)),
			failure_threshold: Math.floor(numberValue(fields.failure_threshold.value, 3)),
			health_timeout: Math.floor(numberValue(fields.health_timeout.value, 10)),
			health_mode: fields.health_mode.checked ? 'strict' : 'direct',
			log_level: fields.log_level.value,
			critical_resource: resources,
			health_resolvers: String(fields.health_resolvers ? fields.health_resolvers.value : '').trim() || '1.1.1.1 8.8.8.8 9.9.9.9 77.88.8.8 77.88.8.1'
		};
	},

	setWarpAutoSettings: function(settings) {
		var fields = this.autoFields;
		var resources;

		if (!fields)
			return;

		settings = settings || {};
		this.setWarpAutoInterfaceChoices(this.autoKnownInterfaces || [], settings.interface || 'YTwarp');
		resources = settings.critical_resource || settings.critical_resources || [ 'youtube.com' ];
		if (!Array.isArray(resources))
			resources = String(resources).split(/[\r\n,]+/);

		fields.enabled.checked = boolValue(settings.enabled);
		fields.provider.value = settings.provider || 'remote';
		if (fields.awg_version)
			fields.awg_version.value = settings.awg_version || 'v3_hybrid';
		var bSize = numberValue(settings.batch_size != null ? settings.batch_size : settings.native_batch_limit, 5);
		if (fields.batch_size)
			fields.batch_size.value = bSize;
		if (fields.native_batch_limit)
			fields.native_batch_limit.value = bSize;
		if (this.autoGenerateButton)
			dom.content(this.autoGenerateButton, [ _('Generate batch (%d)').format(bSize) ]);
		fields.native_sni.value = settings.native_sni || 'w3.org';
		fields.native_quic_mode.value = settings.native_quic_mode || 'dynamic';
		fields.native_endpoint_mode.value = settings.native_endpoint_mode || 'auto';
		fields.native_min_interval.value = numberValue(settings.native_min_interval, 900);
		fields.native_endpoints.value = Array.isArray(settings.native_endpoints) ? settings.native_endpoints.join('\n') : settings.native_endpoints || '';
		fields.automatic_failover.checked = settings.automatic_failover == null ? true : boolValue(settings.automatic_failover);
		fields.failover_cooldown.value = numberValue(settings.failover_cooldown, 10);
		fields.source_url.value = settings.source_url || DEFAULT_WARP_SOURCE_URL;
		fields.refresh_interval.value = numberValue(settings.refresh_interval, 86400);
		fields.minimum_ready.value = numberValue(settings.minimum_ready, 2);
		fields.health_interval.value = numberValue(settings.health_interval, 60);
		fields.failure_threshold.value = numberValue(settings.failure_threshold, 3);
		fields.health_timeout.value = numberValue(settings.health_timeout, 10);
		fields.health_mode.checked = settings.health_mode == null ? true : settings.health_mode == 'strict';
		fields.log_level.value = settings.log_level || 'info';
		fields.critical_resource.value = resources.filter(function(value) {
			return String(value).trim().length;
		}).join('\n') || 'youtube.com';
		if (fields.health_resolvers)
			fields.health_resolvers.value = settings.health_resolvers || '1.1.1.1 8.8.8.8 9.9.9.9 77.88.8.8 77.88.8.1';
		this.updateProviderFields();
	},

	updateProviderFields: function() {
		var native = this.autoFields.provider.value == 'native';
		if (this.nativeSettingsNode) this.nativeSettingsNode.style.display = native ? '' : 'none';
		if (this.remoteSettingsNode) this.remoteSettingsNode.style.display = native ? 'none' : '';
	},

	profileDownload: function(id, label) {
		return E('a', {
			'class': 'btn cbi-button cbi-button-action',
			'href': L.url('admin', 'services', 'amneziawg', 'download') + '?id=' + encodeURIComponent(id),
			'download': ''
		}, [ label || _('Download') ]);
	},

	interfaceDownload: function(name, label) {
		return E('a', {
			'class': 'btn cbi-button cbi-button-action',
			'style': 'padding:2px 8px; font-size:12px;',
			'href': L.url('admin', 'services', 'amneziawg', 'download') + '?interface=' + encodeURIComponent(name),
			'download': (name || 'amneziawg') + '.conf'
		}, [ label || _('Download .conf') ]);
	},

	setWarpAutoInterfaceChoices: function(interfaces, selected) {
		var field = this.autoFields && this.autoFields.interface;
		var names = [];
		var seen = {};

		(interfaces || []).forEach(function(name) {
			name = String(name || '');
			if (/^[A-Za-z][A-Za-z0-9_]{0,14}$/.test(name) && !seen[name]) {
				seen[name] = true;
				names.push(name);
			}
		});
		selected = String(selected || 'YTwarp');
		if (!seen[selected])
			names.unshift(selected);
		if (!field)
			return;
		dom.content(field, names.map(function(name) {
			return E('option', { 'value': name }, [ name ]);
		}));
		field.value = selected;
		this.autoTarget = selected;
	},

	getWarpAutoPool: function(state) {
		var pool = state.pool || state.configs || [];
		var result = [];

		if (Array.isArray(pool))
			return pool;

		for (var id in pool) {
			var entry = pool[id];
			if (entry && typeof entry == 'object') {
				if (!entry.id)
					entry.id = id;
				result.push(entry);
			}
		}

		return result;
	},

	renderWarpAutoRuntime: function(state) {
		var runtime = state.runtime || {};
		var pool = this.getWarpAutoPool(state);
		var service = runtime.service || runtime.state || (runtime.up === true ? 'running' : runtime.running === true ? 'running' : runtime.running === false ? 'stopped' : '-');
		var activeId = runtime.active_id || runtime.active || state.active_id || state.active || '';
		var interfaceState = runtime.interface_state || 'unknown';
		var bootstrapState = runtime.bootstrap_state || '-';
		var bootstrapError = runtime.bootstrap_error || '';
		var health = runtime.health || runtime.last_health || state.health || '-';
		var failures = runtime.consecutive_failures;
		var lastHealth = runtime.last_health || state.last_health;
		var lastFailover = runtime.last_failover;

		if (service && typeof service == 'object')
			service = service.status || service.state || '-';
		if (health && typeof health == 'object')
			health = health.status || health.result || '-';
		if (failures == null)
			failures = state.consecutive_failures;

		this.autoInterfaceState = interfaceState;
		if (this.autoBootstrapButton)
			this.autoBootstrapButton.disabled = this.autoBusy || interfaceState != 'missing' || bootstrapState == 'running';

		// Find active profile in pool
		var activeEntry = null;
		for (var i = 0; i < pool.length; i++) {
			if (pool[i].id === activeId || pool[i].active === true) {
				activeEntry = pool[i];
				break;
			}
		}

		// Check for state discrepancy between configured profile and actual kernel peer
		var discrepancy = false;
		var discrepancyMsg = '';
		if (activeEntry && runtime.actual_endpoint && activeEntry.endpoint) {
			if (activeEntry.endpoint !== runtime.actual_endpoint) {
				discrepancy = true;
				discrepancyMsg = _('Discrepancy: active profile specifies %s but kernel interface is connected to %s.').format(activeEntry.endpoint, runtime.actual_endpoint);
			}
		}
		if (runtime.actual_peer_desc && activeId && runtime.actual_peer_desc !== activeId) {
			discrepancy = true;
			discrepancyMsg = _('Discrepancy: configured interface peer is %s but active profile is %s.').format(runtime.actual_peer_desc, activeId);
		}

		// 1. Compact 4-6 indicator grid using native LuCI theme classes
		var trafficRx = runtime.actual_rx != null ? '%1024mB'.format(+runtime.actual_rx) : '-';
		var trafficTx = runtime.actual_tx != null ? '%1024mB'.format(+runtime.actual_tx) : '-';
		var handshakeStr = runtime.actual_handshake ? timestampToStr(+runtime.actual_handshake) : _('No handshake yet');
		var failoverStr = lastFailover ? autoTimestampToStr(lastFailover) : _('Never');

		var gridStyle = 'display:grid; grid-template-columns:repeat(auto-fit, minmax(170px, 1fr)); gap:12px; margin-bottom:16px;';
		var cardStyle = 'background-color:var(--background-color-low); border:1px solid var(--border-color-medium); border-radius:4px; padding:10px 14px;';
		var labelStyle = 'font-size:11px; text-transform:uppercase; color:var(--text-color-medium); font-weight:bold; margin-bottom:4px;';
		var valueStyle = 'font-size:15px; font-weight:600; word-break:break-all; color:var(--text-color-high);';

		var makeCard = function(title, content) {
			return E('div', { 'style': cardStyle }, [
				E('div', { 'style': labelStyle }, [ title ]),
				E('div', { 'style': valueStyle }, [ content ])
			]);
		};

		var dashboard = E('div', { 'style': gridStyle }, [
			makeCard(_('Service'), renderHealthBadge(service)),
			makeCard(_('Interface'), E('span', [
				(runtime.interface || 'YTwarp') + ' ',
				E('small', { 'style': 'font-weight:normal; opacity:.8;' }, [ '(' + (interfaceState === 'present' ? _('up') : interfaceState) + ')' ])
			])),
			makeCard(_('Health Gate'), renderHealthBadge(health)),
			makeCard(_('Last Handshake'), E('span', { 'style': 'font-size:13px;' }, [ handshakeStr ])),
			makeCard(_('Traffic (RX / TX)'), E('span', { 'style': 'font-size:13px;' }, [ trafficRx + ' / ' + trafficTx ])),
			makeCard(_('Failover Status'), E('span', { 'style': 'font-size:13px;' }, [
				(failures > 0 ? E('span', { 'class': 'cbi-badge cbi-badge-negative' }, [ failures + ' fail' ]) : _('Stable (0 fail)')),
				' · ',
				failoverStr
			]))
		]);

		// 2. Active Connection dedicated card using native theme background & accent
		var activeConnCard = null;
		if (activeEntry) {
			var activeProvider = activeEntry.source_provider === 'native' ? _('Native (Cloudflare)') :
			                     activeEntry.source_provider === 'remote' ? _('Remote') : (activeEntry.source_provider || '-');
			var activeEpSource = activeEntry.endpoint_source === 'cloudflare_registration' ? _('Registration API') :
			                     activeEntry.endpoint_source === 'custom' ? _('Custom Pool') : (activeEntry.endpoint_source || '-');

			var detailsBtn = E('button', {
				'class': 'btn cbi-button',
				'style': 'margin-left:6px;',
				'click': L.bind(function(ev) {
					ev.preventDefault();
					handleProfileDetails(activeEntry, state.profile_configs);
				}, this)
			}, [ _('Details') ]);

			activeConnCard = E('div', {
				'class': 'cbi-section',
				'style': 'background-color:var(--background-color-low); border:1px solid var(--border-color-medium); border-left:4px solid var(--success-color-high, #27ae60); padding:12px 16px; margin-bottom:16px;'
			}, [
				E('div', { 'style': 'display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap;' }, [
					E('div', [
						E('h4', { 'style': 'margin:0 0 6px 0; font-size:16px; color:var(--text-color-high);' }, [
							_('Active Connection: '),
							E('strong', [ formatProfileName(activeEntry) ]),
							' ',
							renderStatusBadge(activeEntry.status)
						]),
						E('div', { 'style': 'font-size:13px; color:var(--text-color-medium);' }, [
							E('span', [ _('Provider: '), E('strong', { 'style': 'color:var(--text-color-high);' }, [ activeProvider ]), ' (' + activeEpSource + ')' ]),
							' · ',
							E('span', [ _('Endpoint: '), E('code', [ runtime.actual_endpoint || activeEntry.endpoint || '-' ]) ]),
							(activeEntry.latency_ms != null ? E('span', [ ' · ', _('RTT: '), activeEntry.latency_ms + ' ms' ]) : '')
						])
					]),
					E('div', { 'style': 'margin-top:6px;' }, [
						this.profileDownload('active', _('Download .conf')),
						detailsBtn
					])
				]),
				discrepancy ? E('div', {
					'class': 'alert-message warning',
					'style': 'margin-top:10px; margin-bottom:0;'
				}, [ discrepancyMsg ]) : ''
			]);
		} else {
			activeConnCard = E('div', {
				'class': 'cbi-section',
				'style': 'background-color:var(--background-color-low); border:1px solid var(--border-color-medium); border-left:4px solid var(--warn-color-high, #f39c12); padding:12px 16px; margin-bottom:16px;'
			}, [
				E('strong', { 'style': 'color:var(--text-color-high);' }, [ _('No active WARP profile assigned.') ]),
				E('p', { 'style': 'margin:4px 0 0 0; font-size:13px; color:var(--text-color-medium);' }, [
					_('Choose a READY profile from the pool below and click "Activate", or wait for automatic selection.')
				])
			]);
		}

		dom.content(this.autoRuntimeNode, [ dashboard, activeConnCard ].filter(Boolean));
	},

	renderWarpAutoPool: function(state) {
		var pool = this.getWarpAutoPool(state);
		this.autoPoolButtons = [];
		var filter = this.poolFilter || 'all';

		// Calculate pool health summary counts
		var total = pool.length;
		var readyCount = 0;
		var activeCount = 0;
		var failedCount = 0;
		var nativeCount = 0;
		var remoteCount = 0;

		pool.forEach(function(entry) {
			var st = String(entry.status || entry.state || '').toUpperCase();
			if (st === 'ACTIVE') activeCount++;
			else if (st === 'READY') readyCount++;
			else if (st === 'FAILED') failedCount++;
			if (entry.source_provider === 'native') nativeCount++;
			else if (entry.source_provider === 'remote') remoteCount++;
		});

		var configuredProvider = (state.settings && state.settings.provider) || 'remote';
		var minReady = (state.settings && state.settings.minimum_ready != null) ? state.settings.minimum_ready : 2;
		var poolStatusText = readyCount >= minReady ? _('Pool healthy') : _('Pool degraded (under minimum READY threshold)');
		var poolStatusBadge = readyCount >= minReady ? 'cbi-badge cbi-badge-positive' : 'cbi-badge cbi-badge-negative';

		var providerSemanticsInfo = configuredProvider === 'native' && remoteCount > 0
			? E('div', { 'class': 'cbi-value-description', 'style': 'margin-top:4px; font-size:12px; color:var(--text-color-medium);' }, [
				_('Configured provider is Native. Existing Remote profiles in pool serve as valid standby fallback until replaced or refreshed.')
			]) : '';

		var summaryHeader = E('div', {
			'style': 'display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; margin-bottom:10px; gap:8px;'
		}, [
			E('div', [
				E('span', { 'class': poolStatusBadge, 'style': 'font-weight:600; padding:3px 10px; margin-right:8px;' }, [ poolStatusText ]),
				E('span', { 'style': 'color:var(--text-color-medium); font-size:13px;' }, [
					_('Total: %d · Active: %d · READY: %d (min %d) · Failed: %d').format(total, activeCount, readyCount, minReady, failedCount)
				]),
				providerSemanticsInfo
			]),
			// Filter buttons: All | Native | Remote
			E('div', { 'class': 'btn-group' }, [
				E('button', {
					'class': 'btn cbi-button' + (filter === 'all' ? ' cbi-button-action' : ''),
					'click': L.bind(function(ev) {
						ev.preventDefault();
						this.poolFilter = 'all';
						this.renderWarpAutoPool(state);
					}, this)
				}, [ _('All (%d)').format(total) ]),
				E('button', {
					'class': 'btn cbi-button' + (filter === 'native' ? ' cbi-button-action' : ''),
					'click': L.bind(function(ev) {
						ev.preventDefault();
						this.poolFilter = 'native';
						this.renderWarpAutoPool(state);
					}, this)
				}, [ _('Native (%d)').format(nativeCount) ]),
				E('button', {
					'class': 'btn cbi-button' + (filter === 'remote' ? ' cbi-button-action' : ''),
					'click': L.bind(function(ev) {
						ev.preventDefault();
						this.poolFilter = 'remote';
						this.renderWarpAutoPool(state);
					}, this)
				}, [ _('Remote (%d)').format(remoteCount) ])
			])
		]);

		var filteredPool = pool.filter(function(entry) {
			if (filter === 'native') return entry.source_provider === 'native';
			if (filter === 'remote') return entry.source_provider === 'remote';
			return true;
		});

		var activeId = (state.runtime && state.runtime.active_id) || '';

		filteredPool.sort(function(a, b) {
			var aId = String(a.id || a.fingerprint || a.name || '');
			var bId = String(b.id || b.fingerprint || b.name || '');
			var aIsActive = (aId && aId === activeId) || a.active === true || (String(a.status).toUpperCase() === 'ACTIVE');
			var bIsActive = (bId && bId === activeId) || b.active === true || (String(b.status).toUpperCase() === 'ACTIVE');

			if (aIsActive && !bIsActive) return -1;
			if (!aIsActive && bIsActive) return 1;

			var aSpeed = (typeof a.speed_mbps === 'number') ? a.speed_mbps : (+a.speed_mbps || 0);
			var bSpeed = (typeof b.speed_mbps === 'number') ? b.speed_mbps : (+b.speed_mbps || 0);
			if (bSpeed !== aSpeed) {
				return bSpeed - aSpeed;
			}

			var aLat = (typeof a.latency_ms === 'number' && a.latency_ms >= 0) ? a.latency_ms : 99999;
			var bLat = (typeof b.latency_ms === 'number' && b.latency_ms >= 0) ? b.latency_ms : 99999;
			if (aLat !== bLat) {
				return aLat - bLat;
			}

			var aCreated = +a.created_at || 0;
			var bCreated = +b.created_at || 0;
			return bCreated - aCreated;
		});

		var rows = filteredPool.map(L.bind(function(entry) {
			var id = String(entry.id || entry.fingerprint || entry.name || '-');
			var profile = formatProfileName(entry);
			var status = String(entry.status || entry.state || '-').toUpperCase();
			var endpoint = entry.endpoint || '-';
			var lastTest = autoTimestampToStr(entry.last_test || entry.tested_at);
			var latency = entry.latency_ms == null ? '-' : String(entry.latency_ms) + ' ms';
			var failures = entry.failure_count == null ? '0' : String(entry.failure_count);

			var providerStr = entry.source_provider === 'native' ? _('Native') :
			                  entry.source_provider === 'remote' ? _('Remote') : (entry.source_provider || '-');
			var epSourceStr = entry.endpoint_source === 'cloudflare_registration' ? _('CF Reg') :
			                  entry.endpoint_source === 'custom' ? _('Custom') : (entry.endpoint_source || '-');

			var actions = [];
			if (status == 'READY' || status == 'FAILED' || status == 'ACTIVE') {
				var action = status == 'READY' ? 'activate' : 'retest';
				var btnText = status == 'READY' ? _('Activate') : _('Retest');
				var button = E('button', {
					'class': 'btn cbi-button' + (status == 'READY' ? ' cbi-button-action' : ''),
					'title': status == 'ACTIVE' ? _('Benchmark speed and latency of active profile') : (status == 'READY' ? _('Activate this profile') : _('Retest this profile')),
					'click': L.bind(function(event) {
						event.preventDefault();
						return this.runWarpAutoAction(action, id);
					}, this)
				}, [ btnText ]);
				button.disabled = !!this.autoBusy;
				this.autoPoolButtons.push(button);
				actions.push(button, ' ');
			}
			actions.push(this.profileDownload(id));

			var detailsBtn = E('button', {
				'class': 'btn cbi-button',
				'click': L.bind(function(event) {
					event.preventDefault();
					handleProfileDetails(entry, state.profile_configs);
				}, this)
			}, [ _('Details') ]);
			actions.push(' ', detailsBtn);

			var isCurrentActive = (state.runtime && state.runtime.active_id === id) || entry.active;
			var deleteBtn = E('button', {
				'class': 'btn cbi-button cbi-button-negative',
				'title': isCurrentActive ? _('Cannot delete active profile') : _('Delete profile from pool'),
				'disabled': !!isCurrentActive || !!this.autoBusy,
				'click': L.bind(function(event) {
					event.preventDefault();
					if (isCurrentActive) return;
					if (confirm(_('Delete profile %s?').format(profile))) {
						return this.deleteWarpAutoProfile(id);
					}
				}, this)
			}, [ _('Delete') ]);
			deleteBtn.disabled = !!isCurrentActive || !!this.autoBusy;
			this.autoPoolButtons.push(deleteBtn);
			actions.push(' ', deleteBtn);

			var profileLink = E('a', {
				'href': '#',
				'style': 'font-weight:600; cursor:pointer;',
				'title': _('Click for details'),
				'click': L.bind(function(ev) {
					ev.preventDefault();
					handleProfileDetails(entry, state.profile_configs);
				}, this)
			}, [ String(profile) ]);

			var conf = (state.profile_configs && state.profile_configs[id]) || {};
			var awgBadge = renderAwgVariantBadge(entry.variant || conf.variant);

			var speedBadge;
			if (entry.speed_mbps) {
				var badgeColor = entry.speed_mbps >= 80 ? 'cbi-badge-positive' : (entry.speed_mbps >= 30 ? 'cbi-badge-info' : 'cbi-badge-neutral');
				speedBadge = E('span', { 'class': 'cbi-badge ' + badgeColor, 'style': 'font-weight:600' }, [ entry.speed_mbps + ' Mbps' ]);
			} else {
				speedBadge = E('span', { 'style': 'color:var(--text-color-medium)' }, [ '-' ]);
			}

			return E('tr', [
				E('td', [ profileLink ]),
				E('td', [ providerStr ]),
				E('td', [ awgBadge ]),
				E('td', [ epSourceStr ]),
				E('td', [ E('code', [ String(endpoint) ]) ]),
				E('td', [ renderStatusBadge(status) ]),
				E('td', [ speedBadge ]),
				E('td', [ lastTest ]),
				E('td', [ latency ]),
				E('td', [ failures ]),
				E('td', { 'style': 'white-space:nowrap' }, actions)
			]);
		}, this));

		if (!rows.length)
			rows.push(E('tr', [ E('td', { 'colspan': 11 }, [ E('em', [ _('No profiles match current filter.') ]) ]) ]));

		dom.content(this.autoPoolNode, E('div', [
			summaryHeader,
			E('table', { 'class': 'table cbi-section-table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, [ _('Profile') ]),
					E('th', { 'class': 'th' }, [ _('Provider') ]),
					E('th', { 'class': 'th' }, [ _('AWG') ]),
					E('th', { 'class': 'th' }, [ _('Source') ]),
					E('th', { 'class': 'th' }, [ _('Endpoint') ]),
					E('th', { 'class': 'th' }, [ _('State') ]),
					E('th', { 'class': 'th' }, [ _('Speed') ]),
					E('th', { 'class': 'th' }, [ _('Last test') ]),
					E('th', { 'class': 'th' }, [ _('Latency (RTT)') ]),
					E('th', { 'class': 'th' }, [ _('Failures') ]),
					E('th', { 'class': 'th' }, [ _('Actions') ])
				])
			].concat(rows))
		]));
	},

	renderWarpAutoLogs: function(state) {
		var logs = state.logs || state.recent_logs || [];
		var filterLevel = this.logsFilterLevel || 'all';

		var lines = [];
		if (typeof logs == 'string') {
			lines = logs.split(/\r?\n/).filter(Boolean);
		} else if (Array.isArray(logs)) {
			lines = logs.filter(Boolean);
		}

		lines = lines.slice(-80).map(redactAutoLog);

		var monthMap = { Jan:'01', Feb:'02', Mar:'03', Apr:'04', May:'05', Jun:'06', Jul:'07', Aug:'08', Sep:'09', Oct:'10', Nov:'11', Dec:'12' };

		var parsedLogs = [];
		lines.forEach(function(raw, idx) {
			var text = String(raw).trim();
			if (!text) return;

			var timeStr = '';
			var ts = idx;
			var cleanText = text;

			// Parse standard syslog timestamp: "Sat Sep  5 20:18:55 2026 user.warn awg-warp-auto: ..."
			var m = text.match(/^([A-Za-z]{3})\s+([A-Za-z]{3})\s+(\d+)\s+(\d{2}:\d{2}:\d{2})\s+(\d{4})\s+(user|daemon)\.([a-z]+)\s+awg-warp-auto:\s*(.*)$/);
			if (m) {
				var month = monthMap[m[2]] || '01';
				var day = m[3].length === 1 ? '0' + m[3] : m[3];
				timeStr = m[5] + '-' + month + '-' + day + ' ' + m[4];
				ts = Date.parse(m[5] + '-' + month + '-' + day + 'T' + m[4] + 'Z') || idx;
				cleanText = m[8];
			} else {
				cleanText = text.replace(/^[A-Za-z]{3}\s+[A-Za-z]{3}\s+\d+\s+\d+:\d+:\d+\s+\d{4}\s+/, '');
				cleanText = cleanText.replace(/^(daemon|user)\.(info|notice|warn|err|debug)\s+awg-warp-auto:\s*/, '');
			}

			var level = 'info';
			if (/daemon\.err|user\.err|\berror\b/i.test(text)) level = 'error';
			else if (/daemon\.warn|user\.warn|\bwarning\b|\brollback\b|\bfailed\b/i.test(text)) level = 'warn';
			else if (/daemon\.debug|user\.debug|\bdebug\b/i.test(text)) level = 'debug';

			parsedLogs.push({ raw: text, timeStr: timeStr, timestamp: ts, level: level, message: cleanText, seq: idx });
		});

		// Sort descending: NEWEST events at the top
		parsedLogs.sort(function(a, b) {
			if (b.timestamp !== a.timestamp) return b.timestamp - a.timestamp;
			return b.seq - a.seq;
		});

		var filteredLogs = parsedLogs.filter(function(item) {
			if (filterLevel === 'all') return true;
			if (filterLevel === 'warn') return item.level === 'warn' || item.level === 'error';
			if (filterLevel === 'error') return item.level === 'error';
			return true;
		});

		var logRows = filteredLogs.map(function(item) {
			var badgeClass = 'cbi-badge';
			if (item.level === 'error') badgeClass += ' cbi-badge-negative';
			else if (item.level === 'warn') badgeClass += ' cbi-badge-neutral';
			else if (item.level === 'info') badgeClass += ' cbi-badge-info';
			else badgeClass += ' cbi-badge-neutral';

			return E('div', {
				'style': 'font-family:var(--font-mono, monospace); font-size:12px; margin-bottom:4px; line-height:1.5; border-bottom:1px solid var(--border-color-low); padding-bottom:3px; color:var(--text-color-high);'
			}, [
				item.timeStr ? E('span', { 'style': 'color:var(--text-color-medium); margin-right:8px;' }, [ item.timeStr ]) : '',
				E('span', { 'class': badgeClass, 'style': 'font-size:10px; font-weight:bold; padding:2px 6px; margin-right:8px; text-transform:uppercase;' }, [ item.level ]),
				E('span', [ item.message ])
			]);
		});

		var controls = E('div', { 'style': 'display:flex; justify-content:space-between; align-items:center; margin-bottom:10px; flex-wrap:wrap; gap:8px;' }, [
			E('div', [
				E('span', { 'style': 'font-weight:bold; margin-right:8px; color:var(--text-color-high);' }, [ _('Filter Level:') ]),
				E('div', { 'class': 'btn-group' }, [
					E('button', {
						'class': 'btn cbi-button' + (filterLevel === 'all' ? ' cbi-button-action' : ''),
						'click': L.bind(function(ev) {
							ev.preventDefault();
							this.logsFilterLevel = 'all';
							this.renderWarpAutoLogs(state);
						}, this)
					}, [ _('All') ]),
					E('button', {
						'class': 'btn cbi-button' + (filterLevel === 'warn' ? ' cbi-button-action' : ''),
						'click': L.bind(function(ev) {
							ev.preventDefault();
							this.logsFilterLevel = 'warn';
							this.renderWarpAutoLogs(state);
						}, this)
					}, [ _('Warnings & Errors') ]),
					E('button', {
						'class': 'btn cbi-button' + (filterLevel === 'error' ? ' cbi-button-action' : ''),
						'click': L.bind(function(ev) {
							ev.preventDefault();
							this.logsFilterLevel = 'error';
							this.renderWarpAutoLogs(state);
						}, this)
					}, [ _('Errors Only') ])
				])
			]),
			E('button', {
				'class': 'btn cbi-button',
				'click': L.bind(function(ev) {
					ev.preventDefault();
					this.updateWarpAuto();
				}, this)
			}, [ _('Refresh Logs') ])
		]);

		dom.content(this.autoLogsNode, [
			controls,
			E('div', {
				'style': 'max-height:24em; overflow:auto; background-color:var(--background-color-low); border:1px solid var(--border-color-medium); border-radius:4px; padding:10px;'
			}, logRows.length ? logRows : [ E('em', [ _('No logs match selected filter.') ]) ])
		]);
	},

	updateWarpAuto: function() {
		return callGetWarpAutoStatus().then(L.bind(function(state) {
			state = state || {};
			if (state.ok === false)
				throw new Error(state.error || _('Unable to read WARP Auto status'));

			this.lastAutoState = state;
			this.autoKnownInterfaces = (state.runtime && state.runtime.available_interfaces) || [];
			if (!this.autoSettingsLoaded || !this.autoSettingsDirty)
				this.setWarpAutoSettings(state.settings);
			this.autoSettingsLoaded = true;
			this.renderWarpAutoRuntime(state);
			this.renderWarpAutoPool(state);
			this.renderWarpAutoLogs(state);

			// Check for pending background activation from session
			if (!this.activationPollingActive) {
				try {
					var raw = sessionStorage.getItem('warp_auto_active_op');
					if (raw) {
						var parsed = JSON.parse(raw);
						if (parsed && parsed.op_id && (Date.now() - (parsed.start || 0) < 60000)) {
							callGetWarpAutoOperation(parsed.op_id).then(L.bind(function(opRes) {
								var op = opRes && opRes.operation;
								if (op && (op.status === 'running' || op.status === 'waiting')) {
									if (!this.activationPollingActive) {
										this.attachActivationModal(parsed.op_id, parsed.id);
									}
								} else {
									sessionStorage.removeItem('warp_auto_active_op');
								}
							}, this)).catch(function() {
								sessionStorage.removeItem('warp_auto_active_op');
							});
						} else {
							sessionStorage.removeItem('warp_auto_active_op');
						}
					}
				} catch(e) {}
			}

			// Check for pending background batch generation from session or running state
			if (!this.batchPollingActive) {
				try {
					var rawBatch = sessionStorage.getItem('warp_auto_active_batch');
					var rt = state && state.runtime;
					if (rt && rt.batch_state === 'running') {
						var parsedB = rawBatch ? JSON.parse(rawBatch) : null;
						var bCount = (parsedB && parsedB.count) || rt.batch_requested || 5;
						this.attachBatchModal(bCount);
					} else if (rawBatch) {
						var parsedB = JSON.parse(rawBatch);
						if (parsedB && (Date.now() - (parsedB.start || 0) < 180000)) {
							this.attachBatchModal(parsedB.count || 5);
						} else {
							sessionStorage.removeItem('warp_auto_active_batch');
						}
					}
				} catch(e) {}
			}

			// Check for pending background bootstrap
			if (!this.bootstrapPollingActive) {
				try {
					var rawBoot = sessionStorage.getItem('warp_auto_active_bootstrap');
					var rt = state && state.runtime;
					if (rt && rt.bootstrap_state === 'running') {
						this.attachBootstrapModal();
					} else if (rawBoot) {
						var parsedBoot = JSON.parse(rawBoot);
						if (parsedBoot && (Date.now() - (parsedBoot.start || 0) < 90000)) {
							this.attachBootstrapModal();
						} else {
							sessionStorage.removeItem('warp_auto_active_bootstrap');
						}
					}
				} catch(e) {}
			}
		}, this)).catch(L.bind(function(error) {
			this.showWarpAutoMessage(error.message || _('Unable to read WARP Auto status'), true);
		}, this));
	},

	saveWarpAutoSettings: function() {
		var settings = this.getWarpAutoSettings();

		var stepSave = E('li', { 'style': 'margin-bottom:8px;' }, [
			E('span', { 'class': 'spinning', 'style': 'margin-right:8px; font-weight:bold;' }, '⏳'),
			_('Saving configuration to /etc/config/awg-warp-auto…')
		]);
		var stepApply = E('li', { 'style': 'margin-bottom:8px; opacity:0.5;' }, [
			E('span', { 'style': 'margin-right:8px; font-weight:bold;' }, '⚪'),
			_('Applying settings & reloading service…')
		]);
		var stepVerify = E('li', { 'style': 'margin-bottom:8px; opacity:0.5;' }, [
			E('span', { 'style': 'margin-right:8px; font-weight:bold;' }, '⚪'),
			_('Verifying service state…')
		]);

		var checklistNode = E('ul', { 'style': 'list-style:none; padding-left:0; margin:16px 0;' }, [
			stepSave, stepApply, stepVerify
		]);

		var statusTextNode = E('p', { 'style': 'color:var(--text-color-medium); margin-top:8px;' }, [
			_('Please wait while changes are applied to the router…')
		]);

		var modalContent = E('div', [
			E('p', { 'style': 'font-weight:bold; margin-bottom:8px;' }, [ _('Applying configuration changes…') ]),
			checklistNode,
			statusTextNode
		]);

		ui.showModal(_('Applying Configuration'), [ modalContent ]);
		this.setWarpAutoBusy(true);

		var setStepState = function(node, state, text) {
			node.style.opacity = '1';
			var icon = state === 'active' ? '⏳' : state === 'done' ? '✓' : state === 'failed' ? '✗' : '⚪';
			var iconClass = state === 'active' ? 'spinning' : '';
			dom.content(node, [
				E('span', { 'class': iconClass, 'style': 'margin-right:8px; font-weight:bold;' }, icon),
				text
			]);
		};

		var applyTimeout = setTimeout(function() {
			setStepState(stepSave, 'done', _('Configuration saved to /etc/config/awg-warp-auto'));
			setStepState(stepApply, 'active', _('Applying settings & reloading service…'));
		}, 300);

		return callSaveWarpAutoSettings(settings, '0').then(L.bind(function(result) {
			clearTimeout(applyTimeout);
			if (!result || result.ok === false)
				throw new Error(result && result.error || _('Unable to save WARP Auto settings'));

			this.autoSettingsDirty = false;
			setStepState(stepSave, 'done', _('Configuration saved to /etc/config/awg-warp-auto'));
			setStepState(stepApply, 'done', _('Service reloaded'));
			setStepState(stepVerify, 'active', _('Verifying service state…'));

			return this.updateWarpAuto().then(L.bind(function() {
				setStepState(stepVerify, 'done', _('Configuration applied successfully'));
				statusTextNode.innerText = _('Settings applied. Closing…');
				return new Promise(function(resolve) {
					setTimeout(function() {
						ui.hideModal();
						resolve(result);
					}, 700);
				});
			}, this));
		}, this)).then(L.bind(function(result) {
			this.showWarpAutoMessage(result && result.message || _('WARP Auto settings saved.'));
			this.showNotification(_('WARP Auto settings applied successfully!'), 'info');
			this.setWarpAutoBusy(false);
			return result;
		}, this)).catch(L.bind(function(error) {
			clearTimeout(applyTimeout);
			setStepState(stepApply, 'failed', _('Failed to apply configuration'));
			this.showWarpAutoMessage(error.message || _('Unable to save WARP Auto settings'), true);
			this.showNotification(error.message || _('Unable to save WARP Auto settings'), 'error');

			dom.content(modalContent, [
				E('p', { 'style': 'font-weight:bold; color:var(--danger-color, #c00); margin-bottom:8px;' }, [
					_('Configuration Error')
				]),
				E('div', { 'class': 'alert-message error', 'style': 'margin:12px 0;' }, [
					error.message || _('Unable to save WARP Auto settings')
				]),
				E('div', { 'class': 'right', 'style': 'margin-top:16px; display:flex; justify-content:flex-end;' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-neutral',
						'click': function() { ui.hideModal(); }
					}, [ _('Dismiss') ])
				])
			]);
			this.setWarpAutoBusy(false);
		}, this));
	},

	attachActivationModal: function(operationId, id) {
		var stepApplying = E('li', { 'style': 'margin-bottom:8px;' }, [
			E('span', { 'class': 'spinning', 'style': 'margin-right:8px;' }, '⏳'),
			_('Applying configuration to network interface…')
		]);
		var stepHealth = E('li', { 'style': 'margin-bottom:8px; opacity:0.5;' }, [
			E('span', { 'style': 'margin-right:8px;' }, '⚪'),
			_('Running connectivity health check (YouTube/DNS)…')
		]);
		var stepFinalize = E('li', { 'style': 'margin-bottom:8px; opacity:0.5;' }, [
			E('span', { 'style': 'margin-right:8px;' }, '⚪'),
			_('Finalizing activation and committing state…')
		]);

		var checklistNode = E('ul', { 'style': 'list-style:none; padding-left:0; margin:16px 0;' }, [
			stepApplying, stepHealth, stepFinalize
		]);

		var statusTextNode = E('p', { 'style': 'color:var(--text-color-medium); margin-top:8px;' }, [
			_('Please wait, profile activation and verification may take up to 40 seconds.')
		]);

		var modalContent = E('div', [
			E('p', [ _('Activating AmneziaWG profile %s…').format(id || _('profile')) ]),
			checklistNode,
			statusTextNode
		]);

		ui.showModal(_('Profile Activation'), [ modalContent ]);
		this.setWarpAutoBusy(true);

		try { poll.stop(); } catch(e) {}

		var startTime = Date.now();
		var timeoutMs = 60000;

		try {
			sessionStorage.setItem('warp_auto_active_op', JSON.stringify({ op_id: operationId, id: id, start: startTime }));
		} catch(e) {}

		var setStepState = function(node, state, text) {
			node.style.opacity = '1';
			var icon = state === 'active' ? '⏳' : state === 'done' ? '✓' : state === 'failed' ? '✗' : '⚪';
			var iconClass = state === 'active' ? 'spinning' : '';
			dom.content(node, [
				E('span', { 'class': iconClass, 'style': 'margin-right:8px; font-weight:bold;' }, icon),
				text
			]);
		};

		var cleanup = L.bind(function() {
			try { sessionStorage.removeItem('warp_auto_active_op'); } catch(e) {}
			this.activationPollingActive = false;
			try { poll.start(); } catch(e) {}
			this.setWarpAutoBusy(false);
			this.updateWarpAuto();
		}, this);

		this.activationPollingActive = true;

		return new Promise(L.bind(function(resolve, reject) {
			var pollInterval = setInterval(L.bind(function() {
				if (Date.now() - startTime > timeoutMs) {
					clearInterval(pollInterval);
					callGetWarpAutoStatus().then(L.bind(function(st) {
						ui.hideModal();
						cleanup();
						var activeNow = (st && st.runtime && st.runtime.active_id) || (st && st.active_id);
						if (activeNow === id) {
							this.showNotification(_('Profile %s activated successfully.').format(id), 'info');
						} else {
							this.showNotification(_('Activation timed out. Previous profile remained active.'), 'warning');
						}
						resolve();
					}, this)).catch(function(err) {
						ui.hideModal();
						cleanup();
						reject(err);
					});
					return;
				}

				callGetWarpAutoOperation(operationId).then(L.bind(function(opRes) {
					var op = (opRes && opRes.operation) || null;
					if (!op) return;

					if (op.step === 'applying' || op.step === 'waiting') {
						setStepState(stepApplying, 'active', _('Applying configuration to network interface…'));
					} else if (op.step === 'health_check') {
						setStepState(stepApplying, 'done', _('Configuration applied to network interface'));
						setStepState(stepHealth, 'active', _('Running connectivity health check (YouTube/DNS)…'));
					} else if (op.step === 'rolling_back') {
						setStepState(stepApplying, 'done', _('Configuration applied to network interface'));
						setStepState(stepHealth, 'failed', _('Health check failed (%s)').format(op.error || _('connectivity error')));
						setStepState(stepFinalize, 'active', _('Rolling back to previous working profile…'));
					}

					if (op.status === 'success') {
						clearInterval(pollInterval);
						setStepState(stepApplying, 'done', _('Configuration applied to network interface'));
						setStepState(stepHealth, 'done', _('Connectivity health check passed'));
						setStepState(stepFinalize, 'done', _('Profile activated successfully'));
						setTimeout(L.bind(function() {
							ui.hideModal();
							cleanup();
							this.showNotification(_('Profile %s activated successfully!').format(id), 'info');
							resolve();
						}, this), 800);
					} else if (op.status === 'rolled_back') {
						clearInterval(pollInterval);
						setStepState(stepFinalize, 'failed', _('Rolled back: %s').format(op.error || _('health check failed')));
						setTimeout(L.bind(function() {
							ui.hideModal();
							cleanup();
							this.showNotification(_('Activation failed (%s). Previous profile restored.').format(op.error || 'health check failed'), 'warning');
							resolve();
						}, this), 1200);
					} else if (op.status === 'failed') {
						clearInterval(pollInterval);
						setStepState(stepFinalize, 'failed', _('Failed: %s').format(op.error || _('unknown error')));
						setTimeout(L.bind(function() {
							ui.hideModal();
							cleanup();
							this.showNotification(_('Activation error: %s').format(op.error || 'unknown error'), 'error');
							reject(new Error(op.error));
						}, this), 1200);
					}
				}, this)).catch(function(err) {
					// Ignored transient read error during polling
				});
			}, this), 1000);
		}, this));
	},

	runActivationFlow: function(id) {
		return callWarpAutoAction('activate', id).then(L.bind(function(res) {
			if (!res || res.ok === false)
				throw new Error((res && res.error) || _('Failed to start profile activation'));

			return this.attachActivationModal(res.operation_id, id);
		}, this)).catch(L.bind(function(error) {
			try { sessionStorage.removeItem('warp_auto_active_op'); } catch(e) {}
			ui.hideModal();
			try { poll.start(); } catch(e) {}
			this.setWarpAutoBusy(false);
			this.showWarpAutoMessage(error.message || _('Activation failed'), true);
			this.showNotification(error.message || _('Activation failed'), 'error');
		}, this));
	},

	attachBatchModal: function(count) {
		count = count || 5;
		var statusNode = E('span', { 'id': 'batch-status-text' }, [ _('Starting batch generation…') ]);
		var counterNode = E('span', { 'id': 'batch-counter-text' }, [ '0 / ' + count ]);
		var progressBar = E('div', { 'id': 'batch-progress-bar', 'style': 'height:100%; width:5%; background:var(--primary-color-medium, #0069d6); transition:width 0.3s ease;' });
		var readyCount = E('strong', { 'id': 'batch-ready-count', 'style': 'color:#2ecc71;' }, '0');
		var failedCount = E('strong', { 'id': 'batch-failed-count', 'style': 'color:#e74c3c;' }, '0');
		var detailMsg = E('div', { 'id': 'batch-message-detail', 'style': 'font-size:13px; font-style:italic; color:var(--text-color-medium); margin-top:8px;' }, [
			_('Connecting to registration API…')
		]);

		var runInBackgroundBtn = E('button', {
			'class': 'btn cbi-button',
			'click': function() {
				ui.hideModal();
			}
		}, [ _('Run in background') ]);

		var modalContent = E('div', { 'class': 'warp-auto-batch-modal', 'style': 'padding:10px 0;' }, [
			E('p', { 'style': 'margin-bottom:12px; color:var(--text-color-medium);' }, [
				_('Acquiring and testing a batch of %d profiles. This may take 30–90 seconds.').format(count)
			]),
			E('div', { 'class': 'batch-progress-box', 'style': 'background:var(--background-color-low); border:1px solid var(--border-color-medium); border-radius:4px; padding:12px; margin-bottom:14px;' }, [
				E('div', { 'style': 'display:flex; justify-content:space-between; margin-bottom:8px; font-weight:600;' }, [
					statusNode, counterNode
				]),
				E('div', { 'style': 'height:8px; width:100%; background:var(--border-color-medium); border-radius:4px; overflow:hidden;' }, [
					progressBar
				]),
				E('div', { 'style': 'display:flex; gap:16px; margin-top:10px; font-size:12px; color:var(--text-color-medium);' }, [
					E('span', {}, [ _('READY: '), readyCount ]),
					E('span', {}, [ _('FAILED: '), failedCount ])
				])
			]),
			detailMsg,
			E('div', { 'class': 'right', 'style': 'margin-top:16px; display:flex; justify-content:flex-end;' }, [
				runInBackgroundBtn
			])
		]);

		ui.showModal(_('Generating WARP Profiles'), [ modalContent ]);
		this.setWarpAutoBusy(true);

		var startTime = Date.now();
		var timeoutMs = Math.max(180000, (count || 5) * 60000 + 60000);

		try {
			sessionStorage.setItem('warp_auto_active_batch', JSON.stringify({ count: count, start: startTime }));
		} catch(e) {}

		var cleanup = L.bind(function() {
			try { sessionStorage.removeItem('warp_auto_active_batch'); } catch(e) {}
			this.batchPollingActive = false;
			this.setWarpAutoBusy(false);
			this.updateWarpAuto();
		}, this);

		this.batchPollingActive = true;

		return new Promise(L.bind(function(resolve, reject) {
			var pollInterval = setInterval(L.bind(function() {
				if (Date.now() - startTime > timeoutMs) {
					clearInterval(pollInterval);
					ui.hideModal();
					cleanup();
					this.showNotification(_('Batch generation timed out.'), 'warning');
					resolve();
					return;
				}

				callGetWarpAutoStatus().then(L.bind(function(st) {
					var rt = (st && st.runtime) || {};
					var generated = rt.batch_generated || 0;
					var requested = rt.batch_requested || count;
					var ready = rt.batch_ready || 0;
					var failed = rt.batch_failed || 0;
					var pct = Math.min(100, Math.max(5, Math.round(((generated + (rt.batch_state === 'running' ? 0.3 : 0)) / (requested || 1)) * 100)));

					counterNode.innerText = generated + ' / ' + requested;
					progressBar.style.width = pct + '%';
					readyCount.innerText = ready;
					failedCount.innerText = failed;
					if (rt.batch_message) detailMsg.innerText = rt.batch_message;

					if (rt.batch_state === 'running') {
						var currIdx = Math.min(generated + 1, requested);
						statusNode.innerText = _('Processing profile %d of %d…').format(currIdx, requested);
					} else if (rt.batch_state === 'complete') {
						clearInterval(pollInterval);
						statusNode.innerText = _('Batch generation completed');
						progressBar.style.width = '100%';
						counterNode.innerText = requested + ' / ' + requested;
						setTimeout(L.bind(function() {
							ui.hideModal();
							cleanup();
							this.showNotification(
								_('Batch generation complete: %d READY, %d FAILED of %d requested.').format(ready, failed, requested),
								ready > 0 ? 'info' : 'warning'
							);
							resolve();
						}, this), 1000);
					} else if (rt.batch_state === 'failed') {
						clearInterval(pollInterval);
						statusNode.innerText = _('Batch generation failed');
						setTimeout(L.bind(function() {
							ui.hideModal();
							cleanup();
							this.showNotification(_('Batch generation failed: %s').format(rt.batch_message || _('unknown error')), 'error');
							reject(new Error(rt.batch_message));
						}, this), 1200);
					}
				}, this)).catch(function(err) {});
			}, this), 1000);
		}, this));
	},

	runBatchFlow: function(count) {
		var action = 'batch';
		count = count || 5;
		this.setWarpAutoBusy(true);
		this.showWarpAutoMessage(_('Starting batch profile generation…'));

		return callSaveWarpAutoSettings(this.getWarpAutoSettings(), '1').then(L.bind(function(saved) {
			if (!saved || saved.ok === false)
				throw new Error(saved && saved.error || _('Unable to save WARP Auto settings'));
			this.autoSettingsDirty = false;
			return callWarpAutoAction(action, String(count || ''));
		}, this)).then(L.bind(function(result) {
			if (!result || result.ok === false)
				throw new Error((result && result.error) || _('Failed to start batch generation'));

			return this.attachBatchModal(count);
		}, this)).catch(L.bind(function(error) {
			try { sessionStorage.removeItem('warp_auto_active_batch'); } catch(e) {}
			ui.hideModal();
			try { poll.start(); } catch(e) {}
			this.setWarpAutoBusy(false);
			this.showWarpAutoMessage(error.message || _('Batch generation failed'), true);
			this.showNotification(error.message || _('Batch generation failed'), 'error');
		}, this));
	},

	attachRetestAllModal: function() {
		var statusNode = E('span', { 'style': 'font-size:14px; color:var(--text-color-high);' }, [ _('Retesting pool profiles…') ]);
		var counterNode = E('span', { 'style': 'font-size:14px; font-weight:bold;' }, [ '0 / 0' ]);
		var progressBar = E('div', {
			'style': 'height:100%; width:5%; background:var(--primary-color-medium, #0069d6); border-radius:4px; transition:width 0.3s ease;'
		});
		var readyCount = E('strong', { 'style': 'color:var(--success-color, #2ea44f);' }, [ '0' ]);
		var failedCount = E('strong', { 'style': 'color:var(--danger-color, #d73a49);' }, [ '0' ]);
		var detailMsg = E('div', {
			'style': 'font-family:var(--font-mono, monospace); font-size:12px; color:var(--text-color-medium); min-height:2.2em; word-break:break-all; background:var(--background-color-low); padding:6px 10px; border-radius:3px; border:1px solid var(--border-color-low);'
		}, [ _('Initializing retest…') ]);

		var runInBackgroundBtn = E('button', {
			'class': 'btn cbi-button',
			'click': function() {
				ui.hideModal();
			}
		}, [ _('Run in background') ]);

		var modalContent = E('div', { 'class': 'warp-auto-retest-modal', 'style': 'padding:10px 0;' }, [
			E('p', { 'style': 'margin-bottom:12px; color:var(--text-color-medium);' }, [
				_('Benchmarking YouTube reachability and download speed (25MB streamed to /dev/null) for all pool profiles.')
			]),
			E('div', { 'class': 'batch-progress-box', 'style': 'background:var(--background-color-low); border:1px solid var(--border-color-medium); border-radius:4px; padding:12px; margin-bottom:14px;' }, [
				E('div', { 'style': 'display:flex; justify-content:space-between; margin-bottom:8px; font-weight:600;' }, [
					statusNode, counterNode
				]),
				E('div', { 'style': 'height:10px; width:100%; background:var(--border-color-medium); border-radius:4px; overflow:hidden;' }, [
					progressBar
				]),
				E('div', { 'style': 'display:flex; gap:16px; margin-top:10px; font-size:12px; color:var(--text-color-medium);' }, [
					E('span', {}, [ _('OK: '), readyCount ]),
					E('span', {}, [ _('FAILED: '), failedCount ])
				])
			]),
			detailMsg,
			E('div', { 'class': 'right', 'style': 'margin-top:16px; display:flex; justify-content:flex-end;' }, [
				runInBackgroundBtn
			])
		]);

		ui.showModal(_('Retesting All Profiles'), [ modalContent ]);
		this.setWarpAutoBusy(true);

		var startTime = Date.now();
		var timeoutMs = 300000;

		var cleanup = L.bind(function() {
			this.retestPollingActive = false;
			this.setWarpAutoBusy(false);
			this.updateWarpAuto();
		}, this);

		this.retestPollingActive = true;

		return new Promise(L.bind(function(resolve, reject) {
			var pollInterval = setInterval(L.bind(function() {
				if (Date.now() - startTime > timeoutMs) {
					clearInterval(pollInterval);
					ui.hideModal();
					cleanup();
					this.showNotification(_('Retest timed out.'), 'warning');
					resolve();
					return;
				}

				callGetWarpAutoStatus().then(L.bind(function(st) {
					var rt = (st && st.runtime) || {};
					var tested = rt.batch_generated || 0;
					var requested = rt.batch_requested || 0;
					var ready = rt.batch_ready || 0;
					var failed = rt.batch_failed || 0;

					if (requested > 0) {
						var step = rt.batch_state === 'running' ? (tested + 0.5) : tested;
						var pct = Math.min(100, Math.max(5, Math.round((step / requested) * 100)));
						progressBar.style.width = pct + '%';
						counterNode.innerText = (rt.batch_state === 'running' ? Math.min(tested + 1, requested) : tested) + ' / ' + requested;
					}

					readyCount.innerText = ready;
					failedCount.innerText = failed;
					if (rt.batch_message) detailMsg.innerText = rt.batch_message;

					if (rt.batch_state === 'running') {
						if (requested > 0) {
							var currIdx = Math.min(tested + 1, requested);
							statusNode.innerText = _('Testing profile %d of %d…').format(currIdx, requested);
						} else {
							statusNode.innerText = _('Testing profiles…');
						}
					} else if (rt.batch_state === 'complete') {
						clearInterval(pollInterval);
						statusNode.innerText = _('Retest completed');
						progressBar.style.width = '100%';
						if (requested > 0) counterNode.innerText = requested + ' / ' + requested;
						setTimeout(L.bind(function() {
							ui.hideModal();
							cleanup();
							this.showNotification(
								_('Retest complete: %d OK, %d FAILED of %d profiles.').format(ready, failed, requested || (ready + failed)),
								'info'
							);
							resolve();
						}, this), 800);
					} else if (rt.batch_state === 'failed') {
						clearInterval(pollInterval);
						statusNode.innerText = _('Retest failed');
						setTimeout(L.bind(function() {
							ui.hideModal();
							cleanup();
							this.showNotification(_('Retest failed: %s').format(rt.batch_message || _('unknown error')), 'error');
							reject(new Error(rt.batch_message));
						}, this), 1200);
					}
				}, this)).catch(function(err) {});
			}, this), 1000);
		}, this));
	},

	runRetestAllFlow: function() {
		if (this.autoBusy) return;
		this.setWarpAutoBusy(true);
		this.showWarpAutoMessage(_('Starting retest of all profiles…'));

		return callWarpAutoAction('test_all', '').then(L.bind(function(result) {
			if (!result || result.ok === false)
				throw new Error((result && result.error) || _('Failed to start retest'));

			return this.attachRetestAllModal();
		}, this)).catch(L.bind(function(error) {
			ui.hideModal();
			this.setWarpAutoBusy(false);
			this.showWarpAutoMessage(error.message || _('Retest failed'), true);
			this.showNotification(error.message || _('Retest failed'), 'error');
		}, this));
	},

	attachBootstrapModal: function() {
		var stepCheck = E('li', { 'style': 'margin-bottom:8px;' }, [ '⚪ ', _('Checking environment & requirements…') ]);
		var stepFetch = E('li', { 'style': 'margin-bottom:8px; opacity:0.5;' }, [ '⚪ ', _('Generating and testing initial WARP profile…') ]);
		var stepIface = E('li', { 'style': 'margin-bottom:8px; opacity:0.5;' }, [ '⚪ ', _('Configuring network interface and policy routing…') ]);
		var stepFinal = E('li', { 'style': 'margin-bottom:8px; opacity:0.5;' }, [ '⚪ ', _('Finalizing interface activation…') ]);

		var runInBackgroundBtn = E('button', {
			'class': 'btn cbi-button',
			'click': function() {
				ui.hideModal();
			}
		}, [ _('Run in background') ]);

		var modalContent = E('div', { 'class': 'warp-auto-bootstrap-modal' }, [
			E('p', [ _('Setting up dedicated WARP interface. Please wait…') ]),
			E('ul', { 'style': 'list-style:none; padding-left:0; line-height:1.6;' }, [
				stepCheck, stepFetch, stepIface, stepFinal
			]),
			E('div', { 'class': 'right', 'style': 'margin-top:16px; display:flex; justify-content:flex-end;' }, [
				runInBackgroundBtn
			])
		]);

		ui.showModal(_('Creating WARP Interface'), [ modalContent ]);
		this.setWarpAutoBusy(true);

		var startTime = Date.now();
		var timeoutMs = 120000;

		try {
			sessionStorage.setItem('warp_auto_active_bootstrap', JSON.stringify({ start: startTime }));
		} catch(e) {}

		var setStep = function(node, state, text) {
			node.style.opacity = '1';
			var icon = state === 'active' ? '⏳' : state === 'done' ? '✓' : state === 'failed' ? '✗' : '⚪';
			var iconClass = state === 'active' ? 'spinning' : '';
			dom.content(node, [
				E('span', { 'class': iconClass, 'style': 'margin-right:8px; font-weight:bold;' }, icon),
				text
			]);
		};

		setStep(stepCheck, 'done', _('Environment check completed'));
		setStep(stepFetch, 'active', _('Generating and testing initial WARP profile…'));

		var cleanup = L.bind(function() {
			try { sessionStorage.removeItem('warp_auto_active_bootstrap'); } catch(e) {}
			this.bootstrapPollingActive = false;
			try { poll.start(); } catch(e) {}
			this.setWarpAutoBusy(false);
			this.updateWarpAuto();
		}, this);

		this.bootstrapPollingActive = true;

		return new Promise(L.bind(function(resolve, reject) {
			var pollInterval = setInterval(L.bind(function() {
				if (Date.now() - startTime > timeoutMs) {
					clearInterval(pollInterval);
					ui.hideModal();
					cleanup();
					this.showNotification(_('Interface creation timed out.'), 'warning');
					resolve();
					return;
				}

				callGetWarpAutoStatus().then(L.bind(function(st) {
					var rt = (st && st.runtime) || {};
					if (rt.bootstrap_state === 'ready') {
						clearInterval(pollInterval);
						setStep(stepFetch, 'done', _('Initial profile generated and tested'));
						setStep(stepIface, 'done', _('Network interface and routing configured'));
						setStep(stepFinal, 'done', _('WARP interface created and active'));
						setTimeout(L.bind(function() {
							ui.hideModal();
							cleanup();
							this.showNotification(_('WARP interface created successfully!'), 'info');
							resolve();
						}, this), 1000);
					} else if (rt.bootstrap_state === 'failed') {
						clearInterval(pollInterval);
						setStep(stepFinal, 'failed', _('Bootstrap failed: %s').format(rt.bootstrap_error || _('activation failed')));
						setTimeout(L.bind(function() {
							ui.hideModal();
							cleanup();
							this.showNotification(_('Bootstrap failed: %s').format(rt.bootstrap_error || _('activation failed')), 'error');
							reject(new Error(rt.bootstrap_error));
						}, this), 1200);
					}
				}, this)).catch(function() {});
			}, this), 1000);
		}, this));
	},

	runBootstrapFlow: function() {
		this.setWarpAutoBusy(true);
		this.showWarpAutoMessage(_('Creating and testing WARP interface…'));

		return callSaveWarpAutoSettings(this.getWarpAutoSettings(), '1').then(L.bind(function(saved) {
			if (!saved || saved.ok === false)
				throw new Error(saved && saved.error || _('Unable to save WARP Auto settings'));
			this.autoSettingsDirty = false;
			return callWarpAutoAction('bootstrap', '');
		}, this)).then(L.bind(function(result) {
			if (!result || result.ok === false)
				throw new Error((result && result.error) || _('Failed to start initial WARP setup'));

			return this.attachBootstrapModal();
		}, this)).catch(L.bind(function(error) {
			try { sessionStorage.removeItem('warp_auto_active_bootstrap'); } catch(e) {}
			ui.hideModal();
			try { poll.start(); } catch(e) {}
			this.setWarpAutoBusy(false);
			this.showWarpAutoMessage(error.message || _('Bootstrap failed'), true);
			this.showNotification(error.message || _('Bootstrap failed'), 'error');
		}, this));
	},

	runWarpAutoAction: function(action, profileId) {
		/* RPC declares id as a string. Send an empty string for actions that
		 * do not target a pool entry, otherwise ubus rejects the request before
		 * the backend can dispatch refresh/test_all/rollback. */
		var id = profileId || '';
		var actionNames = {
			refresh: _('Refreshing configurations…'),
			batch: _('Generating profiles batch…'),
			test_all: _('Testing configurations…'),
			activate: _('Activating selected profile…'),
			retest: _('Retesting profile…'),
			native_test: _('Generating and testing Native profile…'),
			force_replenish: _('Replenishing profile pool (force)…'),
			rollback: _('Rolling back profile…'),
			bootstrap: _('Creating and testing WARP interface…')
		};

		if (action == 'activate') {
			if (!id) {
				this.showWarpAutoMessage(_('Select a READY profile first.'), true);
				return Promise.resolve();
			}
			return this.runActivationFlow(id);
		}

		if (action == 'batch' || action == 'generate_batch') {
			var batchCount = (this.autoFields && this.autoFields.batch_size && parseInt(this.autoFields.batch_size.value, 10)) || 5;
			return this.runBatchFlow(batchCount);
		}

		if (action == 'native_test') {
			return this.runBatchFlow(1);
		}

		if (action == 'bootstrap') {
			return this.runBootstrapFlow();
		}

		if (action == 'clean_replenish') {
			var pool = (this.lastAutoState && this.lastAutoState.pool) || [];
			var inactiveCount = pool.filter(function(e) { return !e.active; }).length;
			var minReady = (this.lastAutoState && this.lastAutoState.settings && this.lastAutoState.settings.minimum_ready != null)
				? this.lastAutoState.settings.minimum_ready : 2;
			if (inactiveCount === 0) {
				this.showNotification(_('No inactive profiles to delete.'), 'info');
				return Promise.resolve();
			}
			if (!confirm(_('Delete %d inactive profiles? The system will automatically generate new profiles up to the minimum ready threshold (%d).').format(inactiveCount, minReady))) {
				return Promise.resolve();
			}
			return this.runCleanReplenishFlow();
		}

		this.setWarpAutoBusy(true);
		this.showWarpAutoMessage(actionNames[action] || _('Running WARP Auto action…'));

		var request = action == 'bootstrap' || action == 'native_test' || action == 'batch'
			? callSaveWarpAutoSettings(this.getWarpAutoSettings(), '1').then(L.bind(function(saved) {
				if (!saved || saved.ok === false)
					throw new Error(saved && saved.error || _('Unable to save WARP Auto settings'));
				this.autoSettingsDirty = false;
				return callWarpAutoAction(action, id);
			}, this))
			: callWarpAutoAction(action, id);

		return request.then(L.bind(function(result) {
			if (!result || result.ok === false)
				throw new Error(result && result.error || _('WARP Auto action failed'));

			this.showWarpAutoMessage(result.message || (action == 'bootstrap'
				? _('Initial setup started. Follow its state below.')
				: _('WARP Auto action completed.')));
			return this.updateWarpAuto();
		}, this)).catch(L.bind(function(error) {
			this.showWarpAutoMessage(error.message || _('WARP Auto action failed'), true);
			this.showNotification(error.message || _('WARP Auto action failed'), 'error');
		}, this)).then(L.bind(function(result) {
			this.setWarpAutoBusy(false);
			return result;
		}, this));
	},

	deleteWarpAutoProfile: function(id) {
		this.setWarpAutoBusy(true);
		this.showWarpAutoMessage(_('Deleting profile %s…').format(id));

		return callWarpAutoAction('delete', id).then(L.bind(function(res) {
			if (!res || res.ok === false)
				throw new Error((res && res.error) || _('Failed to delete profile'));

			this.showNotification(_('Profile %s deleted.').format(id), 'info');
			this.showWarpAutoMessage(_('Profile %s deleted.').format(id));
			return this.updateWarpAuto();
		}, this)).catch(L.bind(function(err) {
			this.showNotification(err.message || _('Failed to delete profile'), 'error');
			this.showWarpAutoMessage(err.message || _('Failed to delete profile'), true);
		}, this)).then(L.bind(function() {
			this.setWarpAutoBusy(false);
		}, this));
	},

	runCleanReplenishFlow: function() {
		var minReady = (this.lastAutoState && this.lastAutoState.settings && this.lastAutoState.settings.minimum_ready != null)
			? this.lastAutoState.settings.minimum_ready : 2;
		this.setWarpAutoBusy(true);
		this.showWarpAutoMessage(_('Deleting inactive profiles and replenishing pool…'));

		return callSaveWarpAutoSettings(this.getWarpAutoSettings(), '1').then(L.bind(function(saved) {
			if (!saved || saved.ok === false)
				throw new Error(saved && saved.error || _('Unable to save WARP Auto settings'));
			this.autoSettingsDirty = false;
			return callWarpAutoAction('clean_replenish', '');
		}, this)).then(L.bind(function(result) {
			if (!result || result.ok === false)
				throw new Error((result && result.error) || _('Failed to start clean & replenish'));

			return this.attachBatchModal(minReady);
		}, this)).catch(L.bind(function(error) {
			try { sessionStorage.removeItem('warp_auto_active_batch'); } catch(e) {}
			ui.hideModal();
			this.setWarpAutoBusy(false);
			this.showWarpAutoMessage(error.message || _('Clean and replenish failed'), true);
			this.showNotification(error.message || _('Clean and replenish failed'), 'error');
		}, this));
	},

	renderWarpAuto: function() {
		var fields = {};
		var dirty = L.bind(this.markWarpAutoSettingsDirty, this);
		var makeInput = function(name, type, attrs) {
			attrs = attrs || {};
			attrs.type = type;
			attrs.name = name;
			attrs['class'] = attrs['class'] || 'cbi-input-text';
			var input = E('input', attrs);
			input.addEventListener('input', dirty);
			input.addEventListener('change', dirty);
			fields[name] = input;
			return input;
		};
		var makeRow = function(label, control, help) {
			return E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ label ]),
				E('div', { 'class': 'cbi-value-field' }, [
					control,
					help ? E('div', { 'class': 'cbi-value-description' }, [ help ]) : ''
				])
			]);
		};
		var enabled = makeInput('enabled', 'checkbox', { 'class': 'cbi-input-checkbox' });
		var failover = makeInput('automatic_failover', 'checkbox', { 'class': 'cbi-input-checkbox' });
		var failoverCooldown = makeInput('failover_cooldown', 'number', { 'min': 5, 'max': 3600, 'step': 1 });
		var target = E('select', { 'class': 'cbi-input-select', 'name': 'interface' }, []);
		target.addEventListener('change', dirty);
		fields.interface = target;
		var source = makeInput('source_url', 'url', {
			'placeholder': DEFAULT_WARP_SOURCE_URL,
			'style': 'width:100%; max-width:40em'
		});
		var provider = E('select', { 'class': 'cbi-input-select', 'name': 'provider' }, [
			E('option', { 'value': 'remote' }, [ _('Remote') ]),
			E('option', { 'value': 'native' }, [ _('Native') ])
		]);
		fields.provider = provider;
		provider.addEventListener('change', dirty);
		provider.addEventListener('change', L.bind(this.updateProviderFields, this));
		var awgVersion = E('select', { 'class': 'cbi-input-select', 'name': 'awg_version' }, [
			E('option', { 'value': 'v3_hybrid' }, [ _('AWG 3.0 + 3.1 Hybrid (Recommended)') ]),
			E('option', { 'value': 'v3_0' }, [ _('AWG 3.0 (Advanced Obfuscation)') ]),
			E('option', { 'value': 'v3_1' }, [ _('AWG 3.1 (Random Trailers & Anti-Cookie)') ]),
			E('option', { 'value': 'v2' }, [ _('AWG 2.0 (Legacy Obfuscation)') ])
		]);
		fields.awg_version = awgVersion;
		awgVersion.addEventListener('change', dirty);
		var nativeSni = makeInput('native_sni', 'text', { 'placeholder': 'w3.org', 'maxlength': 253 });
		var nativeQuicMode = E('select', { 'class': 'cbi-input-select', 'name': 'native_quic_mode' }, [
			E('option', { 'value': 'dynamic' }, [ _('Dynamic local SNI I1 (Recommended)') ]),
			E('option', { 'value': 'fallback' }, [ _('Compatibility preset (Fallback only)') ])
		]);
		fields.native_quic_mode = nativeQuicMode;
		nativeQuicMode.addEventListener('change', dirty);
		var nativeEndpointMode = E('select', { 'class': 'cbi-input-select', 'name': 'native_endpoint_mode' }, [
			E('option', { 'value': 'auto' }, [ _('Auto: Cloudflare registration endpoint') ]),
			E('option', { 'value': 'custom' }, [ _('Custom pool only') ]),
			E('option', { 'value': 'auto_custom' }, [ _('Auto, then custom fallback') ])
		]);
		fields.native_endpoint_mode = nativeEndpointMode;
		nativeEndpointMode.addEventListener('change', dirty);
		var batchSizeInput = makeInput('batch_size', 'number', { 'min': 1, 'max': 10, 'step': 1 });
		var nativeInterval = makeInput('native_min_interval', 'number', { 'min': 60, 'step': 1 });
		var nativeEndpoints = E('textarea', { 'rows': 4, 'class': 'cbi-input-text', 'style': 'width:100%; max-width:40em' });
		fields.native_endpoints = nativeEndpoints;
		nativeEndpoints.addEventListener('input', dirty);
		var refresh = makeInput('refresh_interval', 'number', { 'min': 60, 'step': 1 });
		var minimumReady = makeInput('minimum_ready', 'number', { 'min': 0, 'max': 10, 'step': 1 });
		var healthInterval = makeInput('health_interval', 'number', { 'min': 5, 'step': 1 });
		var failureThreshold = makeInput('failure_threshold', 'number', { 'min': 1, 'step': 1 });
		var healthTimeout = makeInput('health_timeout', 'number', { 'min': 1, 'step': 1 });
		var strictHealth = makeInput('health_mode', 'checkbox', { 'class': 'cbi-input-checkbox' });
		var healthResolvers = makeInput('health_resolvers', 'text', {
			'placeholder': '1.1.1.1 8.8.8.8 9.9.9.9 77.88.8.8 77.88.8.1',
			'style': 'width:100%; max-width:40em'
		});
		var logLevel = E('select', { 'class': 'cbi-input-select', 'name': 'log_level' }, [
			E('option', { 'value': 'error' }, [ _('Error only') ]),
			E('option', { 'value': 'warning' }, [ _('Warnings and errors') ]),
			E('option', { 'value': 'info' }, [ _('Important events') ]),
			E('option', { 'value': 'debug' }, [ _('Debug: include successful health checks') ])
		]);
		var critical = E('textarea', {
			'name': 'critical_resource',
			'rows': 4,
			'class': 'cbi-input-text',
			'style': 'width:100%; max-width:40em'
		});
		var saveButton = E('button', {
			'class': 'btn cbi-button cbi-button-save',
			'click': L.bind(function(event) {
				event.preventDefault();
				return this.saveWarpAutoSettings();
			}, this)
		}, [ _('Save & Apply') ]);
		var generateButton = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'title': _('Acquire and test a batch of profiles using currently selected Provider (Remote generator or Native registration API)'),
			'click': L.bind(function(event) {
				event.preventDefault();
				return this.runWarpAutoAction('batch');
			}, this)
		}, [ _('Generate batch') ]);
		this.autoGenerateButton = generateButton;

		var testButton = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'title': _('Benchmark latency and download speed for all profiles in the pool'),
			'click': L.bind(function(event) {
				event.preventDefault();
				return this.runRetestAllFlow();
			}, this)
		}, [ _('Retest all') ]);

		var cleanButton = E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'title': _('Delete all profiles except currently active and replenish pool up to minimum ready threshold'),
			'click': L.bind(function(event) {
				event.preventDefault();
				return this.runWarpAutoAction('clean_replenish');
			}, this)
		}, [ _('Delete all except active') ]);

		var bootstrapButton = E('button', {
			'class': 'btn cbi-button cbi-button-positive',
			'disabled': true,
			'click': L.bind(function(event) {
				event.preventDefault();
				return this.runWarpAutoAction('bootstrap');
			}, this)
		}, [ _('Create WARP interface') ]);

		critical.addEventListener('input', dirty);
		critical.addEventListener('change', dirty);
		logLevel.addEventListener('change', dirty);

		this.autoFields = fields;
		this.autoFields.critical_resource = critical;
		this.autoFields.log_level = logLevel;
		this.autoSaveButton = saveButton;
		this.autoBootstrapButton = bootstrapButton;
		this.autoActionButtons = [ bootstrapButton, generateButton, testButton, cleanButton ];
		this.autoMessageNode = E('span', { 'style': 'margin-left:1em' });
		this.autoRuntimeNode = E('div', [ E('em', [ _('Loading WARP Auto status…') ]) ]);
		this.autoPoolNode = E('div', [ E('em', [ _('Loading WARP Auto pool…') ]) ]);
		this.autoLogsNode = E('div', [ E('em', [ _('Loading WARP Auto logs…') ]) ]);
		this.autoSettingsLoaded = false;
		this.autoSettingsDirty = false;
		this.autoBusy = false;
		this.remoteSettingsNode = E('div', [
			makeRow(_('Profile batch size'), batchSizeInput, _('Number of profiles acquired per batch generation (1..10, default 5).')),
			makeRow(_('Config source URL'), source, _('Default: %s. Change this for a mirror or compatible source.').format(DEFAULT_WARP_SOURCE_URL))
		]);

		// Native Provider Basic & Advanced Collapsible Section
		var nativeAdvancedToggle = E('a', {
			'href': '#',
			'style': 'font-weight:600; text-decoration:none; display:inline-block; margin:8px 0 12px 0;',
			'click': function(ev) {
				ev.preventDefault();
				var advNode = ev.target.nextElementSibling;
				var isHidden = advNode.style.display === 'none';
				advNode.style.display = isHidden ? '' : 'none';
				ev.target.innerText = isHidden ? _('▾ Hide Advanced Native Settings') : _('▸ Show Advanced Native Settings');
			}
		}, [ _('▸ Show Advanced Native Settings') ]);

		var nativeAdvancedSection = E('div', { 'style': 'display:none; padding-left:12px; border-left:2px solid var(--border-color-medium);' }, [
			makeRow(_('QUIC SNI'), nativeSni, _('Server Name Indication hostname encoded into dynamic QUIC I1.')),
			makeRow(_('QUIC mode'), nativeQuicMode, _('Dynamic local SNI I1 uses /usr/bin/quic-i1. Compatibility preset acts as error fallback if helper is unavailable.')),
			makeRow(_('Endpoint source'), nativeEndpointMode, _('Auto uses numeric endpoint returned by Cloudflare registration.')),
			makeRow(_('Minimum registration interval'), nativeInterval, _('Seconds between registration batches; failures use additional backoff.')),
			makeRow(_('Custom / Fallback Endpoint Pool'), nativeEndpoints, _('Optional host:port entries. Never treated as official Cloudflare endpoints; each must pass isolated health checks.'))
		]);

		this.nativeSettingsNode = E('div', [
			makeRow(_('Profile batch size'), batchSizeInput, _('Number of independent profiles registered and tested per batch (1..10, default 5).')),
			makeRow(_('Endpoint source'), nativeEndpointMode, _('Auto uses numeric endpoint returned by Cloudflare registration API.')),
			nativeAdvancedToggle,
			nativeAdvancedSection
		]);
		this.setWarpAutoSettings({});

		return this.renderWarpTabs([
			{
				id: 'overview',
				title: _('Overview'),
				content: [
					E('p', [ _('Runtime state, active connection details, and profile pool.') ]),
					this.autoRuntimeNode,
					E('h3', [ _('Profile Pool') ]),
					this.autoPoolNode,
					E('div', { 'class': 'cbi-page-actions', 'style': 'margin-top:16px;' }, [
						generateButton, ' ', testButton, ' ', cleanButton
					])
				]
			},
			{
				id: 'settings',
				title: _('Settings'),
				content: [
					E('h2', [ _('WARP Auto Settings') ]),

					// QUICK START MOVED TO TOP BEFORE CONFIGURATION SECTIONS
					E('div', {
						'class': 'cbi-section',
						'style': 'background-color:var(--background-color-low); border:1px solid var(--border-color-medium); border-left:4px solid var(--primary-color-medium, #0069d6); border-radius:4px; padding:12px 16px; margin-bottom:18px;'
					}, [
						E('h3', { 'style': 'margin:0 0 6px 0;' }, [ _('Quick Start') ]),
						E('p', { 'style': 'margin:0 0 10px 0; color:var(--text-color-medium); font-size:13px;' }, [
							_('Create and configure a dedicated WARP interface using tested profiles from the pool. Existing interfaces remain untouched.'),
							' ',
							E('a', {
								'href': '#',
								'style': 'font-weight:bold; margin-left:6px;',
								'click': L.bind(function(ev) {
									ev.preventDefault();
									this.switchWarpTab('amneziawg');
								}, this)
							}, [ _('View AmneziaWG Status →') ])
						]),
						E('div', [ bootstrapButton ])
					]),

					// SECTION 1: GENERAL
					E('div', { 'class': 'cbi-section', 'style': 'border:1px solid var(--border-color-medium); border-radius:4px; padding:12px 16px; margin-bottom:16px;' }, [
						E('h3', { 'style': 'margin-top:0; border-bottom:1px solid var(--border-color-low); padding-bottom:6px;' }, [ _('1. General Settings') ]),
						makeRow(_('Target AmneziaWG interface'), target, _('Choose AmneziaWG interface managed by WARP Auto service.')),
						makeRow(_('Enable WARP Auto'), enabled),
						makeRow(_('Provider'), provider),
						makeRow(_('AWG Protocol Version'), awgVersion, _('Obfuscation protocol version for generated WARP configurations.'))
					]),

					// SECTION 2: PROVIDER CONFIGURATION
					E('div', { 'class': 'cbi-section', 'style': 'border:1px solid var(--border-color-medium); border-radius:4px; padding:12px 16px; margin-bottom:16px;' }, [
						E('h3', { 'style': 'margin-top:0; border-bottom:1px solid var(--border-color-low); padding-bottom:6px;' }, [ _('2. Provider Configuration') ]),
						this.remoteSettingsNode,
						this.nativeSettingsNode
					]),

					// SECTION 3: POOL & FAILOVER
					E('div', { 'class': 'cbi-section', 'style': 'border:1px solid var(--border-color-medium); border-radius:4px; padding:12px 16px; margin-bottom:16px;' }, [
						E('h3', { 'style': 'margin-top:0; border-bottom:1px solid var(--border-color-low); padding-bottom:6px;' }, [ _('3. Pool & Failover Policy') ]),
						makeRow(_('Automatic failover'), failover, _('Only switches from ACTIVE after the configured consecutive failure threshold.')),
						makeRow(_('Failover cooldown'), failoverCooldown, _('Seconds before another automatic switch; default 10.')),
						makeRow(_('Minimum READY profiles'), minimumReady, _('Target count of ready standby profiles (default 2).')),
						makeRow(_('Refresh interval'), refresh, _('Seconds between routine pool checks; default 86400.'))
					]),

					// SECTION 4: HEALTH POLICY & LOGGING
					E('div', { 'class': 'cbi-section', 'style': 'border:1px solid var(--border-color-medium); border-radius:4px; padding:12px 16px; margin-bottom:16px;' }, [
						E('h3', { 'style': 'margin-top:0; border-bottom:1px solid var(--border-color-low); padding-bottom:6px;' }, [ _('4. Health Policy & Diagnostics') ]),
						makeRow(_('Health-check interval'), healthInterval, _('Seconds between runtime health checks; minimum 5; default 60.')),
						makeRow(_('Failure threshold'), failureThreshold, _('Consecutive failed checks to trigger failover; default 3.')),
						makeRow(_('Health-check timeout'), healthTimeout, _('Seconds to wait for health probe response; default 10.')),
						makeRow(_('Verify current Forkop/policy route'), strictHealth, _('Leave off on a bare router. Turn on after selected traffic is routed through Forkop.')),
						makeRow(_('Health-check DNS resolvers'), healthResolvers, _('Space-separated DNS resolvers for isolated candidate and health tests.')),
						makeRow(_('Log level'), logLevel, _('Important events by default. Select Debug only when diagnosing.')),
						makeRow(_('Critical resources'), critical, _('One hostname per line. youtube.com remains the default health target.'))
					]),

					// SAVE SETTINGS FINISHES CONFIGURATION FORM
					E('div', { 'class': 'cbi-page-actions' }, [ saveButton ])
				]
			},
			{
				id: 'amneziawg',
				title: _('AmneziaWG'),
				content: [ this.manualImporterNode, this.statusNode ]
			},
			{
				id: 'logs',
				title: _('Logs'),
				content: [
					E('p', [ _('Event log with structured severity levels and automatic secret redaction.') ]),
					this.autoLogsNode
				]
			}
		]);
	},

	updateImporterInterfaceChoices: function() {
		if (!this.importerInterfaceSelect)
			return;
		var currentVal = this.importerInterfaceSelect.value || this.autoTarget || 'YTwarp';
		var names = [];
		var seen = {};
		if (this.currentIfaces) {
			Object.keys(this.currentIfaces).forEach(function(k) {
				seen[k] = true;
				names.push(k);
			});
		}
		if (Array.isArray(this.autoKnownInterfaces)) {
			this.autoKnownInterfaces.forEach(function(k) {
				if (!seen[k]) {
					seen[k] = true;
					names.push(k);
				}
			});
		}
		if (!names.length)
			names.push('YTwarp');
		dom.content(this.importerInterfaceSelect, names.map(function(name) {
			return E('option', { 'value': name }, [ name ]);
		}));
		if (seen[currentVal])
			this.importerInterfaceSelect.value = currentVal;
		else
			this.importerInterfaceSelect.value = names[0];
	},

	refreshAmneziaInterfaces: function() {
		return callgetAwgInstances().then(L.bind(function(ifaces) {
			this.currentIfaces = ifaces || {};
			this.updateImporterInterfaceChoices();
			dom.content(this.statusNode, this.renderIfaces(ifaces));
		}, this)).catch(L.bind(function(err) {
			dom.content(this.statusNode, E('p', { 'class': 'error' }, [
				_('Unable to load AmneziaWG interfaces: %s').format(err.message || err)
			]));
		}, this));
	},

	handleImport: function(fileInput, button, resultNode, targetIface, validateYoutube) {
		var file = fileInput.files && fileInput.files[0];
		if (!file)
			return Promise.resolve();
		if (file.size > 65536) {
			dom.content(resultNode, E('span', { 'class': 'error' }, [ _('The file is larger than 64 KiB.') ]));
			return Promise.resolve();
		}

		targetIface = targetIface || (this.importerInterfaceSelect && this.importerInterfaceSelect.value) || this.autoTarget || 'YTwarp';
		if (validateYoutube === undefined)
			validateYoutube = this.importerValidateYt ? this.importerValidateYt.checked : true;

		button.disabled = true;
		dom.content(resultNode, E('em', [ _('Validating configuration…') ]));

		return readTextFile(file).then(L.bind(function(configText) {
			return callValidateAwgConfig(configText, file.name).then(L.bind(function(result) {
				if (!result || !result.ok)
					throw new Error(result && result.error || _('Configuration validation failed'));

				var iSummary = (result.i_fields || []).map(function(field) {
					return field.name.toUpperCase() + ' (' + field.length + ' chars)';
				}).join(', ') || _('none');

				var protoStr = result.protocol_variant ? result.protocol_variant.toUpperCase() : 'AWG';

				ui.showModal(_('Apply profile to "%s"').format(targetIface), [
					E('p', [ _('The validated profile will replace configuration on interface "%s". Firewall and other interfaces remain untouched.').format(targetIface) ]),
					ui.itemlist(E([]), [
						_('Target Interface'), targetIface,
						_('Protocol Format'), protoStr,
						_('Profile'), result.profile,
						_('Addresses'), (result.addresses || []).join(', '),
						_('Endpoint'), result.endpoint,
						_('Junk packets'), iSummary,
						_('Verify YouTube'), validateYoutube ? _('Yes (active test)') : _('No (skip YouTube test)')
					]),
					E('div', { 'class': 'right' }, [
						E('button', {
							'class': 'btn',
							'click': ui.hideModal
						}, [ _('Cancel') ]),
						' ',
						E('button', {
							'class': 'btn cbi-button cbi-button-positive important',
							'click': L.bind(function(ev) {
								ev.currentTarget.disabled = true;
								dom.content(ev.currentTarget, [ _('Applying and testing…') ]);
								return callImportAwgConfig(configText, file.name, targetIface, validateYoutube ? '1' : '0').then(L.bind(function(applied) {
									ui.hideModal();
									if (!applied || !applied.ok)
										throw new Error(applied && applied.error || _('Import failed'));
									dom.content(resultNode, E('span', { 'style': 'color:green' }, [
										_('Applied to %s: %s (%s)').format(targetIface, applied.profile, applied.endpoint)
									]));
									fileInput.value = '';
									this.showNotification(_('Configuration applied successfully to %s!').format(targetIface), 'info');
									return this.refreshAmneziaInterfaces();
								}, this)).catch(function(err) {
									ui.hideModal();
									throw err;
								});
							}, this)
						}, [ _('Apply to interface %s').format(targetIface) ])
					])
				]);
			}, this));
		}, this)).catch(L.bind(function(err) {
			dom.content(resultNode, E('span', { 'class': 'error' }, [ err.message ]));
			this.showNotification(err.message, 'error');
		}, this)).finally(function() {
			button.disabled = !(fileInput.files && fileInput.files.length);
		});
	},

	handleInterfaceImportModal: function(instanceName) {
		var fileInput = E('input', { 'type': 'file', 'accept': '.conf,text/plain' });
		var pasteArea = E('textarea', {
			'class': 'cbi-input-text',
			'style': 'width:100%; height:120px; font-family:monospace; font-size:12px; margin-top:6px;',
			'placeholder': _('Or paste configuration (.conf) contents here...')
		});
		var isWarpTarget = (instanceName === (this.autoTarget || 'YTwarp'));
		var ytCheck = E('input', { 'type': 'checkbox', 'id': 'modal_import_yt', 'class': 'cbi-input-checkbox', 'checked': isWarpTarget });
		var errorNode = E('p', { 'class': 'error', 'style': 'margin-top:8px;' });

		ui.showModal(_('Import Config to "%s"').format(instanceName), [
			E('p', [ _('Select a file or paste configuration to apply to AmneziaWG interface "%s":').format(instanceName) ]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Upload .conf') ]),
				E('div', { 'class': 'cbi-value-field' }, [ fileInput ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Paste text') ]),
				E('div', { 'class': 'cbi-value-field' }, [ pasteArea ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Verify YouTube') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					ytCheck, ' ',
					E('label', { 'for': 'modal_import_yt' }, [ _('Validate YouTube reachability after applying') ])
				])
			]),
			errorNode,
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-positive',
					'click': L.bind(function(ev) {
						var applyBtn = ev.currentTarget;
						var textPromise = (fileInput.files && fileInput.files[0]) ?
							readTextFile(fileInput.files[0]) :
							Promise.resolve(pasteArea.value);

						applyBtn.disabled = true;
						dom.content(applyBtn, [ _('Applying…') ]);

						textPromise.then(L.bind(function(configText) {
							if (!configText || !configText.trim())
								throw new Error(_('Please choose a file or paste config contents.'));

							var filename = (fileInput.files && fileInput.files[0]) ? fileInput.files[0].name : (instanceName + '.conf');
							return callImportAwgConfig(configText, filename, instanceName, ytCheck.checked ? '1' : '0');
						}, this)).then(L.bind(function(applied) {
							ui.hideModal();
							if (!applied || !applied.ok)
								throw new Error(applied && applied.error || _('Import failed'));
							this.showNotification(_('Configuration applied successfully to %s!').format(instanceName), 'info');
							return this.refreshAmneziaInterfaces();
						}, this)).catch(function(err) {
							applyBtn.disabled = false;
							dom.content(applyBtn, [ _('Apply') ]);
							dom.content(errorNode, [ err.message || err ]);
						});
					}, this)
				}, [ _('Apply') ])
			])
		]);
	},

	handleAddInterfaceModal: function() {
		var nameInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'placeholder': 'awg1',
			'pattern': '[A-Za-z][A-Za-z0-9_]{0,14}',
			'title': _('Letters, digits and underscore; 15 characters maximum')
		});
		var zoneSelect = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'wan' }, [ 'wan (' + _('Default outbound zone') + ')' ]),
			E('option', { 'value': 'vpn' }, [ 'vpn (' + _('VPN / routing zone') + ')' ]),
			E('option', { 'value': '' }, [ _('None (do not assign to firewall zone)') ])
		]);
		var fileInput = E('input', { 'type': 'file', 'accept': '.conf,text/plain' });
		var pasteArea = E('textarea', {
			'class': 'cbi-input-text',
			'style': 'width:100%; height:100px; font-family:monospace; font-size:12px; margin-top:4px;',
			'placeholder': _('Optional: paste .conf here, or leave empty to configure later')
		});
		var errorNode = E('p', { 'class': 'error', 'style': 'margin-top:8px;' });

		ui.showModal(_('Add AmneziaWG Interface'), [
			E('p', [ _('Create a new AmneziaWG network interface and optionally assign it to a firewall zone or populate it with a .conf profile.') ]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Interface Name') ]),
				E('div', { 'class': 'cbi-value-field' }, [ nameInput ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Firewall Zone') ]),
				E('div', { 'class': 'cbi-value-field' }, [ zoneSelect ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Config file (optional)') ]),
				E('div', { 'class': 'cbi-value-field' }, [ fileInput ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Paste Config (optional)') ]),
				E('div', { 'class': 'cbi-value-field' }, [ pasteArea ])
			]),
			errorNode,
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-positive',
					'click': L.bind(function(ev) {
						var submitBtn = ev.currentTarget;
						var name = nameInput.value.trim();
						if (!/^[A-Za-z][A-Za-z0-9_]{0,14}$/.test(name)) {
							dom.content(errorNode, [ _('Invalid interface name. Use 1-15 letters, numbers or underscore.') ]);
							return;
						}

						submitBtn.disabled = true;
						dom.content(submitBtn, [ _('Creating…') ]);

						var configPromise = (fileInput.files && fileInput.files[0]) ?
							readTextFile(fileInput.files[0]) :
							Promise.resolve(pasteArea.value.trim() || null);

						configPromise.then(L.bind(function(confText) {
							return callCreateInterface(name, zoneSelect.value, confText);
						}, this)).then(L.bind(function(res) {
							ui.hideModal();
							if (!res || !res.ok)
								throw new Error(res && res.error || _('Failed to create interface'));
							this.showNotification(_('AmneziaWG interface "%s" created successfully!').format(name), 'info');
							return this.refreshAmneziaInterfaces();
						}, this)).catch(function(err) {
							submitBtn.disabled = false;
							dom.content(submitBtn, [ _('Create') ]);
							dom.content(errorNode, [ err.message || err ]);
						});
					}, this)
				}, [ _('Create Interface') ])
			])
		]);
	},

	handleRestartInterface: function(instanceName) {
		this.showNotification(_('Restarting interface %s…').format(instanceName), 'info');
		return callRestartInterface(instanceName).then(L.bind(function(res) {
			if (!res || !res.ok)
				throw new Error(res && res.error || _('Restart failed'));
			this.showNotification(_('Interface %s restarted successfully!').format(instanceName), 'info');
			return this.refreshAmneziaInterfaces();
		}, this)).catch(L.bind(function(err) {
			this.showNotification(err.message || err, 'error');
		}, this));
	},

	handleDeleteInterface: function(instanceName) {
		var warnAuto = (instanceName === (this.autoTarget || 'YTwarp')) ?
			E('p', { 'class': 'alert-message warning' }, [ _('Warning: This interface is currently configured as the target interface for WARP Auto!') ]) : '';

		ui.showModal(_('Delete Interface "%s"').format(instanceName), [
			E('p', [ _('Are you sure you want to delete AmneziaWG interface "%s"? This will remove it from network and firewall configuration.').format(instanceName) ]),
			warnAuto,
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'click': L.bind(function(ev) {
						ev.currentTarget.disabled = true;
						return callDeleteInterface(instanceName).then(L.bind(function(res) {
							ui.hideModal();
							if (!res || !res.ok)
								throw new Error(res && res.error || _('Delete failed'));
							this.showNotification(_('Interface %s deleted successfully!').format(instanceName), 'info');
							return this.refreshAmneziaInterfaces();
						}, this)).catch(function(err) {
							ui.hideModal();
							ui.addNotification(null, E('p', [ err.message || err ]), 'error');
						});
					}, this)
				}, [ _('Delete Interface') ])
			])
		]);
	},

	renderImporter: function() {
		var input = E('input', {
			'type': 'file',
			'accept': '.conf,text/plain'
		});
		var result = E('span', { 'style': 'margin-left:1em' });
		var ifaceSelect = E('select', { 'class': 'cbi-input-select', 'style': 'margin-right:8px;' });
		this.importerInterfaceSelect = ifaceSelect;
		this.updateImporterInterfaceChoices();

		var validateYtCheck = E('input', { 'type': 'checkbox', 'id': 'importer_val_yt', 'class': 'cbi-input-checkbox', 'checked': true });
		this.importerValidateYt = validateYtCheck;

		var button = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'disabled': true,
			'click': L.bind(function(ev) {
				ev.preventDefault();
				return this.handleImport(input, button, result, ifaceSelect.value, validateYtCheck.checked);
			}, this)
		}, [ _('Validate and apply') ]);

		input.addEventListener('change', function() {
			button.disabled = !(input.files && input.files.length);
			dom.content(result, []);
		});

		return E('div', { 'class': 'cbi-section' }, [
			E('h2', [ _('Import AmneziaWG profile') ]),
			E('p', [
				_('Upload an AmneziaWG or WireGuard .conf file to import into an AmneziaWG interface. Supported formats: WireGuard, AWG 2.0, AWG 3.0, AWG 3.1, and hybrid.')
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Target Interface') ]),
				E('div', { 'class': 'cbi-value-field' }, [ ifaceSelect ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Configuration file') ]),
				E('div', { 'class': 'cbi-value-field' }, [ input, ' ', button, result ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Verify YouTube connectivity') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					validateYtCheck,
					' ',
					E('label', { 'for': 'importer_val_yt' }, [ _('Test YouTube reachability after applying (recommended for WARP configs; uncheck for generic VPNs)') ])
				])
			]),
			E('p', { 'class': 'alert-message info' }, [
				_('Only the selected interface and its peer are updated. DNS is ignored; firewall zone, routing policy, and other interfaces are preserved.')
			])
		]);
	},

	renderIfaces: function(ifaces) {
		var res = [
			E('h2', [ _('AmneziaWG Status') ])
		];

		var ifaceCount = Object.keys(ifaces || {}).length;
		var totalPeers = 0;
		for (var k in ifaces) {
			if (Array.isArray(ifaces[k].peers)) totalPeers += ifaces[k].peers.length;
		}

		var summaryBar = E('div', {
			'style': 'display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; margin-bottom:14px; gap:8px; background-color:var(--background-color-low); padding:8px 12px; border-radius:4px; border:1px solid var(--border-color-medium);'
		}, [
			E('div', [
				E('strong', [ _('Interfaces:') ]), ' ' + ifaceCount + ' · ',
				E('strong', [ _('Total Peers:') ]), ' ' + totalPeers
			]),
			E('div', { 'style': 'display:inline-flex; gap:8px; align-items:center;' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-positive',
					'click': L.bind(this.handleAddInterfaceModal, this)
				}, [ _('+ Add AmneziaWG Interface') ]),
				this.profileDownload('active', _('Download Active WARP Profile (.conf)'))
			])
		]);
		res.push(summaryBar);

		for (var instanceName in ifaces) {
			var iface = ifaces[instanceName];
			var isUp = !!iface.is_up || iface.status === 'up';
			var variant = iface.protocol_variant || iface.variant || 'awg2';
			var variantLabel = 'AmneziaWG 2.0';
			var variantColor = '#6f42c1';
			if (variant === 'wireguard') {
				variantLabel = 'WireGuard';
				variantColor = '#007bff';
			} else if (variant === 'awg3_hybrid') {
				variantLabel = 'AWG 3.0 + 3.1';
				variantColor = '#e83e8c';
			} else if (variant === 'awg3_1') {
				variantLabel = 'AWG 3.1';
				variantColor = '#fd7e14';
			} else if (variant === 'awg3_0') {
				variantLabel = 'AWG 3.0';
				variantColor = '#20c997';
			}

			var statusBadge = isUp ?
				E('span', { 'class': 'badge', 'style': 'background:#28a745; color:#fff; font-size:11px; font-weight:bold; padding:2px 7px; border-radius:3px; margin-left:6px;' }, [ 'UP' ]) :
				E('span', { 'class': 'badge', 'style': 'background:#6c757d; color:#fff; font-size:11px; font-weight:bold; padding:2px 7px; border-radius:3px; margin-left:6px;' }, [ 'DOWN' ]);

			var protoBadge = E('span', { 'class': 'badge', 'style': 'background:' + variantColor + '; color:#fff; font-size:11px; font-weight:600; padding:2px 7px; border-radius:3px; margin-left:6px;' }, [ variantLabel ]);

			var zoneBadge = iface.zone ? E('span', { 'class': 'badge', 'style': 'background:#17a2b8; color:#fff; font-size:11px; padding:2px 6px; border-radius:3px; margin-left:6px;' }, [ _('Zone: ') + iface.zone ]) : '';

			var actionsToolbar = E('div', { 'style': 'display:inline-flex; gap:6px; margin-left:auto; align-items:center;' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'style': 'padding:2px 8px; font-size:12px;',
					'title': _('Import .conf into this interface'),
					'click': L.bind(this.handleInterfaceImportModal, this, instanceName)
				}, [ _('Import Config') ]),
				this.interfaceDownload(instanceName, _('Download .conf')),
				E('button', {
					'class': 'btn cbi-button cbi-button-neutral',
					'style': 'padding:2px 8px; font-size:12px;',
					'title': _('Restart interface'),
					'click': L.bind(this.handleRestartInterface, this, instanceName)
				}, [ _('Restart') ]),
				E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'style': 'padding:2px 8px; font-size:12px;',
					'title': _('Delete interface'),
					'click': L.bind(this.handleDeleteInterface, this, instanceName)
				}, [ _('Delete') ])
			]);

			var headerLine = E('div', { 'style': 'display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:8px; margin-bottom:10px;' }, [
				E('span', {
					'style': 'cursor:pointer; display:inline-flex; align-items:center;',
					'click': ui.createHandlerFn(this, handleInterfaceDetails, iface)
				}, [
					E('span', { 'class': 'ifacebadge' }, [
						E('img', { 'src': L.resource('icons', 'amneziawg.svg') }),
						'\xa0',
						instanceName
					]),
					statusBadge,
					protoBadge,
					zoneBadge,
					E('span', { 'style': 'opacity:.8; margin-left:8px; font-size:12px;' }, [
						iface.listen_port ? _('Port %d').format(iface.listen_port) : '',
						iface.public_key ? ' · ' : '',
						iface.public_key ? E('code', {}, [ iface.public_key ]) : ''
					])
				]),
				actionsToolbar
			]);

			res.push(
				E('div', { 'class': 'cbi-section', 'style': 'border:1px solid var(--border-color-medium); border-radius:4px; padding:12px; margin-bottom:16px;' }, [
					headerLine,
					renderPeerTable(instanceName, iface.peers || [])
				])
			);
		}

		if (res.length == 2 && ifaceCount == 0)
			res.push(E('p', { 'class': 'center', 'style': 'margin-top:3em' }, [
				E('em', [ _('No AmneziaWG interfaces configured.') ])
			]));

		return E([], res);
	},

	render: function() {
		this.statusNode = E('div', [
			E('h2', [ _('AmneziaWG Status') ]),
			E('p', { 'class': 'center', 'style': 'margin-top:5em' }, [
				E('em', [ _('Loading data…') ])
			])
		]);
		this.manualImporterNode = this.renderImporter();
		this.warpAutoNode = this.renderWarpAuto();
		this.updateWarpAuto();
		this.refreshAmneziaInterfaces();

		poll.add(L.bind(function () {
			return this.refreshAmneziaInterfaces();
		}, this), 5);

		poll.add(L.bind(function() {
			return this.updateWarpAuto();
		}, this), 5);

		return this.warpAutoNode;
	},

	handleReset: null,
	handleSaveApply: null,
	handleSave: null
});

'use strict';
'require view';
'require rpc';
'require poll';
'require dom';
'require ui';


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
	params: [ 'config', 'filename' ]
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

function timestampToStr(timestamp) {
	if (timestamp < 1)
		return _('Never', 'No AmneziaWG peer handshake yet');

	var seconds = (Date.now() / 1000) - timestamp;
	var ago;

	if (seconds < 60)
		ago = _('%ds ago').format(seconds);
	else if (seconds < 3600)
		ago = _('%dm ago').format(seconds / 60);
	else if (seconds < 86401)
		ago = _('%dh ago').format(seconds / 3600);
	else
		ago = _('over a day ago');

	return (new Date(timestamp * 1000)).toUTCString() + ' (' + ago + ')';
}

function handleInterfaceDetails(iface) {
	ui.showModal(_('Instance Details'), [
		ui.itemlist(E([]), [
			_('Name'), iface.name,
			_('Public Key'), E('code', [ iface.public_key ]),
			_('Listen Port'), iface.listen_port,
			_('Firewall Mark'), iface.fwmark != 'off' ? iface.fwmark : E('em', _('none'))
		]),
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

	t.update(peers.map(function(peer) {
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
	showWarpAutoMessage: function(message, isError) {
		if (!this.autoMessageNode)
			return;

		dom.content(this.autoMessageNode, message ? E('span', {
			'class': isError ? 'error' : 'success'
		}, [ message ]) : []);
	},

	switchWarpTab: function(name) {
		Object.keys(this.warpTabs || {}).forEach(L.bind(function(key) {
			var tab = this.warpTabs[key];
			var active = key == name;

			tab.panel.style.display = active ? '' : 'none';
			tab.item.classList.toggle('cbi-tab', active);
			tab.link.style.color = active ? '#2ea3d3' : '#c5c5c5';
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
			var item = E('li', { 'class': index ? '' : 'cbi-tab' });
			var link = E('a', {
				'href': '#',
				'style': 'color:' + (index ? '#c5c5c5' : '#2ea3d3'),
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
			interface: String(fields.interface_new.value || '').trim() || fields.interface.value,
			provider: fields.provider.value,
			native_sni: fields.native_sni.value.trim() || 'w3.org',
			native_quic_mode: fields.native_quic_mode.value,
			native_endpoint_mode: fields.native_endpoint_mode.value,
			native_batch_limit: Math.floor(numberValue(fields.native_batch_limit.value, 2)),
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
			critical_resource: resources
		};
	},

	setWarpAutoSettings: function(settings) {
		var fields = this.autoFields;
		var resources;

		if (!fields)
			return;

		settings = settings || {};
		this.setWarpAutoInterfaceChoices(this.autoKnownInterfaces || [], settings.interface || 'awg_warp');
		fields.interface_new.value = '';
		resources = settings.critical_resource || settings.critical_resources || [ 'youtube.com' ];
		if (!Array.isArray(resources))
			resources = String(resources).split(/[\r\n,]+/);

		fields.enabled.checked = boolValue(settings.enabled);
		fields.provider.value = settings.provider || 'remote';
		fields.native_sni.value = settings.native_sni || 'w3.org';
		fields.native_quic_mode.value = settings.native_quic_mode || 'fallback';
		fields.native_endpoint_mode.value = settings.native_endpoint_mode || 'auto';
		fields.native_batch_limit.value = numberValue(settings.native_batch_limit, 2);
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
		selected = String(selected || 'awg_warp');
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
		var service = runtime.service || runtime.state || (runtime.up === true ? _('running') : runtime.running === true ? _('running') : runtime.running === false ? _('stopped') : '-');
		var active = runtime.active_id || runtime.active || state.active_id || state.active || '-';
		var interfaceState = runtime.interface_state || 'unknown';
		var bootstrapState = runtime.bootstrap_state || '-';
		var bootstrapError = runtime.bootstrap_error || '';
		var health = runtime.health || runtime.last_health || state.health || '-';
		var failures = runtime.consecutive_failures;
		var refreshed = runtime.last_refresh || state.last_refresh;
		var lastHealth = runtime.last_health || state.last_health;

		if (service && typeof service == 'object')
			service = service.status || service.state || '-';
		if (health && typeof health == 'object')
			health = health.status || health.result || '-';
		if (failures == null)
			failures = state.consecutive_failures;
		this.autoInterfaceState = interfaceState;
		if (this.autoBootstrapButton)
			this.autoBootstrapButton.disabled = this.autoBusy || interfaceState != 'missing' || bootstrapState == 'running';
		interfaceState = {
			missing: _('not created'),
			partial: _('incomplete configuration'),
			present: _('created')
		}[interfaceState] || interfaceState;
		bootstrapState = {
			running: _('running'),
			ready: _('completed'),
			failed: _('failed')
		}[bootstrapState] || bootstrapState;
		if (bootstrapError)
			bootstrapState += ': ' + bootstrapError.replace(/_/g, ' ');

		dom.content(this.autoRuntimeNode, ui.itemlist(E([]), [
			_('Service'), String(service || '-'),
			_('WARP interface'), String(interfaceState || '-'),
			_('Initial setup'), String(bootstrapState || '-'),
			_('Active profile'), E('span', [ String(active || '-'), ' ', this.profileDownload('active', _('Download active profile')) ]),
			_('Health'), String(health || '-'),
			_('Last health check'), autoTimestampToStr(lastHealth),
			_('Consecutive failures'), failures == null ? '-' : String(failures),
			_('Last refresh'), autoTimestampToStr(refreshed)
		]));
	},

	renderWarpAutoPool: function(state) {
		var pool = this.getWarpAutoPool(state);
		this.autoPoolButtons = [];
		var rows = pool.map(L.bind(function(entry) {
			var id = String(entry.id || entry.fingerprint || entry.name || '-');
			var profile = entry.profile || entry.name || id;
			var status = String(entry.status || entry.state || '-').toUpperCase();
			var endpoint = entry.endpoint || '-';
			var lastTest = autoTimestampToStr(entry.last_test || entry.tested_at);
			var latency = entry.latency_ms == null ? '-' : String(entry.latency_ms) + ' ms';
			var failures = entry.failure_count == null ? '0' : String(entry.failure_count);

			var actions = [];
			if (status == 'READY' || status == 'FAILED') {
				var action = status == 'READY' ? 'activate' : 'retest';
				var button = E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': L.bind(function(event) {
						event.preventDefault();
						return this.runWarpAutoAction(action, id);
					}, this)
				}, [ status == 'READY' ? _('Activate') : _('Retest') ]);
				button.disabled = !!this.autoBusy;
				this.autoPoolButtons.push(button);
				actions.push(button, ' ');
			}
			actions.push(this.profileDownload(id));

			return E('tr', [
				E('td', [ String(profile) ]),
				E('td', [ status ]),
				E('td', [ String(endpoint) ]),
				E('td', [ lastTest ]),
				E('td', [ latency ]),
				E('td', [ failures ]),
				E('td', { 'style': 'white-space:nowrap' }, actions)
			]);
		}, this));

		if (!rows.length)
			rows.push(E('tr', [ E('td', { 'colspan': 7 }, [ E('em', [ _('No WARP Auto profiles yet.') ]) ]) ]));

		dom.content(this.autoPoolNode, E('table', { 'class': 'table cbi-section-table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, [ _('Profile') ]),
				E('th', { 'class': 'th' }, [ _('State') ]),
				E('th', { 'class': 'th' }, [ _('Endpoint') ]),
				E('th', { 'class': 'th' }, [ _('Last test') ]),
				E('th', { 'class': 'th' }, [ _('Latency') ]),
				E('th', { 'class': 'th' }, [ _('Failures') ]),
				E('th', { 'class': 'th' }, [ _('Actions') ])
			])
		].concat(rows)));

	},

	renderWarpAutoLogs: function(state) {
		var logs = state.logs || state.recent_logs || [];
		var lines;

		if (typeof logs == 'string')
			lines = logs.split(/\r?\n/);
		else if (Array.isArray(logs))
			lines = logs.map(function(entry) {
				if (entry && typeof entry == 'object') {
					var prefix = entry.timestamp || entry.time || '';
					var level = entry.level ? ' ' + entry.level : '';
					return (prefix ? autoTimestampToStr(prefix) : '') + level + ' ' + (entry.message || entry.text || '');
				}
				return String(entry);
			});
		else
			lines = [];

		lines = lines.slice(-50).map(redactAutoLog).filter(function(line) { return line.length; });
		dom.content(this.autoLogsNode, E('pre', {
			'style': 'max-height:14em; overflow:auto; white-space:pre-wrap'
		}, [ lines.join('\n') || _('No recent WARP Auto events.') ]));
	},

	updateWarpAuto: function() {
		return callGetWarpAutoStatus().then(L.bind(function(state) {
			state = state || {};
			if (state.ok === false)
				throw new Error(state.error || _('Unable to read WARP Auto status'));

			this.autoKnownInterfaces = (state.runtime && state.runtime.available_interfaces) || [];
			if (!this.autoSettingsLoaded || !this.autoSettingsDirty)
				this.setWarpAutoSettings(state.settings);
			this.autoSettingsLoaded = true;
			this.renderWarpAutoRuntime(state);
			this.renderWarpAutoPool(state);
			this.renderWarpAutoLogs(state);
		}, this)).catch(L.bind(function(error) {
			this.showWarpAutoMessage(error.message || _('Unable to read WARP Auto status'), true);
		}, this));
	},

	saveWarpAutoSettings: function() {
		var settings = this.getWarpAutoSettings();

		this.setWarpAutoBusy(true);
		this.showWarpAutoMessage(_('Saving WARP Auto settings…'));

		return callSaveWarpAutoSettings(settings, '0').then(L.bind(function(result) {
			if (!result || result.ok === false)
				throw new Error(result && result.error || _('Unable to save WARP Auto settings'));

			this.autoSettingsDirty = false;
			this.showWarpAutoMessage(result.message || _('WARP Auto settings saved.'));
			return this.updateWarpAuto();
		}, this)).catch(L.bind(function(error) {
			this.showWarpAutoMessage(error.message || _('Unable to save WARP Auto settings'), true);
			ui.addNotification(null, E('p', [ error.message || _('Unable to save WARP Auto settings') ]), 'error');
		}, this)).then(L.bind(function(result) {
			this.setWarpAutoBusy(false);
			return result;
		}, this));
	},

	runWarpAutoAction: function(action, profileId) {
		/* RPC declares id as a string. Send an empty string for actions that
		 * do not target a pool entry, otherwise ubus rejects the request before
		 * the backend can dispatch refresh/test_all/rollback. */
		var id = profileId || '';
		var actionNames = {
			refresh: _('Refreshing configurations…'),
			test_all: _('Testing configurations…'),
			activate: _('Activating selected profile…'),
			retest: _('Retesting profile…'),
			native_test: _('Generating and testing Native profile…'),
			rollback: _('Rolling back profile…'),
			bootstrap: _('Creating and testing WARP interface…')
		};

		if (action == 'activate' && !id) {
			this.showWarpAutoMessage(_('Select a READY profile first.'), true);
			return Promise.resolve();
		}

		this.setWarpAutoBusy(true);
		this.showWarpAutoMessage(actionNames[action] || _('Running WARP Auto action…'));

		var request = action == 'bootstrap' || action == 'native_test'
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
			ui.addNotification(null, E('p', [ error.message || _('WARP Auto action failed') ]), 'error');
		}, this)).then(L.bind(function(result) {
			this.setWarpAutoBusy(false);
			return result;
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
		var targetNew = makeInput('interface_new', 'text', {
			'placeholder': _('new interface name'),
			'pattern': '[A-Za-z][A-Za-z0-9_]{0,14}',
			'title': _('Letters, digits and underscore; 15 characters maximum')
		});
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
		var nativeSni = makeInput('native_sni', 'text', { 'placeholder': 'w3.org', 'maxlength': 253 });
		var nativeQuicMode = E('select', { 'class': 'cbi-input-select', 'name': 'native_quic_mode' }, [
			E('option', { 'value': 'fallback' }, [ _('Compatibility preset') ]),
			E('option', { 'value': 'dynamic' }, [ _('Dynamic local SNI I1 (optional helper)') ])
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
		var nativeBatch = makeInput('native_batch_limit', 'number', { 'min': 1, 'max': 2, 'step': 1 });
		var nativeInterval = makeInput('native_min_interval', 'number', { 'min': 60, 'step': 1 });
		var nativeEndpoints = E('textarea', { 'rows': 4, 'class': 'cbi-input-text', 'style': 'width:100%; max-width:40em' });
		fields.native_endpoints = nativeEndpoints;
		nativeEndpoints.addEventListener('input', dirty);
		var refresh = makeInput('refresh_interval', 'number', { 'min': 60, 'step': 1 });
		var minimumReady = makeInput('minimum_ready', 'number', { 'min': 0, 'step': 1 });
		var healthInterval = makeInput('health_interval', 'number', { 'min': 5, 'step': 1 });
		var failureThreshold = makeInput('failure_threshold', 'number', { 'min': 1, 'step': 1 });
		var healthTimeout = makeInput('health_timeout', 'number', { 'min': 1, 'step': 1 });
		var strictHealth = makeInput('health_mode', 'checkbox', { 'class': 'cbi-input-checkbox' });
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
		}, [ _('Save settings') ]);
		var refreshButton = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': L.bind(function(event) {
				event.preventDefault();
				return this.runWarpAutoAction('refresh');
			}, this)
		}, [ _('Refresh configs') ]);
		var testButton = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': L.bind(function(event) {
				event.preventDefault();
				return this.runWarpAutoAction('test_all');
			}, this)
		}, [ _('Test all') ]);
		var generateButton = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': L.bind(function(event) {
				event.preventDefault();
				return this.runWarpAutoAction('native_test');
			}, this)
		}, [ _('Generate test profile') ]);
		var rollbackButton = E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'click': L.bind(function(event) {
				event.preventDefault();
				return this.runWarpAutoAction('rollback');
			}, this)
		}, [ _('Rollback') ]);
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
		this.autoActionButtons = [ bootstrapButton, refreshButton, testButton, generateButton, rollbackButton ];
		this.autoMessageNode = E('span', { 'style': 'margin-left:1em' });
		this.autoRuntimeNode = E('div', [ E('em', [ _('Loading WARP Auto status…') ]) ]);
		this.autoPoolNode = E('div', [ E('em', [ _('Loading WARP Auto pool…') ]) ]);
		this.autoLogsNode = E('div', [ E('em', [ _('Loading WARP Auto logs…') ]) ]);
		this.autoSettingsLoaded = false;
		this.autoSettingsDirty = false;
		this.autoBusy = false;
		this.remoteSettingsNode = E('div', [ makeRow(_('Config source URL'), source, _('Default: %s. Change this for a mirror or compatible source.').format(DEFAULT_WARP_SOURCE_URL)) ]);
		this.nativeSettingsNode = E('div', [
			makeRow(_('QUIC SNI'), nativeSni, _('Used only by Dynamic local SNI I1.')),
			makeRow(_('QUIC mode'), nativeQuicMode, _('Compatibility preset remains active until optional quic-i1 helper is installed.')),
			makeRow(_('Endpoint source'), nativeEndpointMode, _('Auto uses endpoint returned by Cloudflare registration.')),
			makeRow(_('Registration batch limit'), nativeBatch, _('Maximum new registrations per replenishment batch.')),
			makeRow(_('Minimum registration interval'), nativeInterval, _('Seconds between registration batches; failures use additional backoff.')),
			makeRow(_('Custom / Fallback Endpoint Pool'), nativeEndpoints, _('Optional host:port entries. Never treated as official Cloudflare endpoints; each must pass isolated health checks.')),
			E('div', { 'class': 'cbi-page-actions' }, [ generateButton ])
		]);
		this.setWarpAutoSettings({});

		return this.renderWarpTabs([
			{
				id: 'overview',
				title: _('Overview'),
				content: [
					E('p', [ _('Runtime state and tested WARP profile pool.') ]),
					E('h3', [ _('Runtime status') ]),
					this.autoRuntimeNode,
					E('h3', [ _('Profile pool') ]),
					this.autoPoolNode,
					E('div', { 'class': 'cbi-page-actions' }, [ refreshButton, ' ', testButton, ' ', rollbackButton ])
				]
			},
			{
				id: 'settings',
				title: _('Settings'),
				content: [
					E('h2', [ _('WARP Auto settings') ]),
					makeRow(_('Target AmneziaWG interface'), E('div', [
						target,
						' ',
						targetNew
					]), _('Choose existing interface, or enter a new name. Save before importing or using pool actions.')),
					makeRow(_('Enable WARP Auto'), enabled),
					makeRow(_('Automatic failover'), failover, _('Only switches from ACTIVE after the configured consecutive failure threshold.')),
					makeRow(_('Failover cooldown'), failoverCooldown, _('Seconds before another automatic switch; default 10.')),
					makeRow(_('Provider'), provider),
					this.remoteSettingsNode,
					this.nativeSettingsNode,
					makeRow(_('Refresh interval'), refresh, _('seconds; default 86400')),
					makeRow(_('Minimum READY profiles'), minimumReady, _('default 2')),
					makeRow(_('Health-check interval'), healthInterval, _('seconds; minimum 5; default 60')),
					makeRow(_('Failure threshold'), failureThreshold, _('consecutive failed checks; default 3')),
					makeRow(_('Health-check timeout'), healthTimeout, _('seconds; default 10')),
					makeRow(_('Verify current Forkop/policy route'), strictHealth, _('Leave off on a bare router. Turn on after selected traffic is routed through Forkop.')),
					makeRow(_('Log level'), logLevel, _('Important events by default. Select Debug only when diagnosing.')),
					makeRow(_('Critical resources'), critical, _('One hostname per line. youtube.com remains the default health target.')),
					E('div', { 'class': 'cbi-page-actions' }, [ saveButton ]),
					E('h3', [ _('Quick Start') ]),
					E('div', { 'class': 'cbi-page-actions' }, [ bootstrapButton, ' ', E('span', [ _('Creates the selected missing interface using a tested profile. Existing interfaces are preserved.') ]) ])
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
					E('p', [ _('Event log. Stable health checks are quiet at Info; select Debug to show each successful check.') ]),
					this.autoLogsNode
				]
			}
		]);
	},

	handleImport: function(fileInput, button, resultNode) {
		var file = fileInput.files && fileInput.files[0];
		if (!file)
			return Promise.resolve();
		if (file.size > 65536) {
			dom.content(resultNode, E('span', { 'class': 'error' }, [ _('The file is larger than 64 KiB.') ]));
			return Promise.resolve();
		}

		button.disabled = true;
		dom.content(resultNode, E('em', [ _('Validating configuration…') ]));

		return readTextFile(file).then(L.bind(function(configText) {
			return callValidateAwgConfig(configText, file.name).then(L.bind(function(result) {
				if (!result || !result.ok)
					throw new Error(result && result.error || _('Configuration validation failed'));

				var iSummary = (result.i_fields || []).map(function(field) {
					return field.name.toUpperCase() + ' (' + field.length + ' chars)';
				}).join(', ') || _('none');

				ui.showModal(_('Apply AmneziaWG profile'), [
					E('p', [ _('The validated profile will replace selected target interface. Forkop and YT2 will not be restarted or modified.') ]),
					ui.itemlist(E([]), [
						_('Profile'), result.profile,
						_('Addresses'), (result.addresses || []).join(', '),
						_('Endpoint'), result.endpoint,
						_('Junk packets'), iSummary,
						_('Applied settings'), 'ListenPort 51821, fwmark 0x01000000, route_allowed_ips 0',
						_('Ignored settings'), 'DNS, ListenPort from file'
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
								return callImportAwgConfig(configText, file.name).then(L.bind(function(applied) {
									ui.hideModal();
									if (!applied || !applied.ok)
										throw new Error(applied && applied.error || _('Import failed'));
									dom.content(resultNode, E('span', { 'style': 'color:green' }, [
										_('Active profile: %s (%s)').format(applied.profile, applied.endpoint)
									]));
									fileInput.value = '';
									ui.addNotification(null, E('p', [
										_('AmneziaWG profile applied. YouTube health check passed.')
									]), 'info');
									return callgetAwgInstances().then(L.bind(function(ifaces) {
										dom.content(this.statusNode, this.renderIfaces(ifaces));
									}, this));
								}, this)).catch(function(err) {
									ui.hideModal();
									throw err;
								});
							}, this)
						}, [ _('Apply to selected interface') ])
					])
				]);
			}, this));
		}, this)).catch(function(err) {
			dom.content(resultNode, E('span', { 'class': 'error' }, [ err.message ]));
			ui.addNotification(null, E('p', [ err.message ]), 'error');
		}).finally(function() {
			button.disabled = !(fileInput.files && fileInput.files.length);
		});
	},

	renderImporter: function() {
		var input = E('input', {
			'type': 'file',
			'accept': '.conf,text/plain'
		});
		var result = E('span', { 'style': 'margin-left:1em' });
		var button = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'disabled': true,
			'click': L.bind(function(ev) {
				ev.preventDefault();
				return this.handleImport(input, button, result);
			}, this)
		}, [ _('Validate and apply') ]);

		input.addEventListener('change', function() {
			button.disabled = !(input.files && input.files.length);
			dom.content(result, []);
		});

	return E('div', { 'class': 'cbi-section' }, [
			E('h2', [ _('Import AmneziaWG profile') ]),
			E('p', [
				_('Upload an AmneziaWG .conf file to replace selected target interface. The file is processed in memory and is not stored on the router.')
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Configuration file') ]),
				E('div', { 'class': 'cbi-value-field' }, [ input, ' ', button, result ])
			]),
			E('p', { 'class': 'alert-message warning' }, [
				_('Only selected interface and its AmneziaWG peer are replaced. DNS is ignored; Forkop and other interfaces remain untouched.')
			])
		]);
	},

	renderIfaces: function(ifaces) {
		var res = [
			E('h2', [ _('AmneziaWG Status') ])
		];

		for (var instanceName in ifaces) {
			res.push(
				E('h3', [ _('Instance "%h"', 'AmneziaWG instance heading').format(instanceName) ]),
				E('p', {
					'style': 'cursor:pointer',
					'click': ui.createHandlerFn(this, handleInterfaceDetails, ifaces[instanceName])
				}, [
					E('span', { 'class': 'ifacebadge' }, [
						E('img', { 'src': L.resource('icons', 'amneziawg.svg') }),
						'\xa0',
						instanceName
					]),
					E('span', { 'style': 'opacity:.8' }, [
						' · ',
						_('Port %d', 'AmneziaWG listen port').format(ifaces[instanceName].listen_port),
						' · ',
						E('code', { 'click': '' }, [ ifaces[instanceName].public_key ])
					])
				]),
				renderPeerTable(instanceName, ifaces[instanceName].peers)
			);
		}

		if (res.length == 1)
			res.push(E('p', { 'class': 'center', 'style': 'margin-top:5em' }, [
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

		poll.add(L.bind(function () {
			return callgetAwgInstances().then(L.bind(function(ifaces) {
				dom.content(this.statusNode, this.renderIfaces(ifaces));
			}, this));
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

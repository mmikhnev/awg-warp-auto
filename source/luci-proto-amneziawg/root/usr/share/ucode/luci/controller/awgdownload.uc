import * as fs from 'fs';
import { cursor } from 'uci';

function download() {
	const access = ubus.call('session', 'access', {
		ubus_rpc_session: ctx.authsession,
		scope: 'access-group', object: 'luci-proto-amneziawg', function: 'write'
	});
	if (access?.access != true) {
		http.status(403, 'Forbidden');
		return;
	}
	let iface = http.formvalue('interface');
	if (iface) {
		if (type(iface) != 'string' || !match(iface, /^[A-Za-z][A-Za-z0-9_]{0,14}$/)) {
			http.status(400, 'Invalid interface');
			return;
		}
		const res = ubus.call('luci.amneziawg', 'exportInterfaceConfig', { name: iface });
		if (!res || !res.ok || !res.config) {
			http.status(404, 'Interface configuration unavailable');
			return;
		}
		http.header('Cache-Control', 'no-store');
		http.header('X-Content-Type-Options', 'nosniff');
		http.header('Content-Disposition', 'attachment; filename="' + (res.filename || (iface + '.conf')) + '"');
		http.prepare_content('application/octet-stream');
		http.write(res.config);
		return;
	}

	let id = http.formvalue('id');
	if (id == 'active') {
		const uci = cursor();
		uci.load('awg-warp-auto');
		id = uci.get('awg-warp-auto', 'main', 'active_id');
	}
	if (type(id) != 'string' || !match(id, /^p_[0-9a-f]{24}$/)) {
		http.status(400, 'Invalid profile');
		return;
	}
	const path = '/etc/awg-warp-auto/pool/' + id + '.conf';
	const info = fs.lstat(path);
	if (info?.type != 'file' || info.size > 65536) {
		http.status(404, 'Profile unavailable');
		return;
	}
	const data = fs.readfile(path);
	if (data == null) { http.status(404, 'Profile unavailable'); return; }
	http.header('Cache-Control', 'no-store');
	http.header('X-Content-Type-Options', 'nosniff');
	http.header('Content-Disposition', 'attachment; filename="warp-' + id + '.conf"');
	http.prepare_content('application/octet-stream');
	http.write(data);
}

return { download };

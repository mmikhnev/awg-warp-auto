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

'use strict';
import * as fs from 'fs';
import { platform } from '../root/usr/share/wgmanager/platform.uc';
import { manager, fail } from '../root/usr/share/wgmanager/core.uc';

const base = ARGV[0], operation = ARGV[1] ?? 'flow';
const options = json(fs.readfile(base + '/options.json'));
let io = platform(options);
try {
	io.lock();
	let api = manager(io);
	if (operation == 'lock-hold') {
		printf('LOCKED\n'); fs.stdout.flush(); sleep(3000); io.unlock(); exit(0);
	}
	if (operation == 'lock-only') { io.unlock(); printf('LOCKED\n'); exit(0); }
	if (operation == 'status') { let status = api.status(); io.unlock(); printf('%J\n', status); exit(0); }
	let status = api.status();
	if (length(status.peers) != 3 || status.mode != 'monitor') fail('TEST', 'initial status');
	api.enable(true);
	let settings = api.prepare({ action: 'settings', payload: sprintf('%J', {
		endpoint: 'vpn.example.com', dns: ['192.168.95.1'], routes: ['192.168.66.0/24', '192.168.95.0/24'], keepalive: 25 }) }, 'integration');
	api.apply({ token: settings.token }, 'integration');
	let plan = api.prepare({ action: 'create', payload: '{"name":"$(touch /tmp/wgm-injection)"}' }, 'integration');
	let id = api.apply({ token: plan.token }, 'integration').peer_id;
	let secret = api.export_peer({ peer_id: id, qr: true });
	for (let name, content in { 'client.conf': secret.config, 'qr.svg': secret.qr_svg }) {
		let f = fs.open(base + '/' + name, 'wxe', 384); f.write(content); f.close();
	}
	let public_status = api.status();
	let f = fs.open(base + '/public-status.json', 'wxe', 384); f.write(sprintf('%J', public_status)); f.close();
	for (let action in ['disable', 'enable']) {
		let p = api.prepare({ action, peer_id: id, payload: '{}' }, 'integration'); api.apply({ token: p.token }, 'integration');
	}
	let edit = api.prepare({ action: 'edit', peer_id: id, payload: '{"name":"iPhone 测试","address":"192.168.66.8"}' }, 'integration');
	api.apply({ token: edit.token }, 'integration');
	let del = api.prepare({ action: 'delete', peer_id: id, payload: '{}' }, 'integration'); api.apply({ token: del.token }, 'integration');
	io.sample(io.snapshot(), true);
	io.unlock();
	printf('%J\n', { ok: true, final_count: length(api.status().peers), id });
}
catch (e) { io.unlock(); printf('ERROR %J\n', e); exit(1); }

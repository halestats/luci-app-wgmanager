// SPDX-License-Identifier: Apache-2.0
'use strict';
import { manager, VERSION, fail } from './core.uc';
import { platform } from './platform.uc';

let io, command = ARGV[0] ?? 'doctor';
try {
	if (command == '--version') { printf('%s\n', VERSION); exit(0); }
	if (index(['doctor', 'enable-management', 'manage-existing', 'read-only', 'restore', 'recover', 'sample', 'checkpoint', 'collect'], command) < 0)
		fail('INVALID_COMMAND', '支持：doctor、enable-management、manage-existing、read-only、restore、recover、sample、checkpoint、collect');
	io = platform(); io.lock();
	let api = manager(io), result;
	if (command == 'doctor') {
		let status = api.status();
		result = { version: VERSION, mode: status.mode, health: status.health, message: status.message,
			interface: status.interface, up: status.up, listen_port: status.listen_port,
			client_count: length(status.peers), protected_count: length(filter(status.peers, p => p.protected)),
			managed_count: length(filter(status.peers, p => p.managed)),
			legacy_count: length(filter(status.peers, p => p.legacy)),
			drift_count: length(filter(status.peers, p => p.drift)), stats: status.stats,
			dependencies: io.dependency_check(), network_policy: status.existing_management ? 'only_selected_existing_peer_uci_sections_no_firewall_changes' : 'never_write_network_or_firewall' };
	}
	else if (command == 'enable-management') result = api.enable(true);
	else if (command == 'manage-existing') result = api.manage_existing();
	else if (command == 'read-only') result = api.enable(false);
	else if (command == 'restore') result = api.restore();
	else if (command == 'recover') result = api.recover();
	else {
		let ledger = io.sample(io.snapshot(), command == 'checkpoint');
		if (command == 'collect') io.collector_mark();
		result = { sampled: true, last_checkpoint: ledger.last_checkpoint };
	}
	io.unlock();
	printf('%J\n', { ok: true, data: result });
}
catch (e) {
	io?.unlock();
	let pieces = split(e.message ?? '', '|');
	let known = length(pieces) == 2 && match(pieces[0], /^[A-Z_]+$/);
	printf('%J\n', { ok: false, error: { code: known ? pieces[0] : 'INTERNAL_ERROR',
		message: known ? pieces[1] : '内部错误，请保留管理文件并检查依赖' } });
	exit(1);
}

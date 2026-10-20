// SPDX-License-Identifier: Apache-2.0
'use strict';
import { manager, VERSION, fail } from './core.uc';
import { platform } from './platform.uc';

let io, position = 0, selected = '', command;
try {
	if (ARGV[0] == '--interface') {
		if (type(ARGV[1]) != 'string' || ARGV[1] == '') fail('INVALID_INTERFACE', '--interface 后须填写接口名');
		selected = ARGV[1]; position = 2;
	}
	command = ARGV[position] ?? 'doctor';
	if (length(ARGV) > position + 1) fail('INVALID_COMMAND', '接口参数格式：wgmanager --interface 接口名 命令');
	if (command == '--version') { printf('%s\n', VERSION); exit(0); }
	if (index(['interfaces', 'doctor', 'enable-management', 'manage-existing', 'read-only', 'restore', 'recover', 'sample', 'checkpoint', 'collect', 'collect-all', 'checkpoint-all'], command) < 0)
		fail('INVALID_COMMAND', '支持：interfaces、doctor、enable-management、manage-existing、read-only、restore、recover、sample、checkpoint、collect；可前置 --interface 接口名');
	io = platform({ interface: selected });
	let result;
	if (command == 'interfaces') result = { interfaces: io.interfaces };
	else if (command == 'collect-all' || command == 'checkpoint-all') {
		if (selected != '') fail('INVALID_COMMAND', '全接口采样命令不能同时指定 --interface');
		let results = [], failed = false, interfaces = io.interfaces;
		for (let item in interfaces) {
			try {
				io = platform({ interface: item.name }); io.lock();
				let ledger = io.sample(io.snapshot(), command == 'checkpoint-all');
				if (command == 'collect-all') io.collector_mark();
				io.unlock();
				push(results, { interface: item.name, ok: true, last_checkpoint: ledger.last_checkpoint });
			}
			catch (e) {
				io?.unlock(); failed = true;
				let code = split(e.message ?? '', '|')[0];
				push(results, { interface: item.name, ok: false, code: match(code, /^[A-Z_]+$/) ? code : 'INTERNAL_ERROR' });
			}
		}
		printf('%J\n', { ok: !failed, data: { interfaces: results } }); exit(failed ? 1 : 0);
	}
	else {
		if (io.interface == '' && command != 'doctor')
			fail('SELECT_INTERFACE', '存在多个接口，请使用 wgmanager --interface 接口名 命令');
		io.lock();
		let api = manager(io);
		if (command == 'doctor') {
			let status = api.status();
			result = { version: VERSION, mode: status.mode, health: status.health, message: status.message,
				interface: status.interface, interfaces: status.interfaces, selection_required: status.selection_required,
				up: status.up, listen_port: status.listen_port, network: status.network, default_routes: status.default_routes,
				out_of_pool_count: length(filter(status.peers, p => p.out_of_pool)),
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
			result = { interface: io.interface, sampled: true, last_checkpoint: ledger.last_checkpoint };
		}
		io.unlock();
	}
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

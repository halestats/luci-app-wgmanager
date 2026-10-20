// SPDX-License-Identifier: Apache-2.0
'use strict';
import * as fs from 'fs';
import { cursor } from 'uci';
import { fail, key, ipv4, accumulate, options_equal, valid_section, IFACE, PORT } from './core.uc';

function shellquote(value) { return "'" + replace('' + value, "'", "'\\''") + "'"; }

// Test paths can be supplied by an importing test. No RPC/CLI argument or
// environment variable is ever forwarded here in production.
function platform(options) {
	options ??= {};
	const data = options.data_dir ?? '/etc/wgmanager';
	const run = options.runtime_dir ?? '/var/run/wgmanager';
	const conf = options.confdir ?? '/etc/config';
	const wg = options.wg_binary ?? '/usr/bin/wg';
	const ip = options.ip_binary ?? '/sbin/ip';
	const qrencode = options.qr_binary ?? '/usr/bin/qrencode';
	const sync = options.sync_binary ?? '/bin/sync';
	let lock_handle;

	function secure_dir(path) {
		let st = fs.lstat(path);
		if (!st) {
			if (!fs.mkdir(path, 448)) fail('STORAGE_ERROR', '无法创建私有数据目录');
			st = fs.lstat(path);
		}
		if (!st || st.type != 'directory' || st.uid != 0 || (st.mode & 63) != 0)
			fail('UNSAFE_PATH', '数据目录权限不安全，已停止操作');
	}

	function safe_file(path, limit, optional) {
		let st = fs.lstat(path);
		if (!st && optional) return null;
		if (!st || st.type != 'file' || st.uid != 0 || (st.mode & 63) != 0 || st.size > limit)
			fail('UNSAFE_PATH', '管理文件类型、权限或大小不符合要求');
		let f = fs.open(path, 're');
		if (!f) fail('STORAGE_ERROR', '无法读取管理文件');
		let text = f.read(limit + 1);
		f.close();
		if (text == null || length(text) > limit) fail('STORAGE_ERROR', '读取文件失败或文件过大');
		return text;
	}

	function read_json(path, optional) {
		let text = safe_file(path, 1048576, optional);
		if (text == null) return null;
		try { return json(text); }
		catch (e) { fail('INVALID_JSON', '管理数据不是有效 JSON，原文件已保留'); }
	}

	function random_hex(count) {
		let f = fs.open('/dev/urandom', 're');
		let value = f?.read(count);
		f?.close();
		if (length(value) != count) fail('RANDOM_FAILED', '系统随机数读取失败');
		return hexenc(value);
	}

	function private_dir(prefix) {
		// mkdtemp() is absent in the ucode shipped with OpenWrt 24.10.
		// mkdir is atomic; names use 96 bits from the kernel RNG.
		for (let i = 0; i < 4; i++) {
			let path = prefix + random_hex(12);
			if (fs.mkdir(path, 448)) return path;
		}
		fail('TEMP_FAILED', '无法创建私有临时目录');
	}

	function sync_path(path) {
		if (system([sync, '-f', path], 5000) != 0) fail('SYNC_FAILED', '持久化检查失败，停止变更');
	}

	function atomic(path, value, durable) {
		let parent = fs.dirname(path);
		secure_dir(parent);
		// Refuse pre-existing symlinks or non-private files, even on replacement.
		if (fs.lstat(path)) safe_file(path, 1048576, false);
		let tmp = path + '.new-' + random_hex(8), f;
		try {
			f = fs.open(tmp, 'wxe', 384);
			if (!f) fail('STORAGE_ERROR', '无法写入暂存文件');
			let text = sprintf('%J\n', value);
			if (f.write(text) != length(text) || !f.close()) fail('STORAGE_ERROR', '暂存写入失败');
			f = null;
			if (durable) sync_path(tmp);
			if (!fs.rename(tmp, path)) fail('STORAGE_ERROR', '原子保存失败');
			if (durable) sync_path(parent);
		}
		catch (e) {
			f?.close();
			fs.unlink(tmp);
			die(e.message);
		}
	}

	function with_temp(callback) {
		secure_dir(run);
		let dir = private_dir(run + '/secret-');
		if (!dir) fail('TEMP_FAILED', '无法建立私有临时目录');
		let result, problem;
		try { result = callback(dir); } catch (e) { problem = e; }
		for (let name in fs.lsdir(dir) ?? []) fs.unlink(dir + '/' + name);
		fs.rmdir(dir);
		if (problem) die(problem.message);
		return result;
	}

	function secret_file(path, text) {
		let f = fs.open(path, 'wxe', 384);
		if (!f || f.write(text) != length(text) || !f.close()) fail('TEMP_FAILED', '私有暂存文件写入失败');
	}

	function capture(argv, input, limit) {
		return with_temp((dir) => {
			let output = dir + '/out', source = '';
			if (input != null) {
				secret_file(dir + '/in', input);
				source = ' < ' + shellquote(dir + '/in');
			}
			// Every argv item and path is quoted; secret key text is only on stdin.
			let command = join(' ', map(argv, shellquote)) + source +
				' > ' + shellquote(output) + ' 2>/dev/null';
			// The directory is 0700; an explicit umask protects command output too.
			let code = system('umask 077; exec ' + command, 5000);
			if (code != 0) fail('COMMAND_FAILED', '本地 WireGuard 或辅助命令执行失败');
			return safe_file(output, limit ?? 1048576, false);
		});
	}

	function list_value(value) {
		if (type(value) == 'array') return value;
		return type(value) == 'string' && value != '' ? split(value, /[[:space:]]+/) : [];
	}

	function section_options(section) {
		let out = {};
		for (let name in sort(keys(section ?? {}))) if (substr(name, 0, 1) != '.') out[name] = section[name];
		return out;
	}
	function change_uci_peer(old, next, purpose) {
		let reference = next ?? old, section = reference?.uci_section;
		if (reference?.source != 'uci' || !valid_section(section) || (old && next && (old.uci_section != next.uci_section || old.public_key != next.public_key)))
			fail('INVALID_PEER', '既有客户端配置标识无效');
		secure_dir(run);
		let savedir = private_dir(run + '/uci-write-'), ctx;
		try {
			ctx = cursor(conf, savedir);
			if (!ctx.load('network')) fail('UCI_READ_FAILED', '无法读取客户端配置');
			let current = ctx.get_all('network', section);
			if (current && current['.type'] != 'wireguard_' + IFACE) fail('UCI_COLLISION', '目标不是当前接口的客户端配置');
			let actual = current ? section_options(current) : null;
			let from_matches = old ? options_equal(actual, old.uci_options) : actual == null;
			let to_matches = next ? options_equal(actual, next.uci_options) : actual == null;
			if (!from_matches && !(purpose != 'apply' && to_matches)) fail('PEER_DRIFT', '所选客户端配置已被外部修改');
			if (purpose != 'apply' && to_matches) { ctx.unload('network'); }
			else {
				if (!next) { if (current && !ctx.delete('network', section)) fail('UCI_WRITE_FAILED', '删除所选客户端配置失败'); }
				else if (!current) {
					if (!ctx.section('network', 'wireguard_' + IFACE, section, next.uci_options)) fail('UCI_WRITE_FAILED', '恢复所选客户端配置失败');
				}
				else {
					for (let name in keys(actual)) if (!(name in next.uci_options) && !ctx.delete('network', section, name)) fail('UCI_WRITE_FAILED', '更新客户端字段失败');
					for (let name in keys(next.uci_options)) if (!ctx.set('network', section, name, next.uci_options[name])) fail('UCI_WRITE_FAILED', '保存客户端字段失败');
				}
				if (!ctx.save('network') || !ctx.commit('network')) fail('UCI_WRITE_FAILED', '提交所选客户端配置失败');
				ctx.unload('network');
				sync_path(conf + '/network'); sync_path(conf);
			}
		}
		catch (e) { ctx?.unload('network'); for (let name in fs.lsdir(savedir) ?? []) fs.unlink(savedir + '/' + name); fs.rmdir(savedir); die(e.message); }
		for (let name in fs.lsdir(savedir) ?? []) fs.unlink(savedir + '/' + name);
		fs.rmdir(savedir);
	}

	function snapshot() {
		let result = { interface: IFACE, up: false, proto: '', addresses: [], uci_peers: [], peers: {}, route_ok: false };
		// A separate savedir prevents applying unrelated LuCI/CLI staged changes.
		secure_dir(run);
		let savedir = private_dir(run + '/uci-');
		if (!savedir) fail('TEMP_FAILED', '无法创建只读配置上下文');
		try {
			let ctx = cursor(conf, savedir);
			if (!ctx.load('network')) fail('UCI_READ_FAILED', '无法解析现有网络配置');
			result.proto = ctx.get('network', IFACE, 'proto') ?? '';
			result.addresses = list_value(ctx.get('network', IFACE, 'addresses'));
			ctx.foreach('network', 'wireguard_' + IFACE, (p) => {
				push(result.uci_peers, { section: p['.name'], options: section_options(p), public_key: p.public_key ?? '', name: p.description ?? '',
					allowed_ips: list_value(p.allowed_ips), disabled: p.disabled ?? '0' });
			});
			ctx.unload('network');
		}
		catch (e) { fs.rmdir(savedir); die(e.message); }
		fs.rmdir(savedir);
		let interfaces = trim(capture([wg, 'show', 'interfaces'], null, 8192));
		if (index(split(interfaces, /[[:space:]]+/), IFACE) < 0) return result;
		let dump = split(rtrim(capture([wg, 'show', IFACE, 'dump'], null, 1048576), '\n'), '\n');
		let first = split(shift(dump) ?? '', '\t');
		if (length(first) != 4 || !key(first[1])) fail('BAD_WG_OUTPUT', 'WireGuard 接口状态格式无效');
		// first[0] is the server private key. Never store it in the snapshot.
		result.public_key = first[1]; result.listen_port = int(first[2]); result.fwmark = first[3]; result.up = true;
		for (let line in dump) {
			let row = split(line, '\t');
			if (length(row) != 8 || !key(row[0]) || result.peers[row[0]]) fail('BAD_WG_OUTPUT', 'WireGuard 客户端状态格式无效');
			// wg show dump emits 'off' for a disabled keepalive, not numeric 0.
			if (row[7] != 'off' && !match(row[7], /^[0-9]{1,5}$/))
				fail('BAD_WG_OUTPUT', 'WireGuard 保活间隔格式无效');
			let keepalive = row[7] == 'off' ? 0 : int(row[7]);
			if (keepalive > 65535) fail('BAD_WG_OUTPUT', 'WireGuard 保活间隔超出范围');
			result.peers[row[0]] = {
				preshared_key: row[1], endpoint: row[2] == '(none)' ? '' : row[2],
				allowed_ips: row[3] == '(none)' ? [] : split(row[3], ','), latest_handshake: int(row[4]),
				transfer_rx: int(row[5]), transfer_tx: int(row[6]), persistent_keepalive: keepalive
			};
		}
		let route = capture([ip, '-4', 'route', 'show', 'dev', IFACE], null, 16384);
		result.route_ok = match(route, /(^|\n)192\.168\.66\.0\/24(\s|$)/) != null;
		return result;
	}

	function change_peer(old, next, purpose, endpoint) {
		let pub = next?.public_key ?? old?.public_key;
		if (!key(pub) || (old && next && old.public_key != next.public_key)) fail('INVALID_PEER', '目标公钥无效');
		let argv = [wg, 'set', IFACE, 'peer', pub];
		if (!next || !next.enabled) {
			push(argv, 'remove');
			capture(argv, null, 8192);
			return;
		}
		if ((next.preshared_key != '' && !key(next.preshared_key)) || ipv4(next.address) == null || !match(next.address, /^192\.168\.66\./))
			fail('INVALID_PEER', '目标客户端数据无效');
		if (purpose == 'apply' && old?.enabled) {
			// An address edit never rewrites the PSK or resets other peer fields.
			push(argv, 'allowed-ips', next.address + '/32');
			capture(argv, null, 8192);
			return;
		}
		with_temp((dir) => {
			secret_file(dir + '/psk', next.preshared_key ? next.preshared_key + '\n' : '');
			push(argv, 'preshared-key', dir + '/psk', 'allowed-ips', next.address + '/32', 'persistent-keepalive', '' + (next.persistent_keepalive ?? 0));
			if (!endpoint && next.source == 'uci' && next.uci_options.endpoint_host) {
				let host = next.uci_options.endpoint_host, port = next.uci_options.endpoint_port || '51820';
				if (!match(host, /^[A-Za-z0-9.:-]+$/) || !match(''+port, /^[0-9]{1,5}$/) || int(port) < 1 || int(port) > 65535) fail('INVALID_PEER', '既有客户端端点格式无效');
				endpoint = (index(host, ':') >= 0 ? '[' + host + ']' : host) + ':' + port;
			}
			if (endpoint && (purpose != 'apply' || next.source == 'uci')) {
				if (!match(endpoint, /^([A-Za-z0-9.-]+|\[[0-9a-fA-F:]+\]):[0-9]{1,5}$/)) fail('INVALID_PEER', '客户端端点格式无效');
				push(argv, 'endpoint', endpoint);
			}
			capture(argv, null, 8192);
		});
	}

	function clock() {
		return { wall: time(), uptime: +split(trim(fs.readfile('/proc/uptime') ?? '0'), ' ')[0],
			boot: trim(fs.readfile('/proc/sys/kernel/random/boot_id') ?? '') };
	}

	function sample(snap, force) {
		let now = clock();
		let ledger = read_json(run + '/traffic.json', true) ?? read_json(data + '/traffic.json', true);
		ledger = accumulate(ledger, snap, now);
		atomic(run + '/traffic.json', ledger, false);
		if (force || now.wall - ledger.last_checkpoint >= 900) {
			ledger.last_checkpoint = now.wall;
			atomic(data + '/traffic.json', ledger, true);
			atomic(run + '/traffic.json', ledger, false);
		}
		return ledger;
	}

	return {
		lock: function() {
			secure_dir(run);
			let path = run + '/lock';
			if (fs.lstat(path)) safe_file(path, 128, false);
			lock_handle = fs.open(path, 'ae', 384);
			if (!lock_handle || !lock_handle.lock('xn')) fail('BUSY', '另一个管理或采样操作正在进行，请稍后重试');
		},
		unlock: function() { lock_handle?.close(); lock_handle = null; },
		backup_existing: function(state) {
			let path = data + '/before-existing-' + random_hex(8) + '.json';
			let network = fs.readfile(conf + '/network');
			if (network == null || length(network) > 1048576) fail('BACKUP_FAILED', '无法备份接管前配置');
			atomic(path, { schema: 1, state, network }, true);
			return path;
		},
		load_state: () => read_json(data + '/state.json', true),
		save_state: (state) => atomic(data + '/state.json', state, true),
		load_journal: () => read_json(data + '/journal.json', true),
		save_journal: (journal) => atomic(data + '/journal.json', journal, true),
		remove_journal: function() {
			if (!fs.unlink(data + '/journal.json')) fail('STORAGE_ERROR', '无法清理已完成事务记录');
			// If power is lost before deletion reaches storage, recovery remains
			// conservative: an old journal reappears and blocks further changes.
			system([sync, '-f', data], 5000);
		},
		save_plan: function(token, value) {
			let count = 0, now = clock();
			for (let name in fs.lsdir(run) ?? []) {
				if (!match(name, /^[0-9a-f]{48}\.plan$/)) continue;
				let plan = read_json(run + '/' + name, false);
				if (plan.boot != now.boot || plan.expires < now.uptime) fs.unlink(run + '/' + name); else count++;
			}
			if (count >= 64) fail('PLAN_LIMIT', '未完成预览过多，请稍后重试');
			atomic(run + '/' + token + '.plan', value, false);
		},
		load_plan: (token) => read_json(run + '/' + token + '.plan', true),
		remove_plan: (token) => fs.unlink(run + '/' + token + '.plan'),
		generate_keys: function() {
			let priv = trim(capture([wg, 'genkey'], null, 128));
			let pub = trim(capture([wg, 'pubkey'], priv + '\n', 128));
			let psk = trim(capture([wg, 'genpsk'], null, 128));
			if (!key(priv) || !key(pub) || !key(psk)) fail('KEY_GENERATION_FAILED', '密钥生成失败');
			return { private_key: priv, public_key: pub, preshared_key: psk };
		},
		qr: (config) => capture([qrencode, '-t', 'SVG', '-m', '4', '-l', 'M', '-o', '-'], config, 524288),
		snapshot, change_peer, change_uci_peer, clock, sample, random_hex,
		reset_counter: function(pub, enabled) {
			let ledger = read_json(run + '/traffic.json', true);
			if (!ledger?.peers?.[pub]) return;
			let p = ledger.peers[pub];
			// A removal/re-add starts a fresh kernel counter epoch. Address-only
			// changes retain counters, so use the current value as the baseline.
			let live = snapshot().peers[pub];
			p.last_rx = live?.transfer_rx ?? 0; p.last_tx = live?.transfer_tx ?? 0;
			p.boot = clock().boot;
			atomic(run + '/traffic.json', ledger, false);
			ledger.last_checkpoint = clock().wall;
			atomic(data + '/traffic.json', ledger, true);
		},
		collector_running: function() {
			let marker = read_json(run + '/collector.json', true);
			return marker != null && marker.boot == clock().boot && clock().uptime - marker.uptime < 35;
		},
		collector_mark: function() { atomic(run + '/collector.json', clock(), false); },
		dependency_check: function() {
			let result = {};
			for (let entry in [wg, ip, qrencode, sync]) result[entry] = fs.access(entry, 'x');
			return result;
		}
	};
}

export { platform };

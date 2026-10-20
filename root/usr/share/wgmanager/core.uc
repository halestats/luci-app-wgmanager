// SPDX-License-Identifier: Apache-2.0
// Pure policy/transaction code. The platform adapter owns all side effects.
'use strict';

const VERSION = '0.3.1';
const IFACE = 'wg';
const PORT = 51820;
const SUBNET = '192.168.66.0/24';

function fail(code, message) { die(`${code}|${message}`); }
function clone(value) { return json(sprintf('%J', value)); }
function equal(a, b) { return sprintf('%J', a) == sprintf('%J', b); }

function key(value) {
	return type(value) == 'string' && match(value, /^[A-Za-z0-9+/]{43}=$/) != null &&
		length(b64dec(value)) == 32 && b64enc(b64dec(value)) == value;
}

function ipv4(value) {
	if (type(value) != 'string' || !match(value, /^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$/))
		return null;
	let out = 0;
	for (let octet in split(value, '.')) {
		if (int(octet) > 255) return null;
		out = out * 256 + int(octet);
	}
	return out;
}

function cidr(value) {
	if (type(value) != 'string') return null;
	let parts = split(value, '/');
	let address = ipv4(parts[0]);
	let bits = length(parts) == 1 ? 32 : int(parts[1]);
	if (address == null || length(parts) > 2 || (length(parts) == 2 && !match(parts[1], /^(0|[1-9][0-9]?)$/)) || bits < 0 || bits > 32)
		return null;
	let size = 2 ** (32 - bits);
	let start = int(address / size) * size;
	return { start, end: start + size - 1, bits };
}

function validate_name(name) {
	if (type(name) != 'string' || length(name) < 1 || length(name) > 96 || (index(name, '\x00') >= 0 || match(name, /[[:cntrl:]]/)))
		fail('INVALID_NAME', '名称须为 1–96 字节，不能包含换行或控制字符');
	return name;
}

function validate_id(id) {
	if (type(id) != 'string' || !match(id, /^p[0-9a-f]{24}$/)) fail('INVALID_ID', '客户端标识无效');
	return id;
}

function own_keys(object, allowed) {
	if (type(object) != 'object') fail('INVALID_INPUT', '参数须为 JSON 对象');
	for (let name in keys(object))
		if (index(allowed, name) < 0) fail('INVALID_INPUT', '含不支持的参数');
}

function validate_address(address) {
	let n = ipv4(address);
	if (n == null || n < ipv4('192.168.66.2') || n > ipv4('192.168.66.254'))
		fail('INVALID_ADDRESS', '客户端地址须在 192.168.66.2–254 范围内');
	return address;
}

function validate_settings(value) {
	own_keys(value, ['endpoint', 'dns', 'routes', 'keepalive']);
	let host = value.endpoint;
	if (type(host) != 'string' || length(host) > 253 ||
		(host != '' && (!match(host, /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/) || index(host, '..') >= 0)))
		fail('INVALID_ENDPOINT', '请填写 IPv4 地址或域名，不带协议、路径或端口');
	if (host != '' && match(host, /^[0-9.]+$/) && ipv4(host) == null)
		fail('INVALID_ENDPOINT', 'IPv4 地址无效');
	for (let label in split(host, '.'))
		if (length(label) > 63 || (host != '' && !match(label, /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$/)))
			fail('INVALID_ENDPOINT', '域名标签无效');
	if (type(value.dns) != 'array' || length(value.dns) > 3 ||
		type(value.routes) != 'array' || length(value.routes) < 1 || length(value.routes) > 16)
		fail('INVALID_SETTINGS', 'DNS 最多 3 项，客户端路由须为 1–16 项');
	for (let address in value.dns)
		if (ipv4(address) == null) fail('INVALID_DNS', 'DNS 仅支持 IPv4 地址');
	for (let route in value.routes)
		if (cidr(route) == null || index(route, '/') < 0) fail('INVALID_ROUTES', '客户端路由须为 IPv4 CIDR');
	if (type(value.keepalive) != 'int' || value.keepalive < 0 || value.keepalive > 65535)
		fail('INVALID_KEEPALIVE', 'Keepalive 须为 0–65535 的整数');
	return clone(value);
}

function empty_state() {
	return { schema: 1, revision: 0, mode: 'monitor', server_public_key: '', protected_keys: [],
		settings: { endpoint: '', dns: [], routes: [SUBNET, '192.168.95.0/24'], keepalive: 25 }, peers: {} };
}

function legacy(peer) { return peer?.source == 'uci'; }
function valid_section(section) { return type(section) == 'string' && match(section, /^[A-Za-z0-9_]+$/); }
function options_equal(a, b) {
 if (type(a) != 'object' || type(b) != 'object' || !equal(sort(keys(a)), sort(keys(b)))) return false;
 for (let k in keys(a)) if (!equal(a[k], b[k])) return false;
 return true;
}
function validate_state(state) {
	if (type(state) != 'object' || state.schema != 1 || type(state.revision) != 'int' || state.revision < 0 ||
		(state.mode != 'monitor' && state.mode != 'manage') || type(state.peers) != 'object' ||
		length(keys(state.peers)) > 128 || type(state.protected_keys) != 'array' ||
		(state.server_public_key != '' && !key(state.server_public_key)))
		fail('INVALID_STATE', '管理数据损坏，已停止写入；请保留文件并检查');
	validate_settings(state.settings);
	if ((state.mode == 'manage' || length(keys(state.peers)) > 0) && !key(state.server_public_key))
		fail('INVALID_STATE', '管理数据缺少服务端身份');
	let seen = {}, addresses = {};
	for (let pub in state.protected_keys) {
		if (!key(pub) || seen[pub]) fail('INVALID_STATE', '受保护公钥列表无效');
		seen[pub] = true;
	}
	for (let id, peer in state.peers) {
		validate_id(id);
		if (type(peer) != 'object' || !key(peer.public_key) ||
			(legacy(peer) ? (peer.private_key != null || (peer.preshared_key != '' && !key(peer.preshared_key))) : (!key(peer.private_key) || !key(peer.preshared_key))) ||
			type(peer.enabled) != 'bool' || seen[peer.public_key]) fail('INVALID_STATE', '客户端数据无效或与受保护客户端冲突');
		if (legacy(peer) && (state.existing_management !== true || !valid_section(peer.uci_section) || type(peer.uci_options) != 'object' || peer.uci_options.public_key != peer.public_key || type(peer.persistent_keepalive) != 'int' || peer.persistent_keepalive < 0 || peer.persistent_keepalive > 65535)) fail('INVALID_STATE', '既有客户端记录无效');
		validate_name(peer.name);
		validate_address(peer.address);
		if (addresses[peer.address]) fail('INVALID_STATE', '管理数据含重复客户端地址');
		addresses[peer.address] = true;
		seen[peer.public_key] = true;
	}
	return state;
}

function configured(snapshot) {
	let result = {};
	for (let peer in snapshot.uci_peers ?? []) {
		if (key(peer.public_key)) result[peer.public_key] = peer;
	}
	return result;
}

function legacy_matches(snapshot, peer) {
 let source = configured(snapshot)[peer.public_key];
 return source != null && source.section == peer.uci_section && options_equal(source.options, peer.uci_options);
}
function uci_fingerprint(snapshot, except_section) {
 let out = {};
 for (let p in snapshot.uci_peers ?? []) if (p.section != except_section) out[p.section] = p.options;
 return out;
}

function find_owned(state, public_key) {
	for (let id, peer in state.peers)
		if (peer.public_key == public_key) return id;
	return null;
}

function ready(snapshot, state) {
	if (!snapshot.up || snapshot.interface != IFACE || snapshot.listen_port != PORT || !key(snapshot.public_key))
		fail('INTERFACE_NOT_READY', '现有 wg 接口未运行或监听端口不匹配；插件不会启动或修改接口');
	if (snapshot.proto != 'wireguard' || index(snapshot.addresses ?? [], '192.168.66.1/24') < 0 || !snapshot.route_ok)
		fail('UNSUPPORTED_NETWORK', '现有接口或直连网段不符合预期；插件不会修改路由或防火墙');
	if (state.server_public_key != '' && snapshot.public_key != state.server_public_key)
		fail('SERVER_CHANGED', '服务端公钥发生变化，管理操作已锁定');
	let uci = configured(snapshot);
	for (let pub in state.protected_keys)
		if (!uci[pub] && !snapshot.peers[pub]) fail('PROTECTED_CHANGED', '既有客户端集合发生变化，请先检查原配置');
	for (let id, peer in state.peers)
		if (uci[peer.public_key] && !legacy(peer)) fail('UCI_COLLISION', '插件客户端公钥已出现在原网络配置中，停止管理以避免冲突');
}

function overlaps(snapshot, state, address, except_id) {
	let n = ipv4(address);
	for (let id, peer in state.peers)
		if (id != except_id && peer.address == address) return true;
	let except_key = state.peers[except_id]?.public_key;
	for (let peer in snapshot.uci_peers ?? []) {
		if (peer.public_key == except_key) continue;
		for (let value in peer.allowed_ips ?? []) {
			if (index(value, ':') >= 0) continue;
			let range = cidr(value);
			if (!range) fail('UNKNOWN_ALLOWED_IPS', '既有客户端含无法识别的 AllowedIPs，停止自动分配');
			if (n >= range.start && n <= range.end) return true;
		}
	}
	for (let pub, peer in snapshot.peers ?? {}) {
		if (pub == except_key) continue;
		for (let value in peer.allowed_ips ?? []) {
			if (index(value, ':') >= 0) continue;
			let range = cidr(value);
			if (!range) fail('UNKNOWN_ALLOWED_IPS', '运行中的客户端含无法识别的 AllowedIPs');
			if (n >= range.start && n <= range.end) return true;
		}
	}
	return false;
}

function allocate(snapshot, state) {
	for (let i = 2; i < 255; i++) {
		let address = `192.168.66.${i}`;
		if (!overlaps(snapshot, state, address, null)) return address;
	}
	fail('POOL_EXHAUSTED', '网段内没有可用客户端地址，含禁用客户端的地址也会保留');
}

function target_matches(actual, peer) {
	if (!peer || !peer.enabled) return actual == null;
	return actual != null && equal(actual.allowed_ips, [`${peer.address}/32`]) &&
		(actual.preshared_key == peer.preshared_key || (legacy(peer) && peer.preshared_key == '' && actual.preshared_key == '(none)')) &&
		(actual.persistent_keepalive ?? 0) == (peer.persistent_keepalive ?? 0);
}

function assert_target(snapshot, peer) {
	if (peer && (!target_matches(snapshot.peers[peer.public_key], peer) || (legacy(peer) && !legacy_matches(snapshot, peer))))
		fail('PEER_DRIFT', '该客户端运行状态与管理记录不一致，请先运行 doctor 检查');
}

function fingerprint(snapshot, except_key) {
	let peers = {};
	for (let pub in sort(keys(snapshot.peers ?? {}))) {
		if (pub == except_key) continue;
		let p = snapshot.peers[pub];
		peers[pub] = { allowed_ips: sort(clone(p.allowed_ips)), preshared_key: p.preshared_key,
			persistent_keepalive: p.persistent_keepalive ?? 0 };
	}
	return { public_key: snapshot.public_key, listen_port: snapshot.listen_port, fwmark: snapshot.fwmark, peers };
}

function accumulate(ledger, snapshot, clock) {
	ledger ??= { schema: 1, peers: {}, last_checkpoint: clock.wall, started: clock.wall };
	if (ledger.schema != 1 || type(ledger.peers) != 'object') fail('INVALID_STATS', '流量记录损坏，请先检查记录文件');
	for (let pub, peer in snapshot.peers ?? {}) {
		let last = ledger.peers[pub];
		let rx = max(0, +peer.transfer_rx || 0), tx = max(0, +peer.transfer_tx || 0);
		if (!last) last = { total_rx: 0, total_tx: 0, last_rx: 0, last_tx: 0, boot: clock.boot };
		let same_boot = last.boot == clock.boot;
		last.total_rx += same_boot && rx >= last.last_rx ? rx - last.last_rx : rx;
		last.total_tx += same_boot && tx >= last.last_tx ? tx - last.last_tx : tx;
		last.last_rx = rx;
		last.last_tx = tx;
		last.boot = clock.boot;
		last.seen = clock.wall;
		ledger.peers[pub] = last;
	}
	return ledger;
}

function manager(io) {
	function load() { return validate_state(io.load_state() ?? empty_state()); }
	function no_journal() {
		if (io.load_journal()) fail('RECOVERY_REQUIRED', '存在未完成事务，已锁定写入；先运行 wgmanager doctor');
	}
	function management(state, snap) {
		if (state.mode != 'manage') fail('READ_ONLY', '当前为只读阶段，请先完成设备验证并在 SSH 启用管理');
		no_journal();
		ready(snap, state);
	}
	function status() {
		let state = load(), snap = io.snapshot();
		let ledger = io.sample(snap, false), rows = [], added = {};
		function add(pub, own, source) {
			let live = snap.peers[pub], totals = ledger.peers[pub];
			let uci = source ?? {};
			let enabled = own ? own.enabled : (uci.disabled != '1');
			push(rows, {
				id: own ? find_owned(state, pub) : '', public_key: pub,
				name: own?.name ?? uci.name ?? '未命名客户端',
				allowed_ips: own ? [`${own.address}/32`] : (uci.allowed_ips ?? live?.allowed_ips ?? []),
				endpoint: live?.endpoint ?? '', latest_handshake: live?.latest_handshake ?? 0,
				transfer_rx: live?.transfer_rx ?? 0, transfer_tx: live?.transfer_tx ?? 0,
				total_rx: totals?.total_rx ?? 0, total_tx: totals?.total_tx ?? 0,
				enabled, managed: own != null, protected: own == null, present: live != null,
				drift: own ? (!target_matches(live, own) || (legacy(own) && !legacy_matches(snap, own))) : false, exportable: own != null && !legacy(own), legacy: legacy(own)
			});
			added[pub] = true;
		}
		for (let p in snap.uci_peers ?? []) if (key(p.public_key) && !added[p.public_key]) { let owned = find_owned(state, p.public_key); add(p.public_key, owned ? state.peers[owned] : null, p); }
		for (let id, p in state.peers) if (!added[p.public_key]) add(p.public_key, p, null);
		for (let pub, p in snap.peers ?? {}) if (!added[pub]) add(pub, null, null);
		let health = 'ok', message = '';
		try { ready(snap, state); }
		catch (e) { health = 'blocked'; message = split(e.message, '|')[1] ?? '接口检查未通过'; }
		if (io.load_journal()) { health = 'recovery'; message = '存在未完成事务，管理已锁定；运行 wgmanager doctor'; }
		return { version: VERSION, mode: state.mode, existing_management: state.existing_management === true, revision: state.revision, health, message,
			interface: IFACE, up: snap.up, listen_port: snap.listen_port ?? PORT,
			public_key: snap.public_key ?? '', settings: clone(state.settings), peers: rows,
			stats: { started: ledger.started, last_checkpoint: ledger.last_checkpoint,
				collector: io.collector_running(), interval: 10, checkpoint_interval: 900 }, timestamp: io.clock().wall };
	}
	function prepare(args, owner) {
		let state = load(), snap = io.snapshot();
		management(state, snap);
		let action = args.action, id = args.peer_id ?? '';
		let payload;
		try { payload = json(args.payload ?? '{}'); } catch (e) { fail('INVALID_INPUT', '参数不是有效 JSON'); }
		let summary;
		if (action == 'settings') {
			payload = validate_settings(payload);
			summary = { title: '更新客户端导出设置', detail: '只影响之后下载的配置；不改变正在运行的客户端或原网络配置' };
		}
		else if (action == 'create') {
			own_keys(payload, ['name', 'address']);
			validate_name(payload.name);
			if (length(keys(state.peers)) >= 128) fail('PEER_LIMIT', '插件管理客户端上限为 128');
			payload.address = payload.address == null || payload.address == '' ? allocate(snap, state) : validate_address(payload.address);
			if (overlaps(snap, state, payload.address, null)) fail('IP_CONFLICT', '此地址已被配置或运行中的客户端占用');
			id = 'p' + io.random_hex(12);
			if (state.peers[id]) fail('ID_COLLISION', '随机标识冲突，请重试');
			summary = { title: '新增客户端', name: payload.name, address: payload.address, detail: '仅向现有 wg 添加一个 Peer' };
		}
		else {
			validate_id(id);
			let peer = state.peers[id];
			if (!peer) fail('PROTECTED_PEER', '请先在 SSH 执行 wgmanager manage-existing 接管既有客户端');
			assert_target(snap, peer);
			if (action == 'edit') {
				own_keys(payload, ['name', 'address']);
				validate_name(payload.name);
				payload.address = validate_address(payload.address);
				if (overlaps(snap, state, payload.address, id)) fail('IP_CONFLICT', '此地址与其他客户端的 AllowedIPs 重叠');
			}
			else if (action == 'enable' || action == 'disable' || action == 'delete') {
				own_keys(payload, []);
				if (action == 'enable' && peer.enabled) fail('NO_CHANGE', '客户端已启用');
				if (action == 'disable' && !peer.enabled) fail('NO_CHANGE', '客户端已禁用');
				if (action == 'enable' && overlaps(snap, state, peer.address, id)) fail('IP_CONFLICT', '此地址与其他客户端重叠');
			}
			else fail('INVALID_ACTION', '不支持的管理操作');
			summary = { title: { edit: '编辑客户端', enable: '启用客户端', disable: '禁用客户端', delete: '删除客户端' }[action],
				name: payload.name ?? peer.name, address: payload.address ?? peer.address,
				detail: (action == 'disable' || action == 'delete') ? '所选客户端将断开；其他客户端保持原状' :
					(action == 'edit' && payload.address != peer.address) ? '修改地址后须重新下载并导入此客户端配置' : '仅更新所选客户端' };
		}
		let clock = io.clock(), token = io.random_hex(24);
		io.save_plan(token, { schema: 1, owner, token, action, peer_id: id, payload,
			revision: state.revision, server_public_key: snap.public_key, boot: clock.boot,
			expires: clock.uptime + 60, summary });
		return { token, summary, expires_in: 60 };
	}
	function manage_existing() {
		let state = load(), snap = io.snapshot(); management(state, snap);
		let after = clone(state), adopted = 0, seen_uci = {};
		for (let source in snap.uci_peers ?? []) { if (seen_uci[source.public_key]) fail('UCI_COLLISION', '存在重复公钥的既有配置，接管已停止'); seen_uci[source.public_key] = true; }
		for (let source in snap.uci_peers ?? []) {
			if (!key(source.public_key) || find_owned(after, source.public_key)) continue;
			if (!valid_section(source.section) || type(source.options) != 'object' || length(source.allowed_ips) != 1 || !match(source.allowed_ips[0], /^192\.168\.66\.[0-9]+\/32$/))
				fail('UNSUPPORTED_LEGACY', '既有客户端须为单一 192.168.66.2–254/32 地址，未接管任何客户端');
			let address = validate_address(split(source.allowed_ips[0], '/')[0]);
			let keepalive = source.options.persistent_keepalive || '0';
			if (keepalive == 'off') keepalive = '0';
			if (!match(''+keepalive, /^[0-9]{1,5}$/) || int(keepalive) > 65535) fail('UNSUPPORTED_LEGACY', '既有保活参数无效');
			let psk = source.options.preshared_key ?? '';
			if (psk != '' && !key(psk)) fail('UNSUPPORTED_LEGACY', '既有预共享密钥格式无效');
			let id = 'p' + io.random_hex(12);
			if (after.peers[id]) fail('ID_COLLISION', '随机标识冲突，请重试');
			let peer = { source: 'uci', uci_section: source.section, uci_options: clone(source.options),
				public_key: source.public_key, private_key: null, preshared_key: psk,
				name: source.name || '既有客户端', address, enabled: source.disabled != '1',
				persistent_keepalive: int(keepalive), endpoint: snap.peers[source.public_key]?.endpoint ?? '' };
			if (!target_matches(snap.peers[source.public_key], peer)) fail('LEGACY_DRIFT', '既有客户端的持久配置与运行状态不同，未接管任何客户端');
			after.peers[id] = peer;
			after.protected_keys = filter(after.protected_keys, pub => pub != source.public_key);
			adopted++;
		}
		if (length(keys(after.peers)) > 128) fail('PEER_LIMIT', '接管后超出客户端上限');
		if (!adopted && state.existing_management === true) return { adopted: 0, protected_count: length(state.protected_keys), managed_count: length(keys(state.peers)), revision: state.revision };
		let backup = io.backup_existing ? io.backup_existing(state) : null;
		after.existing_management = true; after.revision++;
		io.save_state(validate_state(after));
		return { adopted, backup, protected_count: length(after.protected_keys), managed_count: length(keys(after.peers)), revision: after.revision };
	}
	function rollback_existing(journal) {
		validate_state(journal.before); validate_state(journal.after);
		let old = journal.before.peers[journal.peer_id], next = journal.after.peers[journal.peer_id];
		let current = io.snapshot(), stored = load();
		if (!legacy(old) || current.public_key != journal.server_public_key ||
			(!equal(stored, journal.before) && !equal(stored, journal.after))) fail('UNSAFE_RECOVERY', '服务端或管理记录已变化');
		// Refuse overwriting an externally modified target at either layer.
		if (!target_matches(current.peers[old.public_key], old) && !target_matches(current.peers[old.public_key], next))
			fail('UNSAFE_RECOVERY', '目标运行配置已被外部修改');
		io.change_uci_peer(next, old, 'rollback');
		if (journal.runtime_change) io.change_peer(next, old, 'rollback', journal.endpoint ?? '');
		let check = io.snapshot();
		if (!target_matches(check.peers[old.public_key], old) || !legacy_matches(check, old)) fail('ROLLBACK_FAILED', '目标配置恢复验证失败');
		io.save_state(journal.before); io.reset_counter(old.public_key, old.enabled); io.remove_journal();
	}
	function apply_existing(plan, before, snap) {
		let id = plan.peer_id, old = before.peers[id]; assert_target(snap, old);
		let next = clone(old), after = clone(before);
		if (plan.action == 'edit') {
			next.name = validate_name(plan.payload.name); next.address = validate_address(plan.payload.address);
			next.uci_options.description = next.name;
			next.uci_options.allowed_ips = [next.address + '/32'];
		}
		else if (plan.action == 'enable') { next.enabled = true; delete next.uci_options.disabled; }
		else if (plan.action == 'disable') { next.enabled = false; next.uci_options.disabled = '1'; next.endpoint = snap.peers[old.public_key]?.endpoint ?? old.endpoint; }
		else if (plan.action == 'delete') next = null;
		else fail('INVALID_ACTION', '既有客户端操作无效');
		if (next && overlaps(snap, before, next.address, id)) fail('IP_CONFLICT', '客户端地址已被其他配置占用');
		if (next) after.peers[id] = next; else delete after.peers[id];
		after.revision++; validate_state(after);
		let runtime_change = old.enabled != (next?.enabled ?? false) || (next?.enabled && old.address != next.address);
		let journal = { schema: 1, kind: 'uci_peer', peer_id: id, action: plan.action, before, after, runtime_change,
			server_public_key: snap.public_key, endpoint: snap.peers[old.public_key]?.endpoint ?? old.endpoint ?? '' };
		io.sample(snap, true); io.save_journal(journal);
		try {
			if (runtime_change) io.change_peer(old, next, 'apply', next?.endpoint ?? '');
			io.change_uci_peer(old, next, 'apply');
			let check = io.snapshot();
			if (!target_matches(check.peers[old.public_key], next) || (next && !legacy_matches(check, next)) ||
				(!next && configured(check)[old.public_key]) || !equal(fingerprint(snap, old.public_key), fingerprint(check, old.public_key)) ||
				!options_equal(uci_fingerprint(snap, old.uci_section), uci_fingerprint(check, old.uci_section)))
				fail('VERIFY_FAILED', '所选客户端写入后验证未通过');
			io.save_state(after); io.reset_counter(old.public_key, next?.enabled ?? false); io.remove_journal();
		}
		catch (e) {
			try { rollback_existing(journal); }
			catch (rollback_error) { fail('RECOVERY_REQUIRED', '既有客户端回滚未完成，运行 wgmanager doctor 后再恢复'); }
			let reason = split(e.message ?? '', '|')[0];
			if (index(['VERIFY_FAILED', 'COMMAND_FAILED', 'STORAGE_ERROR', 'SYNC_FAILED', 'UCI_WRITE_FAILED', 'PEER_DRIFT', 'INVALID_PEER'], reason) < 0) reason = 'INTERNAL_ERROR';
			fail('APPLY_FAILED', '所选既有客户端操作未完成（' + reason + '），已回滚该客户端');
		}
		return { revision: after.revision, peer_id: id, action: plan.action };
	}
	function recover_existing(journal) {
		if (journal.schema != 1 || !valid_section(journal.before?.peers?.[journal.peer_id]?.uci_section)) fail('UNSAFE_RECOVERY', '事务标识无效');
		rollback_existing(journal);
		return { recovered: true, peer_id: journal.peer_id, policy: 'rollback_selected_uci_peer' };
	}


	function apply(args, owner) {
		let token = args.token;
		if (type(token) != 'string' || !match(token, /^[0-9a-f]{48}$/)) fail('INVALID_TOKEN', '预览令牌无效');
		let plan = io.load_plan(token), clock = io.clock();
		if (!plan || plan.owner != owner) fail('INVALID_TOKEN', '预览不存在或不属于当前会话');
		// A preview is consumed once, including on stale/failed attempts.
		io.remove_plan(token);
		if (plan.boot != clock.boot || plan.expires < clock.uptime) fail('EXPIRED_PLAN', '预览已过期，请重新操作');
		let before = load(), snap = io.snapshot();
		management(before, snap);
		if (before.revision != plan.revision || plan.server_public_key != snap.public_key)
			fail('STALE_PLAN', '配置在预览后发生变化，请重新预览');
		let after = clone(before), id = plan.peer_id, old = before.peers[id], next;
		if (legacy(old)) return apply_existing(plan, before, snap);
		if (plan.action == 'settings') after.settings = validate_settings(plan.payload);
		else if (plan.action == 'create') {
			if (overlaps(snap, before, plan.payload.address, null)) fail('IP_CONFLICT', '地址在预览后被占用');
			let pair = io.generate_keys();
			if (!key(pair.private_key) || !key(pair.public_key) || !key(pair.preshared_key) ||
				configured(snap)[pair.public_key] || snap.peers[pair.public_key] || find_owned(before, pair.public_key) ||
				index(before.protected_keys, pair.public_key) >= 0) fail('KEY_GENERATION_FAILED', '生成的密钥无效或冲突');
			next = { name: plan.payload.name, address: validate_address(plan.payload.address), enabled: true,
				private_key: pair.private_key, public_key: pair.public_key, preshared_key: pair.preshared_key };
			after.peers[id] = next;
		}
		else {
			if (!old) fail('PROTECTED_PEER', '找不到插件创建的目标客户端');
			assert_target(snap, old);
			next = clone(old);
			if (plan.action == 'edit') {
				next.name = validate_name(plan.payload.name);
				next.address = validate_address(plan.payload.address);
			}
			else if (plan.action == 'enable') next.enabled = true;
			else if (plan.action == 'disable') next.enabled = false;
			else if (plan.action == 'delete') next = null;
			else fail('INVALID_ACTION', '不支持的管理操作');
			if (next && overlaps(snap, before, next.address, id)) fail('IP_CONFLICT', '客户端地址在预览后出现冲突');
			if (next) after.peers[id] = next; else delete after.peers[id];
		}
		after.revision++;
		validate_state(after);
		let pub = next?.public_key ?? old?.public_key;
		let runtime_change = (old?.enabled ?? false) != (next?.enabled ?? false) ||
			(next?.enabled && old?.address != next.address);
		if (!runtime_change) {
			io.save_state(after);
			return { revision: after.revision, peer_id: id, action: plan.action };
		}
		io.sample(snap, true);
		let journal = { schema: 1, action: plan.action, peer_id: id, before, after,
			server_public_key: snap.public_key, endpoint: snap.peers[pub]?.endpoint ?? '' };
		io.save_journal(journal);
		try {
			io.change_peer(old, next, 'apply', '');
			let check = io.snapshot();
			if (!target_matches(check.peers[pub], next) || !equal(fingerprint(snap, pub), fingerprint(check, pub)))
				fail('VERIFY_FAILED', '运行状态验证未通过');
			io.save_state(after);
			io.reset_counter(pub, next?.enabled ?? false);
			io.remove_journal();
		}
		catch (e) {
			try {
				let current = io.snapshot();
				if (current.public_key != snap.public_key || configured(current)[pub]) fail('UNSAFE_ROLLBACK', '目标归属发生变化');
				io.change_peer(next, old, 'rollback', journal.endpoint);
				if (!target_matches(io.snapshot().peers[pub], old)) fail('ROLLBACK_FAILED', '回滚验证失败');
				io.save_state(before);
				io.reset_counter(pub, old?.enabled ?? false);
				io.remove_journal();
			}
			catch (rollback_error) { fail('RECOVERY_REQUIRED', '操作和回滚未全部完成，写入已锁定；请运行 wgmanager doctor'); }
			// Only expose an allowlisted error code, never command output or keys.
			let reason = split(e.message ?? '', '|')[0];
			if (index(['VERIFY_FAILED', 'COMMAND_FAILED', 'STORAGE_ERROR', 'SYNC_FAILED', 'BAD_WG_OUTPUT', 'TEMP_FAILED'], reason) < 0) reason = 'INTERNAL_ERROR';
			fail('APPLY_FAILED', '操作未完成（' + reason + '），已回滚所选客户端；未重启任何网络服务');
		}
		return { revision: after.revision, peer_id: id, action: plan.action };
	}
	function export_peer(args) {
		let state = load(), peer = state.peers[validate_id(args.peer_id)];
		if (!peer || legacy(peer)) fail('NO_PRIVATE_KEY', '旧客户端私钥不在插件中，无法恢复或重新生成配置');
		if (!state.settings.endpoint) fail('NO_ENDPOINT', '请先填写公网域名或 IPv4 地址');
		if (!key(state.server_public_key)) fail('NO_SERVER_KEY', '尚未初始化服务端公钥');
		let c = `[Interface]\nPrivateKey = ${peer.private_key}\nAddress = ${peer.address}/32\n`;
		if (length(state.settings.dns)) c += `DNS = ${join(', ', state.settings.dns)}\n`;
		c += `\n[Peer]\nPublicKey = ${state.server_public_key}\nPresharedKey = ${peer.preshared_key}\n`;
		c += `AllowedIPs = ${join(', ', state.settings.routes)}\nEndpoint = ${state.settings.endpoint}:${PORT}\n`;
		c += `PersistentKeepalive = ${state.settings.keepalive}\n`;
		let result = { filename: `${IFACE}-${args.peer_id}.conf`, config: c, disabled: !peer.enabled };
		if (args.qr === true) result.qr_svg = io.qr(c);
		return result;
	}
	function enable(value) {
		no_journal();
		let state = load(), snap = io.snapshot();
		if (value) {
			ready(snap, state);
			let protect = {};
			for (let pub in state.protected_keys) protect[pub] = true;
			for (let pub in keys(configured(snap))) if (!find_owned(state, pub)) protect[pub] = true;
			for (let pub in keys(snap.peers)) if (!find_owned(state, pub)) protect[pub] = true;
			state.protected_keys = sort(keys(protect));
			// Protect the existing peers actually found; a fresh server may have none.
			state.server_public_key = snap.public_key;
		}
		state.mode = value ? 'manage' : 'monitor';
		state.revision++;
		io.save_state(validate_state(state));
		return { mode: state.mode, protected_count: length(state.protected_keys), revision: state.revision };
	}
	function restore() {
		no_journal();
		let state = load(), snap = io.snapshot();
		// A fresh install is a strict no-op, even before the interface exists.
		if (!length(keys(state.peers))) return { restored: 0 };
		ready(snap, state);
		// Validate the whole intended set before touching the first peer.
		for (let id, peer in state.peers) {
			if (legacy(peer)) continue;
			if (overlaps(snap, state, peer.address, id)) fail('IP_CONFLICT', '恢复前发现地址冲突，未开始恢复');
			let actual = snap.peers[peer.public_key];
			if (actual && !target_matches(actual, peer)) fail('PEER_DRIFT', '运行状态发生变化，未开始恢复');
		}
		let restored = 0;
		for (let id, peer in state.peers) {
			if (legacy(peer) || !peer.enabled || snap.peers[peer.public_key]) continue;
			// Each restored peer uses the same durable transaction path.
			let before = clone(state), after = clone(state);
			before.peers[id].enabled = false;
			io.save_journal({ schema: 1, action: 'restore', peer_id: id, before, after,
				server_public_key: snap.public_key, endpoint: '' });
			io.change_peer(null, peer, 'restore', '');
			let check = io.snapshot();
			if (!target_matches(check.peers[peer.public_key], peer) ||
				!equal(fingerprint(snap, peer.public_key), fingerprint(check, peer.public_key)))
				fail('RECOVERY_REQUIRED', '恢复验证失败，已保留事务记录');
			io.reset_counter(peer.public_key, true);
			io.remove_journal();
			snap = check;
			restored++;
		}
		return { restored };
	}
	function recover() {
		let journal = io.load_journal();
		if (!journal) return { recovered: false };
		if (journal.kind == 'uci_peer') return recover_existing(journal);
		validate_state(journal.before);
		validate_state(journal.after);
		let stored = load();
		if (!equal(stored, journal.before) && !equal(stored, journal.after))
			fail('STALE_RECOVERY', '管理数据在事务后被外部修改，停止自动恢复以保留修改');
		validate_id(journal.peer_id);
		let old = journal.before.peers[journal.peer_id], next = journal.after.peers[journal.peer_id];
		let pub = old?.public_key ?? next?.public_key;
		let current = io.snapshot();
		if (journal.schema != 1 || !key(pub) || (old && next && old.public_key != next.public_key) ||
			current.public_key != journal.server_public_key || configured(current)[pub] ||
			index(journal.before.protected_keys, pub) >= 0 || index(journal.after.protected_keys, pub) >= 0)
			fail('UNSAFE_RECOVERY', '无法安全确认目标归属；事务记录已保留');
		io.change_peer(next, old, 'recovery', journal.endpoint ?? '');
		if (!target_matches(io.snapshot().peers[pub], old)) fail('RECOVERY_REQUIRED', '恢复验证失败，事务记录已保留');
		io.save_state(journal.before);
		io.reset_counter(pub, old?.enabled ?? false);
		io.remove_journal();
		return { recovered: true, peer_id: journal.peer_id, policy: 'rollback_single_peer' };
	}
	return { status, prepare, apply, export_peer, enable, manage_existing, restore, recover };
}

export { legacy, options_equal, valid_section, VERSION, IFACE, PORT, SUBNET, fail, clone, equal, key, ipv4, cidr, empty_state, validate_state, accumulate, manager };

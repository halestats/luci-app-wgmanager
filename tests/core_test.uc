'use strict';
import { manager, clone, equal, key, ipv4, cidr, accumulate, empty_state, fail } from '../root/usr/share/wgmanager/core.uc';
let passed = 0;
function assert(test, note) { if (!test) die('ASSERT: ' + note); }
function pk(i) { return b64enc(sprintf('%032d', i)); }
function fixture() {
	let snap = { interface: 'wg', up: true, proto: 'wireguard', public_key: pk(1), listen_port: 51820,
		fwmark: 'off', addresses: ['192.168.66.1/24'], route_ok: true, uci_peers: [], peers: {} };
	for (let i = 2; i <= 4; i++) {
		push(snap.uci_peers, { public_key: pk(i), name: 'legacy-' + i, allowed_ips: [`192.168.66.${i}/32`], disabled: '0' });
		snap.peers[pk(i)] = { allowed_ips: [`192.168.66.${i}/32`], preshared_key: pk(100 + i), endpoint: '203.0.113.8:45000',
			persistent_keepalive: 0, latest_handshake: 1700000000, transfer_rx: 1000 * i, transfer_tx: 2000 * i };
	}
	let original = clone(snap), state = null, journal = null, plans = {}, ledger = null, sequence = 100;
	let now = { wall: 1700000001, uptime: 100, boot: 'test-boot' }, changes = [], fault = {}, gen = 400;
	let io = {
		load_state: () => state ? clone(state) : null,
		save_state: function(s) { if (fault.save) { fault.save = false; fail('STORAGE_ERROR', 'test save failure'); } state = clone(s); },
		load_journal: () => journal ? clone(journal) : null,
		save_journal: function(j) { if (fault.journal) fail('STORAGE_ERROR', 'test journal failure'); journal = clone(j); },
		remove_journal: function() { if (fault.finalize) { fault.finalize = false; fail('STORAGE_ERROR', 'test finalize failure'); } journal = null; },
		save_plan: (token, p) => { plans[token] = clone(p); }, load_plan: (token) => plans[token], remove_plan: (token) => { delete plans[token]; },
		snapshot: () => clone(snap), clock: () => clone(now), collector_running: () => false,
		sample: function(s) { ledger = accumulate(ledger, s, now); return clone(ledger); },
		reset_counter: function(pub) { if (ledger?.peers?.[pub]) { ledger.peers[pub].last_rx = snap.peers[pub]?.transfer_rx ?? 0; ledger.peers[pub].last_tx = snap.peers[pub]?.transfer_tx ?? 0; } },
		random_hex: function(count) { sequence++; return sprintf('%0' + (count * 2) + 'x', sequence); },
		generate_keys: function() { gen++; return { public_key: pk(gen), private_key: pk(gen + 1000), preshared_key: pk(gen + 2000) }; },
		qr: (config) => '<svg>fake-qr</svg>',
		change_peer: function(old, next, purpose, endpoint) {
			push(changes, { purpose, old: clone(old), next: clone(next) });
			if (fault.change && purpose == 'apply') { fault.change = false; fail('COMMAND_FAILED', 'test command failure'); }
			if (fault.rollback && (purpose == 'rollback' || purpose == 'recovery')) fail('COMMAND_FAILED', 'test rollback failure');
			let pub = old?.public_key ?? next.public_key;
			if (!next || !next.enabled) delete snap.peers[pub];
			else snap.peers[pub] = { allowed_ips: [`${next.address}/32`], preshared_key: next.preshared_key,
				persistent_keepalive: 0, endpoint: endpoint ?? '', transfer_rx: 0, transfer_tx: 0, latest_handshake: 0 };
			if (fault.verify && purpose == 'apply') { fault.verify = false; snap.peers[pub].allowed_ips = ['192.168.66.250/32']; }
		}
	};
	let api = manager(io);
	return { api, io, snap, original, changes, fault, now,
		state: () => clone(state), journal: () => clone(journal),
		set_state: (s) => { state = clone(s); }, set_journal: (j) => { journal = clone(j); },
		unchanged: function() { for (let pub, peer in original.peers) assert(equal(peer, snap.peers[pub]), 'original peer unchanged'); },
		create: function(name, address) {
			let plan = api.prepare({ action: 'create', payload: sprintf('%J', { name: name ?? 'phone', address: address ?? '' }) }, 'owner');
			return api.apply({ token: plan.token }, 'owner').peer_id;
		},
		action: function(action, id, payload) {
			let p = api.prepare({ action, peer_id: id, payload: sprintf('%J', payload ?? {}) }, 'owner');
			return api.apply({ token: p.token }, 'owner');
		}
	};
}
function rejects(code, fn) {
	let caught = false;
	try { fn(); } catch (e) { caught = index(e.message, code + '|') >= 0; if (!caught) die('Expected ' + code + ', got ' + e.message); }
	assert(caught, 'expected rejection ' + code);
}
function test(name, fn) { fn(); passed++; printf('ok %d - %s\n', passed, name); }

test('strict IPv4, CIDR and canonical keys', () => {
	assert(ipv4('192.168.66.5') == 3232252421, 'parse address');
	assert(ipv4('192.168.066.5') == null && ipv4('256.0.0.1') == null, 'reject invalid IPv4');
	assert(cidr('0.0.0.0/0').end == 4294967295 && cidr('1.2.3.4/33') == null, 'CIDR bounds');
	assert(key(pk(1)) && !key(pk(1) + '\n') && !key('x'), 'keys');
});
test('fresh monitor lists all 3 peers and has zero write operations', () => {
	let f = fixture(), status = f.api.status();
	assert(length(status.peers) == 3 && status.mode == 'monitor', '3 peers monitor');
	assert(f.state() == null && length(f.changes) == 0, 'no persistent initialization');
	for (let p in status.peers) assert(p.protected && !p.managed && !p.exportable, 'protected legacy');
	f.unchanged();
});
test('status and errors do not disclose private keys or PSKs', () => {
	let f = fixture(); f.api.enable(true); let id = f.create();
	let output = sprintf('%J', f.api.status()), p = f.state().peers[id];
	assert(index(output, p.private_key) < 0 && index(output, p.preshared_key) < 0, 'managed secrets redacted');
	assert(index(output, pk(102)) < 0 && index(output, 'private_key') < 0, 'legacy secret redacted');
});
test('write methods fail closed in monitor mode', () => {
	let f = fixture(); rejects('READ_ONLY', () => f.create()); assert(length(f.changes) == 0, 'zero commands');
});
test('enable captures baseline without changing any peer', () => {
	let f = fixture(), result = f.api.enable(true);
	assert(result.protected_count == 3 && length(f.changes) == 0, 'baseline only'); f.unchanged();
});
test('first enable accepts a fresh server with no existing clients', () => {
	let f = fixture(); f.snap.uci_peers = []; f.snap.peers = {};
	let result = f.api.enable(true);
	assert(result.mode == 'manage' && result.protected_count == 0 && length(f.changes) == 0, 'empty baseline captures server identity only');
	assert(f.api.status().mode == 'manage' && length(f.api.status().peers) == 0, 'empty managed state remains readable');
});
test('create allocates .5 and targets only new peer', () => {
	let f = fixture(); f.api.enable(true); let id = f.create();
	assert(f.state().peers[id].address == '192.168.66.5', 'next free address');
	assert(length(f.changes) == 1 && f.changes[0].old == null, 'one target add'); f.unchanged();
});
test('disabled UCI addresses remain reserved even with no live endpoint', () => {
	let f = fixture(); f.snap.uci_peers[0].disabled = '1'; delete f.snap.peers[pk(2)];
	f.api.enable(true); let id = f.create(); assert(f.state().peers[id].address == '192.168.66.5', 'disabled reserved');
});
test('broad legacy AllowedIPs cannot be stolen', () => {
	let f = fixture(); f.snap.uci_peers[0].allowed_ips = ['192.168.66.0/24']; f.api.enable(true);
	rejects('POOL_EXHAUSTED', () => f.create()); assert(length(f.changes) == 0, 'no changes');
});
test('kernel-only AllowedIPs are reserved', () => {
	let f = fixture(); f.snap.peers[pk(99)] = clone(f.snap.peers[pk(2)]); f.snap.peers[pk(99)].allowed_ips = ['192.168.66.5/32'];
	f.api.enable(true); let id = f.create(); assert(f.state().peers[id].address == '192.168.66.6', 'kernel peer reserved');
});
test('explicit IP conflict and newline name rejected without commands', () => {
	let f = fixture(); f.api.enable(true);
	rejects('IP_CONFLICT', () => f.create('same', '192.168.66.2'));
	rejects('INVALID_NAME', () => f.create('x\nPostUp=evil')); assert(length(f.changes) == 0, 'no commands');
});
test('unknown fields cannot override generated public keys', () => {
	let f = fixture(); f.api.enable(true);
	rejects('INVALID_INPUT', () => f.api.prepare({ action: 'create', payload: sprintf('%J', { name: 'x', public_key: pk(2) }) }, 'owner'));
});
test('lifecycle edit, disable, enable, delete retains legacy peers', () => {
	let f = fixture(); f.api.enable(true); let id = f.create();
	f.action('edit', id, { name: 'Renamed', address: '192.168.66.7' });
	assert(f.state().peers[id].name == 'Renamed', 'edit stored');
	f.action('disable', id); assert(!f.snap.peers[f.state().peers[id].public_key], 'disabled removed from kernel');
	let second = f.create(); assert(f.state().peers[second].address == '192.168.66.5', 'freed edited address reused');
	f.action('enable', id); f.action('delete', id);
	assert(!f.state().peers[id] && length(f.api.status().peers) == 4, 'deleted only selected peer'); f.unchanged();
});
test('disabled managed IP remains reserved', () => {
	let f = fixture(); f.api.enable(true); let id = f.create(); f.action('disable', id);
	let id2 = f.create(); assert(f.state().peers[id2].address == '192.168.66.6', 'disabled managed address reserved');
});
test('metadata-only edit makes no wg call', () => {
	let f = fixture(); f.api.enable(true); let id = f.create(); let before = length(f.changes);
	f.action('edit', id, { name: '<img src=x onerror=alert(1)>', address: '192.168.66.5' });
	assert(length(f.changes) == before, 'metadata only'); f.unchanged();
});
test('legacy keys and made-up ids cannot be deleted or exported', () => {
	let f = fixture(); f.api.enable(true);
	rejects('INVALID_ID', () => f.action('delete', pk(2)));
	rejects('PROTECTED_PEER', () => f.action('delete', 'p111111111111111111111111'));
	rejects('NO_PRIVATE_KEY', () => f.api.export_peer({ peer_id: 'p111111111111111111111111' }));
	f.unchanged();
});
test('session-bound, single-use, expiring previews', () => {
	let f = fixture(); f.api.enable(true);
	let plan = f.api.prepare({ action: 'create', payload: '{"name":"x"}' }, 'owner');
	rejects('INVALID_TOKEN', () => f.api.apply({ token: plan.token }, 'other'));
	f.now.uptime += 61; rejects('EXPIRED_PLAN', () => f.api.apply({ token: plan.token }, 'owner'));
	rejects('INVALID_TOKEN', () => f.api.apply({ token: plan.token }, 'owner'));
	assert(length(f.changes) == 0, 'no expired changes');
});
test('stale revision rejects a concurrent second preview', () => {
	let f = fixture(); f.api.enable(true);
	let a = f.api.prepare({ action: 'create', payload: '{"name":"a"}' }, 'owner');
	let b = f.api.prepare({ action: 'create', payload: '{"name":"b"}' }, 'owner');
	f.api.apply({ token: a.token }, 'owner'); rejects('STALE_PLAN', () => f.api.apply({ token: b.token }, 'owner')); f.unchanged();
});
test('IP claimed between preview and apply is rejected', () => {
	let f = fixture(); f.api.enable(true);
	let a = f.api.prepare({ action: 'create', payload: '{"name":"a"}' }, 'owner');
	push(f.snap.uci_peers, { public_key: pk(99), allowed_ips: ['192.168.66.5/32'], disabled: '1' });
	rejects('IP_CONFLICT', () => f.api.apply({ token: a.token }, 'owner')); assert(length(f.changes) == 0, 'zero commands');
});
test('server identity, invalid port, route and protected-set changes freeze mutations', () => {
	for (let kind in ['public_key', 'listen_port', 'route_ok', 'protected']) {
		let f = fixture(); f.api.enable(true);
		if (kind == 'protected') { f.snap.uci_peers = []; f.snap.peers = {}; }
		else f.snap[kind] = kind == 'public_key' ? pk(9999) : kind == 'listen_port' ? 0 : false;
		rejects(kind == 'public_key' ? 'SERVER_CHANGED' : kind == 'protected' ? 'PROTECTED_CHANGED' : kind == 'route_ok' ? 'UNSUPPORTED_NETWORK' : 'INTERFACE_NOT_READY', () => f.create());
		assert(length(f.changes) == 0, 'zero changes on incompatible interface');
	}
});
test('external edits to a managed peer block destructive changes', () => {
	let f = fixture(); f.api.enable(true); let id = f.create();
	f.snap.peers[f.state().peers[id].public_key].allowed_ips = ['10.0.0.0/8'];
	rejects('PEER_DRIFT', () => f.action('disable', id)); f.unchanged();
});
test('journal save failure happens before any live mutation', () => {
	let f = fixture(); f.api.enable(true); f.fault.journal = true;
	rejects('STORAGE_ERROR', () => f.create()); assert(length(f.changes) == 0, 'no live change without journal'); f.unchanged();
});
test('wg failure rolls back exactly one new key', () => {
	let f = fixture(); f.api.enable(true); let revision = f.state().revision; f.fault.change = true;
	rejects('APPLY_FAILED', () => f.create()); assert(f.state().revision == revision && f.journal() == null, 'rollback complete'); f.unchanged();
});
test('post-write verification failure rolls back', () => {
	let f = fixture(); f.api.enable(true); f.fault.verify = true;
	rejects('APPLY_FAILED', () => f.create()); assert(length(f.api.status().peers) == 3, 'no stranded peer'); f.unchanged();
});
test('state save failure after a live add removes only the new peer', () => {
	let f = fixture(); f.api.enable(true); f.fault.save = true;
	rejects('APPLY_FAILED', () => f.create()); assert(length(f.api.status().peers) == 3 && f.journal() == null, 'rollback persisted'); f.unchanged();
});
test('rollback failure retains journal, blocks writes, and explicit recovery repairs it', () => {
	let f = fixture(); f.api.enable(true); f.fault.verify = true; f.fault.rollback = true;
	rejects('RECOVERY_REQUIRED', () => f.create()); assert(f.journal() != null, 'journal retained');
	rejects('RECOVERY_REQUIRED', () => f.create()); assert(f.api.status().health == 'recovery', 'status shows recovery');
	f.fault.rollback = false; assert(f.api.recover().recovered, 'recovery succeeds');
	assert(f.journal() == null && length(f.api.status().peers) == 3, 'restored baseline'); f.unchanged();
});
test('settings are config-injection safe and never call wg set', () => {
	let f = fixture(); f.api.enable(true);
	rejects('INVALID_ENDPOINT', () => f.action('settings', '', { endpoint: 'x\nPostUp=bad', dns: [], routes: ['0.0.0.0/0'], keepalive: 25 }));
	f.action('settings', '', { endpoint: 'vpn.example.com', dns: ['192.168.95.1'], routes: ['192.168.95.0/24'], keepalive: 25 });
	assert(length(f.changes) == 0, 'no runtime change for settings');
	let id = f.create(), secret = f.api.export_peer({ peer_id: id, qr: true });
	assert(index(secret.config, 'Endpoint = vpn.example.com:51820') >= 0 && index(secret.config, 'Address = 192.168.66.5/32') >= 0, 'correct export');
	assert(index(secret.config, '::/0') < 0 && secret.qr_svg != '', 'IPv4 export and QR'); f.unchanged();
});
test('restore adds missing plugin peers and is idempotent', () => {
	let f = fixture(); f.api.enable(true); let id = f.create(); let pub = f.state().peers[id].public_key;
	delete f.snap.peers[pub]; assert(f.api.restore().restored == 1, 'restored');
	let count = length(f.changes); assert(f.api.restore().restored == 0 && length(f.changes) == count, 'idempotent'); f.unchanged();
});
test('restore validates all conflicts before its first command', () => {
	let f = fixture(); f.api.enable(true); let id = f.create(); delete f.snap.peers[f.state().peers[id].public_key];
	push(f.snap.uci_peers, { public_key: pk(88), allowed_ips: ['192.168.66.5/32'] });
	let count = length(f.changes); rejects('IP_CONFLICT', () => f.api.restore()); assert(length(f.changes) == count, 'no restore started'); f.unchanged();
});
test('fresh install restore is a no-op on an absent interface', () => {
	let f = fixture(); f.snap.up = false; assert(f.api.restore().restored == 0 && length(f.changes) == 0, 'no create interface');
});
test('sampling handles increments, counter reset and reboot without negative deltas', () => {
	let f = fixture(), a = f.api.status(); assert(a.peers[0].total_rx == 2000, 'first count');
	f.snap.peers[pk(2)].transfer_rx += 100; assert(f.api.status().peers[0].total_rx == 2100, 'delta');
	f.snap.peers[pk(2)].transfer_rx = 50; assert(f.api.status().peers[0].total_rx == 2150, 'reset');
	f.now.boot = 'new-boot'; f.snap.peers[pk(2)].transfer_rx = 20;
	assert(f.api.status().peers[0].total_rx == 2170, 'new boot');
});
test('corrupt state is never silently replaced with empty state', () => {
	let f = fixture(); f.set_state({ schema: 99 }); rejects('INVALID_STATE', () => f.api.status());
	assert(f.state().schema == 99 && length(f.changes) == 0, 'corrupt file retained');
});
test('corrupt manage mode without pinned server identity is refused', () => {
	let f = fixture(), state = empty_state(); state.mode = 'manage'; f.set_state(state);
	rejects('INVALID_STATE', () => f.api.status()); assert(length(f.changes) == 0, 'no unpinned writes');
});
test('recovery refuses management data edited outside the transaction', () => {
	let f = fixture(); f.api.enable(true); f.fault.verify = true; f.fault.rollback = true;
	rejects('RECOVERY_REQUIRED', () => f.create());
	let changed = f.state(); changed.settings.endpoint = 'manual.example.com'; f.set_state(changed); f.fault.rollback = false;
	rejects('STALE_RECOVERY', () => f.api.recover()); assert(f.journal() != null, 'journal retained'); f.unchanged();
});
function adoption_fixture() {
 let f=fixture(), n=0;
 for (let p in f.snap.uci_peers) {
  p.section='original'+(++n);
  p.options={ public_key:p.public_key, description:p.name, allowed_ips:clone(p.allowed_ips), preshared_key:f.snap.peers[p.public_key].preshared_key };
 }
 return f;
}
test('existing-peer adoption requires the already-enabled manage gate',()=>{
 let f=adoption_fixture();rejects('READ_ONLY',()=>f.api.manage_existing());assert(f.state()==null&&length(f.changes)==0,'no adoption in monitor');
});
test('existing-peer adoption preserves live state and removes only the original protection',()=>{
 let f=adoption_fixture();f.api.enable(true);let id=f.create(), before=clone(f.snap);
 let result=f.api.manage_existing();assert(result.adopted==3&&result.managed_count==4&&result.protected_count==0,'all three referenced');
 assert(equal(before,f.snap),'no kernel or UCI mutation on adoption');
 let rows=f.api.status().peers;assert(length(filter(rows,p=>p.legacy&&!p.exportable&&!p.protected&&!p.drift))==3,'no original private-key export');
 rejects('NO_PRIVATE_KEY',()=>f.api.export_peer({peer_id:filter(rows,p=>p.legacy)[0].id}));
 assert(f.api.manage_existing().adopted==0,'idempotent');f.unchanged();
});
test('unsupported original routes leave adoption fully unchanged',()=>{
 let f=adoption_fixture();f.api.enable(true);let before=f.state();f.snap.uci_peers[1].allowed_ips=['192.168.66.0/24'];
 rejects('UNSUPPORTED_LEGACY',()=>f.api.manage_existing());assert(equal(f.state(),before)&&length(f.changes)==0,'all-or-nothing');
});
test('duplicate original public keys refuse adoption',()=>{
 let f=adoption_fixture();f.api.enable(true);let before=f.state();push(f.snap.uci_peers,clone(f.snap.uci_peers[0]));
 rejects('UCI_COLLISION',()=>f.api.manage_existing());assert(equal(f.state(),before),'no partial references');
});
test('original runtime differences refuse adoption',()=>{
 let f=adoption_fixture();f.api.enable(true);let before=f.state();f.snap.peers[pk(2)].preshared_key=pk(999);
 rejects('LEGACY_DRIFT',()=>f.api.manage_existing());assert(equal(f.state(),before),'no state change');
});
test('adoption save failure changes no original peer or source configuration',()=>{
 let f=adoption_fixture();f.api.enable(true);let before=f.state(), snap=clone(f.snap);f.fault.save=true;
 rejects('STORAGE_ERROR',()=>f.api.manage_existing());assert(equal(f.state(),before)&&equal(snap,f.snap),'no write on failure');
});

printf('PASS %d policy/transaction tests\n', passed);

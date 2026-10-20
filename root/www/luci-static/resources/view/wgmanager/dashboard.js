'use strict';
'require view';
'require rpc';
'require poll';
'require dom';
'require ui';

/* Status never contains keys. Secret export is a separate ACL-controlled RPC. */
var statusRPC = rpc.declare({ object: 'wgmanager', method: 'status', params: ['interface'] });
var prepareRPC = rpc.declare({ object: 'wgmanager', method: 'prepare', params: ['action', 'peer_id', 'payload', 'interface'] });
var applyRPC = rpc.declare({ object: 'wgmanager', method: 'apply', params: ['token', 'interface'] });
var exportRPC = rpc.declare({ object: 'wgmanager', method: 'export', params: ['peer_id', 'qr', 'interface'] });

function unwrap(reply) {
	if (!reply || reply.ok !== true) {
		var e = new Error(reply && reply.error && reply.error.message || '管理接口返回异常');
		e.code = reply && reply.error && reply.error.code || 'RPC_ERROR';
		throw e;
	}
	return reply.data;
}
function number(v) { v = Number(v); return Number.isFinite(v) && v >= 0 ? v : 0; }
function bytes(v) {
	var n = number(v), u = ['B', 'KiB', 'MiB', 'GiB', 'TiB'], i = 0;
	while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
	return (i ? n.toFixed(n >= 100 ? 0 : n >= 10 ? 1 : 2) : String(Math.round(n))) + ' ' + u[i];
}
function rate(v) { return bytes(v) + '/s'; }
function ageText(age) {
	if (age < 60) return Math.floor(age) + ' 秒前';
	if (age < 3600) return Math.floor(age / 60) + ' 分钟前';
	if (age < 86400) return Math.floor(age / 3600) + ' 小时前';
	return Math.floor(age / 86400) + ' 天前';
}
function peerStatus(p, now) {
	if (p.out_of_pool) return { cls: 'idle', text: '地址需调整', age: '—' };
	if (!p.enabled) return { cls: 'offline', text: '已禁用', age: '—' };
	if (!p.present || p.drift) return { cls: 'idle', text: p.drift ? '状态待检查' : '未在接口中', age: '—' };
	var t = number(p.latest_handshake), age = now - t;
	if (!t) return { cls: 'offline', text: '尚无握手', age: '从未' };
	if (age < 0) return { cls: 'idle', text: '时钟待检查', age: '时间异常' };
	return { cls: age < 180 ? 'active' : age < 600 ? 'idle' : 'offline',
		text: age < 180 ? '近期握手' : age < 600 ? '较久未握手' : '不活跃', age: ageText(age) };
}
function ipOrder(p) {
	var found = (p.ip || '').match(/\b(\d+)\.(\d+)\.(\d+)\.(\d+)\b/);
	return found ? found.slice(1).reduce(function(n, v) { return n * 256 + Number(v); }, 0) : Infinity;
}
function chart(history, direction) {
	var values = history.map(function(s) { return number(s[direction]); }).slice(-24);
	var peak = Math.max.apply(null, [1].concat(values)), bars = [];
	for (var i = 0; i < 24; i++) {
		var value = values[i] || 0;
		bars.push(E('span', { style: 'height:' + Math.max(3, Math.round(value / peak * 100)) + '%', title: rate(value) }));
	}
	return E('div', { 'class': 'wgm-spark ' + direction, 'aria-label': '最近 24 次采样速率' }, bars);
}
function field(label, input, note) {
	return E('label', { 'class': 'wgm-field' }, [E('span', {}, [label]), input,
		note ? E('small', {}, [note]) : '']);
}
function input(value, placeholder) {
	return E('input', { 'class': 'cbi-input-text', type: 'text', value: value || '', placeholder: placeholder || '', autocomplete: 'off' });
}
function listValue(value) { return value.split(/[\s,]+/).filter(Boolean); }
function notify(error) { ui.addNotification(null, E('p', {}, [String(error && error.message || error)]), 'error'); }

return view.extend({
	load: function() {
		var selected = '';
		try { selected = sessionStorage.getItem('wgm.interface') || ''; } catch (e) {}
		return statusRPC(selected).then(unwrap);
	},
	render: function(data) {
		this.last = Object.create(null); this.history = Object.create(null);
		this.search = ''; this.sort = 'address'; this.busy = false; this.peers = [];
		this.target = data.interface || ''; this.requestGeneration = 0; this.dialogOpen = false; this.switching = false;
		this.summary = E('div', { 'class': 'wgm-summary' });
		this.list = E('div', { 'class': 'wgm-clients' });
		this.clientCount = E('span', { 'class': 'wgm-count' });
		this.banner = E('div', { 'class': 'wgm-banner' });
		this.versionBadge = E('span', { 'class': 'wgm-version', 'aria-label': '插件版本' });
		this.live = E('span', { 'class': 'wgm-live' });
		this.info = E('div', { 'class': 'wgm-message', role: 'status' });
		this.newButton = E('button', { 'class': 'btn cbi-button cbi-button-positive',
			click: L.bind(function() { this.editDialog(null); }, this) }, ['＋ 新增客户端']);
		this.settingsButton = E('button', { 'class': 'btn cbi-button',
			click: L.bind(this.settingsDialog, this) }, ['导出设置']);
		this.searchInput = E('input', { 'class': 'cbi-input-text wgm-search', type: 'search',
			placeholder: '搜索名称、公钥或 IP', 'aria-label': '搜索客户端',
			input: L.bind(function(e) { this.search = e.target.value.toLowerCase(); this.drawPeers(); }, this) });
		this.sortInput = E('select', { 'class': 'cbi-input-select wgm-sort', 'aria-label': '排序',
			change: L.bind(function(e) { this.sort = e.target.value; this.drawPeers(); }, this) }, [
			E('option', { value: 'address' }, ['按 IP 排序']), E('option', { value: 'name' }, ['按名称排序']),
			E('option', { value: 'recent' }, ['按最近握手排序']), E('option', { value: 'download' }, ['按下载速度排序'])
		]);
		this.interfaceSelect = E('select', { 'class': 'cbi-input-select wgm-interface-select', 'aria-label': '管理接口',
			change: L.bind(function(e) { this.selectInterface(e.target.value); }, this) });
		this.root = E('div', { 'class': 'wgm-root' }, [
			E('link', { rel: 'stylesheet', href: L.resource('wgmanager/dashboard.css') + '?v=' + encodeURIComponent(data.version || '0.5.0') }),
			E('div', { 'class': 'wgm-head' }, [
				E('div', { 'class': 'wgm-brand' }, [E('div', { 'class': 'wgm-logo', 'aria-hidden': 'true' }, ['WG']),
					E('div', {}, [E('div', { 'class': 'wgm-eyebrow' }, ['NETWORK / VPN']),
						E('div', { 'class': 'wgm-title-row' }, [E('div', { 'class': 'wgm-title', role: 'heading', 'aria-level': '2' }, ['WireGuard']), this.versionBadge]), E('div', { 'class': 'wgm-subtitle' }, ['客户端管理 · iStoreOS'])])]),
				E('div', { 'class': 'wgm-head-actions' }, [E('label', { 'class': 'wgm-interface-picker' }, [E('span', {}, ['接口']), this.interfaceSelect]), this.settingsButton,
					E('button', { 'class': 'btn cbi-button wgm-theme-button',
						click: L.bind(function() { this.root.classList.toggle('wgm-dark'); }, this) }, ['深色 / 浅色'])])
			]), this.summary, this.banner,
			E('section', { 'class': 'wgm-panel', 'aria-label': '客户端管理' }, [
				E('div', { 'class': 'wgm-section-heading' }, [
					E('div', {}, [E('div', { 'class': 'wgm-section-title', role: 'heading', 'aria-level': '3' }, ['客户端', this.clientCount]),
						E('div', { 'class': 'wgm-hint' }, ['每 2 秒刷新 · 状态按最近握手估算'])]), this.newButton]),
				E('div', { 'class': 'wgm-tools' }, [this.searchInput, this.sortInput,
					this.live]),
				E('div', { 'class': 'wgm-columns', 'aria-hidden': 'true' }, [
					E('span', {}, ['名称 / 地址']), E('span', {}, ['实时速率 / 采样累计']), E('span', {}, ['状态 / 操作'])]),
				this.list, this.info]),
			E('div', { 'class': 'wgm-footer' }, [
				'下载指路由器 → 客户端，上传指客户端 → 路由器。采样累计为尽力统计，停机或采样间隔内的计数重置可能遗漏流量。',
				'原客户端私钥不在路由器时，无法恢复二维码或完整配置。'])
		]);
		this.refresh(data);
		poll.add(L.bind(function() {
			if (this.switching) return Promise.resolve();
			var generation = this.requestGeneration;
			return this.reload().catch(L.bind(function(e) {
				if (generation !== this.requestGeneration) return;
				this.last = Object.create(null);
				this.live.className = 'wgm-live wgm-stale';
				dom.content(this.live, [E('span', { 'class': 'wgm-dot' }), '更新暂停']);
				dom.content(this.info, [E('span', { 'class': 'wgm-error' }, ['刷新失败，当前显示为旧数据：' + e.message])]);
			}, this));
		}, this), 2);
		return this.root;
	},
	canManage: function() { return this.data && this.target && this.data.interface === this.target &&
		this.data.mode === 'manage' && this.data.health === 'ok' && !this.busy && !this.switching; },
	showDialog: function(title, content) {
		this.dialogOpen = true; this.interfaceSelect.disabled = true;
		ui.showModal(title, content);
	},
	hideDialog: function() {
		ui.hideModal(); this.dialogOpen = false;
		this.interfaceSelect.disabled = this.busy || this.switching;
	},
	selectInterface: function(name) {
		if (this.busy || this.dialogOpen || !name || name === this.target) { this.interfaceSelect.value = this.target; return; }
		var previous = this.target;
		this.target = name; this.requestGeneration++; this.switching = true; this.busy = true;
		this.refresh(this.data);
		this.reload().then(L.bind(function() {
			this.switching = false; this.busy = false; this.refresh(this.data);
			try { sessionStorage.setItem('wgm.interface', this.target); } catch (e) {}
		}, this)).catch(L.bind(function(e) {
			this.target = previous; this.requestGeneration++; this.switching = false; this.busy = false;
			this.refresh(this.data); notify(e);
		}, this));
	},
	reload: function() {
		var target = this.target, generation = this.requestGeneration;
		return statusRPC(target).then(unwrap).then(L.bind(function(data) {
			if (target === this.target && generation === this.requestGeneration) this.refresh(data);
		}, this));
	},
	refresh: function(data) {
		if (this.data && this.data.interface !== data.interface) {
			this.last = Object.create(null); this.history = Object.create(null);
			this.search = ''; this.searchInput.value = '';
		}
		this.data = data;
		var interfaces = data.interfaces || (data.interface ? [{ name: data.interface, configured: true, up: data.up }] : []);
		var signature = JSON.stringify(interfaces.map(function(item) { return [item.name, item.configured, item.up]; }));
		if (this.target && !interfaces.some(L.bind(function(item) { return item.name === this.target; }, this))) {
			interfaces = interfaces.concat([{ name: this.target, configured: false, up: false }]); signature += this.target;
		}
		if (this.interfaceSignature !== signature) {
			var options = [E('option', { value: '', disabled: true }, [interfaces.length ? '请选择接口' : '未发现接口'])];
			interfaces.forEach(function(item) { options.push(E('option', { value: item.name }, [item.name +
				(!item.configured ? '（无原生配置）' : item.up ? ' · 运行中' : ' · 未运行')])); });
			dom.content(this.interfaceSelect, options); this.interfaceSignature = signature;
		}
		this.interfaceSelect.value = this.target;
		this.interfaceSelect.disabled = this.busy || this.switching || this.dialogOpen;
		if (this.addressNote && this.addressNote.isConnected) dom.content(this.addressNote, [(data.network ? data.network.hint : '请先配置所选接口的 IPv4 地址') + '；留空按上方网段顺序分配，避开原有和禁用客户端']);
		if (this.routeModeField && this.routeModeField.isConnected && this.routeModeField.value === 'auto') this.autoRoutesField.value = (data.default_routes || []).join(', ');
		dom.content(this.versionBadge, [data.version ? 'v' + data.version : '版本未知']);
		this.live.className = 'wgm-live';
		dom.content(this.live, [E('span', { 'class': 'wgm-dot' }), '每 2 秒更新']);
		var now = performance.now(), active = 0, rx = 0, tx = 0;
		this.peers = (data.peers || []).map(L.bind(function(p) {
			p.status = peerStatus(p, data.timestamp);
			var old = this.last[p.public_key], r = number(p.transfer_rx), t = number(p.transfer_tx);
			var dt = old ? (now - old.time) / 1000 : 0;
			p.upload = p.status.cls === 'active' && old && dt > 0 && dt <= 15 && r >= old.rx ? (r - old.rx) / dt : 0;
			p.download = p.status.cls === 'active' && old && dt > 0 && dt <= 15 && t >= old.tx ? (t - old.tx) / dt : 0;
			this.last[p.public_key] = { rx: r, tx: t, time: now };
			var history = p.status.cls === 'active' ? (this.history[p.public_key] || []) : [];
			history.push({ up: p.upload, down: p.download });
			this.history[p.public_key] = history.slice(-24);
			p.ip = (p.allowed_ips || []).join(', ');
			if (p.status.cls === 'active') active++;
			rx += number(p.total_rx); tx += number(p.total_tx);
			return p;
		}, this));
		// Remove deleted peers' browser samples and keep memory bounded.
		Object.keys(this.last).forEach(L.bind(function(k) {
			if (!this.peers.some(function(p) { return p.public_key === k; })) { delete this.last[k]; delete this.history[k]; }
		}, this));
		var protectedCount = this.peers.filter(function(p) { return p.protected; }).length;
		var mode = data.mode === 'manage' ? '管理阶段' : '只读阶段';
		var banner = mode + ' · ' + (data.existing_management ? '已开放原有客户端管理，操作会同步保存对应配置。' : protectedCount + ' 个既有客户端受保护。');
		if (data.mode !== 'manage' && data.interface) banner += ' 在 SSH 执行 wgmanager --interface ' + data.interface + ' enable-management 后，可新增并管理此接口客户端。';
		if (data.selection_required) banner = data.message;
		var outside = this.peers.filter(function(p) { return p.out_of_pool; }).length;
		if (outside) banner += ' ' + outside + ' 个客户端仍在旧网段，请编辑地址并同步客户端配置。';
		if (data.message && !data.selection_required) banner += ' ' + data.message;
		this.banner.className = 'wgm-banner' + (data.health !== 'ok' || outside ? ' wgm-warning' : '');
		dom.content(this.banner, [banner]);
		dom.content(this.clientCount, [String(this.peers.length)]);
		dom.content(this.summary, [this.metric('WIREGUARD 接口', (data.interface || '未选择') + (data.interface ? data.up ? ' · 运行中' : ' · 未运行' : ''), (data.network && data.network.server_address ? (data.network.server_addresses || [data.network.server_address]).join('、') + (data.network.available ? '' : '（默认，未配置）') + ' · ' : '') + (data.listen_port ? 'UDP ' + data.listen_port : '请先选择并启用接口')),
			this.metric('客户端', this.peers.length + ' 台', active + ' 台近期握手'),
			this.metric('采样累计下载', bytes(tx), '路由器 → 客户端'), this.metric('采样累计上传', bytes(rx), '客户端 → 路由器')]);
		this.newButton.disabled = !this.canManage(); this.settingsButton.disabled = !this.canManage();
		this.drawPeers();
		dom.content(this.info, ['最后更新：' + new Date(number(data.timestamp) * 1000).toLocaleTimeString() + ' · ' +
			(data.stats && data.stats.collector ? '后台每 10 秒采样，每 15 分钟保存累计' : '后台采样未启动，仅页面打开或手动采样时更新累计')]);
	},
	metric: function(label, value, note) {
		return E('div', { 'class': 'wgm-metric' }, [E('div', { 'class': 'wgm-metric-label' }, [label]),
			E('div', { 'class': 'wgm-metric-value' }, [value]), E('div', { 'class': 'wgm-metric-note' }, [note])]);
	},
	drawPeers: function() {
		var q = this.search, sort = this.sort;
		var peers = this.peers.filter(function(p) { return !q || (p.name + ' ' + p.ip + ' ' + p.public_key).toLowerCase().indexOf(q) >= 0; });
		peers.sort(function(a, b) {
			if (sort === 'name') return a.name.localeCompare(b.name);
			if (sort === 'recent') return number(b.latest_handshake) - number(a.latest_handshake);
			if (sort === 'download') return b.download - a.download;
			return ipOrder(a) - ipOrder(b) || a.name.localeCompare(b.name);
		});
		dom.content(this.list, peers.length ? peers.map(L.bind(this.peerCard, this)) :
			[E('div', { 'class': 'wgm-empty' }, [this.peers.length ? '没有匹配的客户端' : '当前没有可显示的客户端，插件不会自动创建或启动接口'])]);
	},
	peerCard: function(p) {
		var buttons = [E('button', { 'class': 'btn cbi-button wgm-details', click: L.bind(function() { this.details(p); }, this) }, ['详情'])];
		if (p.managed) {
			if (p.exportable !== false) buttons.push(E('button', { 'class': 'btn cbi-button wgm-details', disabled: this.busy || null,
				click: L.bind(function() { this.secretDialog(p); }, this) }, ['二维码 / 配置']));
			buttons.push(E('button', { 'class': 'btn cbi-button wgm-details', disabled: (!this.canManage() || p.drift) || null,
				click: L.bind(function() { this.editDialog(p); }, this) }, ['编辑']));
			buttons.push(E('button', { 'class': 'btn cbi-button wgm-details', disabled: (!this.canManage() || p.drift) || null,
				click: L.bind(function() { this.preview(p.enabled ? 'disable' : 'enable', p.id, {}); }, this) }, [p.enabled ? '禁用' : '启用']));
			buttons.push(E('button', { 'class': 'btn cbi-button wgm-danger', disabled: (!this.canManage() || p.drift) || null,
				click: L.bind(function() { this.preview('delete', p.id, {}); }, this) }, ['删除']));
		}
		var initials = Array.from(p.name || 'WG').slice(0, 2).join('').toUpperCase();
		return E('article', { 'class': 'wgm-peer' + (!p.enabled ? ' wgm-disabled' : '') }, [
			E('div', { 'class': 'wgm-peer-main' }, [E('div', { 'class': 'wgm-avatar', 'aria-hidden': 'true' }, [initials]),
				E('div', { 'class': 'wgm-peer-text' }, [E('div', { 'class': 'wgm-name' }, [p.name]),
					E('div', { 'class': 'wgm-ip' }, [p.ip || '无 AllowedIPs']),
					E('span', { 'class': 'wgm-ownership' }, [p.protected ? '受保护 · 原有配置' : p.legacy ? '原有客户端 · 可管理' : '插件管理'])])]),
			E('div', { 'class': 'wgm-traffic' }, [
				E('div', { 'class': 'wgm-speed' }, [E('div', { 'class': 'wgm-speed-label' }, ['↓ 下载']),
					E('div', { 'class': 'wgm-speed-value' }, [rate(p.download)]), chart(this.history[p.public_key] || [], 'down'),
					E('div', { 'class': 'wgm-total' }, ['累计 ' + bytes(p.total_tx)])]),
				E('div', { 'class': 'wgm-speed' }, [E('div', { 'class': 'wgm-speed-label' }, ['↑ 上传']),
					E('div', { 'class': 'wgm-speed-value' }, [rate(p.upload)]), chart(this.history[p.public_key] || [], 'up'),
					E('div', { 'class': 'wgm-total' }, ['累计 ' + bytes(p.total_rx)])])]),
			E('div', { 'class': 'wgm-peer-controls' }, [
				E('div', { 'class': 'wgm-status-line' }, [
					E('span', { 'class': 'wgm-peer-state ' + p.status.cls }, [E('span', { 'class': 'wgm-dot' }), p.status.text]),
					E('span', { 'class': 'wgm-handshake' }, ['握手 ' + p.status.age])]),
				E('div', { 'class': 'wgm-actions', 'aria-label': p.name + '的操作' }, buttons)])
		]);
	},
	details: function(p) {
		if (this.busy || this.switching) return;
		this.showDialog('客户端详情', [E('p', {}, ['接口：' + this.target]), E('p', {}, ['名称：' + p.name]), E('p', {}, ['地址：' + p.ip]),
			p.out_of_pool ? E('p', { 'class': 'wgm-error' }, ['地址不属于所选接口的任何 IPv4 网段；编辑后同步客户端设备地址或重新导入配置。']) : '',
			E('p', {}, ['公钥：', E('code', { 'class': 'wgm-break' }, [p.public_key])]), E('p', {}, ['端点：' + (p.endpoint || '尚无')]),
			E('p', {}, ['握手：' + p.status.age]),
			E('p', {}, ['本次接口流量：↓ ' + bytes(p.transfer_tx) + ' / ↑ ' + bytes(p.transfer_rx)]), E('p', {}, [p.protected ?
				'此客户端尚未接管，请在 SSH 使用 --interface 指定此接口，再执行 manage-existing。' : p.legacy ? '原有客户端已接管；私钥不在路由器，无法生成二维码或完整客户端配置。编辑、启停和删除会同步保存对应配置。' : '配置文件及二维码含客户端私钥，请妥善保存。']),
			E('div', { 'class': 'right' }, [E('button', { 'class': 'btn cbi-button', click: L.bind(this.hideDialog, this) }, ['关闭'])])]);
	},
	editDialog: function(p) {
		if (!this.canManage()) return;
		var name = input(p ? p.name : '', '例如：iPhone'), address = input(p ? p.allowed_ips[0].split('/')[0] : '', '留空自动分配');
		name.maxLength = 96;
		var addressField = field('客户端 IPv4 地址', address, (this.data.network ? this.data.network.hint : '请先配置并启用所选接口的 IPv4 地址') + '；留空按上方网段顺序分配，避开原有和禁用客户端');
		this.addressNote = addressField.querySelector('small');
		this.showDialog(p ? '编辑客户端' : '新增客户端', [field('名称', name),
			addressField,
			p && p.out_of_pool ? E('p', { 'class': 'wgm-error' }, ['此客户端仍在旧网段，请填写上方当前范围内的新地址；保存后同步客户端设备。']) : '',
			E('div', { 'class': 'wgm-dialog-actions right' }, [E('button', { 'class': 'btn cbi-button', click: L.bind(this.hideDialog, this) }, ['取消']),
				E('button', { 'class': 'btn cbi-button cbi-button-positive', click: L.bind(function() {
					this.preview(p ? 'edit' : 'create', p ? p.id : '', { name: name.value.trim(), address: address.value.trim() });
				}, this) }, ['预览变更'])])]);
	},
	settingsDialog: function() {
		if (!this.canManage()) return;
		var s = this.data.settings, host = input(s.endpoint, 'vpn.example.com'), dns = input(s.dns.join(', '), '可留空');
		var routes = input(s.routes.join(', ')), keepalive = input(String(s.keepalive));
		var routeMode = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { value: 'auto' }, ['自动跟随所选接口与 LAN 网段']), E('option', { value: 'custom' }, ['自定义路由'])]);
		routeMode.value = s.routes_mode || 'custom';
		var customRoutes = routes.value;
		routes.addEventListener('input', function() { if (!routes.disabled) customRoutes = routes.value; });
		var updateRoutes = L.bind(function() {
			routes.disabled = routeMode.value === 'auto';
			routes.value = routes.disabled ? (this.data.default_routes || []).join(', ') : customRoutes;
		}, this);
		routeMode.addEventListener('change', updateRoutes); updateRoutes();
		this.routeModeField = routeMode; this.autoRoutesField = routes;
		keepalive.type = 'number'; keepalive.min = 0; keepalive.max = 65535;
		this.showDialog('客户端导出设置', [field('公网域名或 IPv4', host, '不带协议或端口；导出使用接口 ' + this.data.interface + ' 的 UDP ' + this.data.listen_port),
			field('客户端 DNS', dns, 'IPv4 地址，用逗号分隔；留空沿用客户端原 DNS'),
			field('客户端路由模式', routeMode, '自动模式使用所选接口的全部 IPv4 网段和 LAN 网段；已有手动设置在升级后保留为自定义'),
			field('客户端 AllowedIPs', routes, '自动模式随接口变化；自定义可填写 0.0.0.0/0 让全部 IPv4 走 VPN，需服务端支持转发'),
			field('PersistentKeepalive（秒）', keepalive, '默认 25；只写入下载的客户端配置'),
			E('p', {}, ['保存后只影响之后的配置下载。已导入的客户端须重新导入才能采用新设置。']),
			E('div', { 'class': 'wgm-dialog-actions right' }, [E('button', { 'class': 'btn cbi-button', click: L.bind(this.hideDialog, this) }, ['取消']),
				E('button', { 'class': 'btn cbi-button cbi-button-positive', click: L.bind(function() {
					this.preview('settings', '', { endpoint: host.value.trim(), dns: listValue(dns.value),
						routes: listValue(routes.value), routes_mode: routeMode.value, keepalive: Number(keepalive.value) });
				}, this) }, ['预览保存'])])]);
	},
	preview: function(action, id, payload) {
		if (!this.canManage()) return;
		var target = this.target;
		this.busy = true; this.refresh(this.data);
		prepareRPC(action, id, JSON.stringify(payload), target).then(unwrap).then(L.bind(function(plan) {
			this.busy = false; this.refresh(this.data);
			var summary = plan.summary, submitted = false;
			var confirm = E('button', { 'class': 'btn cbi-button ' + (action === 'delete' ? 'cbi-button-negative' : 'cbi-button-positive'),
				click: L.bind(function() {
					if (submitted || this.busy || target !== this.target) return;
					submitted = true; this.busy = true; confirm.disabled = true;
					applyRPC(plan.token, target).then(unwrap).then(L.bind(function(result) {
						this.hideDialog(); this.busy = false;
						return this.reload().then(L.bind(function() {
							if (action === 'create') {
								var peer = this.peers.find(function(p) { return p.id === result.peer_id; });
								if (peer && this.data.settings.endpoint) this.secretDialog(peer);
								else ui.addNotification(null, E('p', {}, ['客户端已创建。请填写导出设置中的公网域名，再下载配置。']), 'info');
							}
						}, this));
					}, this)).catch(L.bind(function(e) {
						this.busy = false; this.hideDialog(); notify(e); this.reload().catch(notify);
					}, this));
				}, this) }, ['确认执行']);
			var content = [E('p', {}, ['操作接口：' + (summary.interface || target)]), E('p', {}, [summary.detail])];
			if (summary.name) content.push(E('p', {}, ['客户端：' + summary.name]));
			if (summary.address) content.push(E('p', {}, ['地址：' + summary.address + '/32']));
			if (action === 'delete') content.push(E('p', { 'class': 'wgm-error' }, ['删除会移除所选客户端的授权和持久配置。请先保留该客户端的原配置文件。']));
			content.push(E('p', {}, ['预览有效期 60 秒。操作只针对所选客户端，提交前请核对名称与地址。']),
				E('div', { 'class': 'wgm-dialog-actions right' }, [E('button', { 'class': 'btn cbi-button', click: L.bind(this.hideDialog, this) }, ['取消']), confirm]));
			this.showDialog(summary.title, content);
		}, this)).catch(L.bind(function(e) { this.busy = false; this.refresh(this.data); notify(e); }, this));
	},
	secretDialog: function(p) {
		if (!p.managed || p.exportable === false || this.busy) return;
		this.busy = true;
		exportRPC(p.id, true, this.target).then(unwrap).then(L.bind(function(result) {
			this.busy = false;
			var text = E('textarea', { 'class': 'wgm-secret', readonly: true, rows: 12, spellcheck: false, 'aria-label': '客户端配置，含私钥' });
			text.value = result.config;
			var image = E('img', { 'class': 'wgm-qr', alt: 'WireGuard 客户端配置二维码，含私钥',
				src: 'data:image/svg+xml;base64,' + btoa(result.qr_svg) });
			var filename = result.filename;
			result.config = ''; result.qr_svg = '';
			var close = L.bind(function() { text.value = ''; image.removeAttribute('src'); this.hideDialog(); }, this);
			this.showDialog(p.name + ' · 配置', [E('p', {}, ['二维码和文件含此客户端私钥。请勿公开分享。' + (result.disabled ? ' 此客户端当前已禁用。' : '')]),
				image, text, E('div', { 'class': 'wgm-dialog-actions right' }, [
					E('button', { 'class': 'btn cbi-button', click: close }, ['关闭']),
					E('button', { 'class': 'btn cbi-button cbi-button-positive', click: function() {
						var blob = new Blob([text.value], { type: 'text/plain;charset=utf-8' });
						var url = URL.createObjectURL(blob), a = document.createElement('a');
						a.href = url; a.download = filename; document.body.appendChild(a); a.click(); a.remove();
						setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
					} }, ['下载 .conf'])])]);
		}, this)).catch(L.bind(function(e) { this.busy = false; notify(e); }, this));
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});

"use strict";
'require view';
'require rpc';
'require poll';
'require dom';
'require ui';

/* This dashboard only calls the existing OpenWrt luci.wireguard status RPC.
 * It never reads private keys or invokes wg set, UCI writes or network reloads. */

var getInstances = rpc.declare({
    object: 'luci.wireguard',
    method: 'getWgInstances'
});

function numberValue(v) {
    var n = Number(v);
    return isFinite(n) && n >= 0 ? n : 0;
}

function bytes(v) {
    var n = numberValue(v), units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    while (n >= 1024 && i < units.length - 1) {
        n /= 1024;
        i++;
    }
    return (i === 0 ? String(Math.round(n)) : n.toFixed(n >= 100 ? 0 : n >= 10 ? 1 : 2)) + ' ' + units[i];
}

function rate(v) {
    return bytes(v) + '/s';
}

function shortKey(s) {
    s = String(s || '');
    return s.length > 20 ? s.slice(0, 9) + '…' + s.slice(-7) : s;
}

function handshakeStatus(v) {
    var t = numberValue(v), age = Date.now() / 1000 - t;
    if (!t || age < 0) return { cls: 'offline', text: '尚无握手', age: '从未' };
    if (age < 180) return { cls: 'active', text: '近期握手', age: ageText(age) };
    if (age < 600) return { cls: 'idle', text: '较久未握手', age: ageText(age) };
    return { cls: 'offline', text: '不活跃', age: ageText(age) };
}

function ageText(age) {
    if (age < 60) return Math.floor(age) + ' 秒前';
    if (age < 3600) return Math.floor(age / 60) + ' 分钟前';
    if (age < 86400) return Math.floor(age / 3600) + ' 小时前';
    return Math.floor(age / 86400) + ' 天前';
}

function sparkline(samples, direction) {
    var vals = (samples || []).slice(-24).map(function(s) { return numberValue(s[direction]); });
    var max = Math.max.apply(null, [1].concat(vals));
    var bars = [];
    for (var i = 0; i < 24; i++) {
        var val = vals[i] || 0;
        var height = Math.max(8, Math.round(val / max * 100));
        bars.push(E('span', { 'style': 'height:' + height + '%', 'title': rate(val) }));
    }
    return E('div', { 'class': 'wgm-spark ' + direction, 'aria-label': '最近流量速率柱状图' }, bars);
}

return view.extend({
    load: function() {
        return getInstances();
    },

    render: function(data) {
        this.search = '';
        this.sort = 'address';
        this.history = {};
        this.last = {};
        this.peers = [];
        this.summary = E('div', { 'class': 'wgm-summary' });
        this.list = E('div', { 'class': 'wgm-clients' });
        this.info = E('div', { 'class': 'wgm-message' }, ['正在读取 WireGuard 状态…']);
        this.searchInput = E('input', {
            'class': 'cbi-input-text wgm-search',
            'type': 'search',
            'placeholder': '搜索客户端名称、公钥或 IP',
            'input': L.bind(function(ev) {
                this.search = String(ev.target.value || '').toLowerCase();
                this.drawPeers();
            }, this)
        });
        this.sortInput = E('select', {
            'class': 'cbi-input-select wgm-sort',
            'change': L.bind(function(ev) {
                this.sort = ev.target.value;
                this.drawPeers();
            }, this)
        }, [
            E('option', { 'value': 'address' }, ['按 IP 排序']),
            E('option', { 'value': 'name' }, ['按名称排序']),
            E('option', { 'value': 'recent' }, ['按最近握手排序']),
            E('option', { 'value': 'download' }, ['按下载速度排序'])
        ]);
        var root = E('div', { 'class': 'wgm-root' }, [
            E('link', { 'rel': 'stylesheet', 'href': L.resource('wgmanager/dashboard.css') }),
            E('div', { 'class': 'wgm-head' }, [
                E('div', {}, [
                    E('div', { 'class': 'wgm-eyebrow' }, ['iStoreOS · WireGuard']),
                    E('h2', {}, ['WireGuard Manager']),
                    E('div', { 'class': 'wgm-subtitle' }, ['使用现有 wg 内核接口 · 自动刷新 · 只读监控版'])
                ]),
                E('div', { 'class': 'wgm-head-actions' }, [
                    E('a', { 'class': 'btn cbi-button wgm-config', 'href': L.url('admin/network/network') }, ['前往接口配置']),
                    E('button', {
                        'class': 'btn cbi-button wgm-theme-button',
                        'click': function() { root.classList.toggle('wgm-dark'); }
                    }, ['深色 / 浅色'])
                ])
            ]),
            this.summary,
            E('div', { 'class': 'wgm-section-heading' }, [
                E('div', {}, [E('h3', {}, ['客户端']), E('div', { 'class': 'wgm-hint' }, ['每 2 秒采样 · 不改变 WireGuard 配置'])]),
                E('div', { 'class': 'wgm-tools' }, [this.searchInput, this.sortInput])
            ]),
            this.list,
            this.info,
            E('div', { 'class': 'wgm-footer' }, [
                '状态按握手时间估算，不代表设备永久在线。客户端「下载」是从路由器到客户端，',
                '「上传」是从客户端到路由器。旧客户端私钥不能从服务器恢复；本版不提供创建、删除或二维码。'
            ])
        ]);
        this.root = root;
        this.refresh(data);
        poll.add(L.bind(function() {
            return getInstances().then(L.bind(this.refresh, this)).catch(L.bind(function(err) {
                dom.content(this.info, [E('span', { 'class': 'wgm-error' }, [
                    '状态更新失败：' + String(err && err.message || err)
                ])]);
            }, this));
        }, this), 2);
        return root;
    },

    refresh: function(data) {
        var wg = data && data.wg;
        if (!wg) {
            dom.content(this.summary, []);
            dom.content(this.list, [E('div', { 'class': 'wgm-empty' }, ['当前未检测到正在运行的 wg 接口。'])]);
            dom.content(this.info, ['请检查 wg show wg 和 LuCI WireGuard 状态页。']);
            this.peers = [];
            return;
        }
        var now = Date.now();
        var activeCount = 0, totalRx = 0, totalTx = 0;
        var peers = (wg.peers || []).map(L.bind(function(peer) {
            var key = String(peer.public_key || '');
            var rx = numberValue(peer.transfer_rx), tx = numberValue(peer.transfer_tx);
            var old = this.last[key];
            var dt = old ? Math.max(0.001, (now - old.time) / 1000) : 0;
            var upload = old && dt && rx >= old.rx ? (rx - old.rx) / dt : 0;
            var download = old && dt && tx >= old.tx ? (tx - old.tx) / dt : 0;
            this.last[key] = { rx: rx, tx: tx, time: now };
            if (!this.history[key]) this.history[key] = [];
            this.history[key].push({ up: upload, down: download });
            if (this.history[key].length > 24) this.history[key].shift();
            var status = handshakeStatus(peer.latest_handshake);
            if (status.cls === 'active') activeCount++;
            totalRx += rx;
            totalTx += tx;
            return {
                key: key, name: peer.name || ('客户端 ' + (peer.allowed_ips || []).join(', ') || '未命名'),
                ip: (peer.allowed_ips || []).join(', ') || '未分配 IP',
                endpoint: peer.endpoint || '(none)', rx: rx, tx: tx, upload: upload,
                download: download, handshake: numberValue(peer.latest_handshake), status: status
            };
        }, this));
        this.peers = peers;
        dom.content(this.summary, [
            this.summaryCard('接口状态', 'wg · 运行中', 'UDP ' + (wg.listen_port || '—')),
            this.summaryCard('客户端', String(peers.length) + ' 台', activeCount + ' 台近期握手'),
            this.summaryCard('总下载', bytes(totalTx), 'iStoreOS → 客户端'),
            this.summaryCard('总上传', bytes(totalRx), '客户端 → iStoreOS')
        ]);
        this.drawPeers();
        dom.content(this.info, ['最后更新：' + (new Date(now)).toLocaleTimeString() + ' · 自动刷新中']);
    },

    summaryCard: function(label, value, note) {
        return E('div', { 'class': 'wgm-metric' }, [
            E('div', { 'class': 'wgm-metric-label' }, [label]),
            E('div', { 'class': 'wgm-metric-value' }, [value]),
            E('div', { 'class': 'wgm-metric-note' }, [note])
        ]);
    },

    drawPeers: function() {
        var q = this.search, peers = this.peers.filter(function(p) {
            return !q || (p.name + ' ' + p.ip + ' ' + p.key + ' ' + p.endpoint).toLowerCase().indexOf(q) !== -1;
        });
        var sort = this.sort;
        peers.sort(function(a, b) {
            if (sort === 'name') return a.name.localeCompare(b.name);
            if (sort === 'recent') return b.handshake - a.handshake;
            if (sort === 'download') return b.download - a.download;
            var ipA = parseInt((a.ip.match(/\d+$/) || [])[0], 10) || 0;
            var ipB = parseInt((b.ip.match(/\d+$/) || [])[0], 10) || 0;
            return ipA - ipB;
        });
        if (!peers.length) {
            dom.content(this.list, [E('div', { 'class': 'wgm-empty' }, ['没有匹配的客户端'])]);
            return;
        }
        dom.content(this.list, peers.map(L.bind(this.peerCard, this)));
    },

    peerCard: function(p) {
        var history = this.history[p.key] || [];
        var details = E('button', {
            'class': 'btn cbi-button wgm-details',
            'click': L.bind(function() {
                ui.showModal('客户端详情', [
                    E('p', {}, ['名称：' + p.name]),
                    E('p', {}, ['地址：' + p.ip]),
                    E('p', {}, ['公钥：', E('code', { 'class': 'wgm-break' }, [p.key])]),
                    E('p', {}, ['端点：' + p.endpoint]),
                    E('p', {}, ['最后握手：' + p.status.age]),
                    E('p', {}, ['累计下载：' + bytes(p.tx)]),
                    E('p', {}, ['累计上传：' + bytes(p.rx)]),
                    E('div', { 'class': 'right' }, [
                        E('button', { 'class': 'btn cbi-button', 'click': ui.hideModal }, ['关闭'])
                    ])
                ]);
            }, this)
        }, ['详情']);
        return E('div', { 'class': 'wgm-peer' }, [
            E('div', { 'class': 'wgm-peer-main' }, [
                E('div', { 'class': 'wgm-avatar' }, ['●']),
                E('div', { 'class': 'wgm-peer-text' }, [
                    E('div', { 'class': 'wgm-name' }, [p.name]),
                    E('div', { 'class': 'wgm-ip' }, [p.ip]),
                    E('div', { 'class': 'wgm-key' }, [shortKey(p.key)])
                ]),
                E('div', { 'class': 'wgm-peer-state ' + p.status.cls }, [
                    E('span', { 'class': 'wgm-dot' }),
                    p.status.text
                ])
            ]),
            E('div', { 'class': 'wgm-peer-bottom' }, [
                E('div', { 'class': 'wgm-speed' }, [
                    E('div', { 'class': 'wgm-speed-label' }, ['↓ 客户端下载']),
                    E('div', { 'class': 'wgm-speed-value' }, [rate(p.download)]),
                    sparkline(history, 'down'),
                    E('div', { 'class': 'wgm-total' }, ['累计 ' + bytes(p.tx)])
                ]),
                E('div', { 'class': 'wgm-speed' }, [
                    E('div', { 'class': 'wgm-speed-label' }, ['↑ 客户端上传']),
                    E('div', { 'class': 'wgm-speed-value' }, [rate(p.upload)]),
                    sparkline(history, 'up'),
                    E('div', { 'class': 'wgm-total' }, ['累计 ' + bytes(p.rx)])
                ]),
                E('div', { 'class': 'wgm-peer-extra' }, [
                    E('div', {}, ['握手：' + p.status.age]),
                    details
                ])
            ])
        ]);
    },

    handleSaveApply: null,
    handleSave: null,
    handleReset: null
});

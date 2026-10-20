#!/usr/bin/env python3
"""Inspect the actual release artifact and its reproducibility/safety envelope."""
import importlib.util
import io
from pathlib import Path, PurePosixPath
import json
import tarfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('wgm_build', ROOT/'scripts/build_ipk.py')
build = importlib.util.module_from_spec(spec); spec.loader.exec_module(build)
count = 0


def check(ok, label):
    global count
    assert ok, label
    count += 1
    print(f'ok {count} - {label}')


target = build.build()
first = target.read_bytes()
build.build()
check(target.read_bytes() == first, 'IPK rebuild is byte-for-byte deterministic')
check(first.startswith(b'\x1f\x8b'), 'OpenWrt gzip/tar IPK envelope')
with tarfile.open(fileobj=io.BytesIO(first), mode='r:gz') as outer:
    names = {m.name.removeprefix('./') for m in outer.getmembers()}
    check(names == {'debian-binary','control.tar.gz','data.tar.gz'}, 'exactly three IPK envelope members')
    def member(name):
        return next(m for m in outer.getmembers() if m.name.removeprefix('./') == name)
    check(outer.extractfile(member('debian-binary')).read() == b'2.0\n', 'debian-binary marker is correct')
    control_bytes = outer.extractfile(member('control.tar.gz')).read()
    data_bytes = outer.extractfile(member('data.tar.gz')).read()

with tarfile.open(fileobj=io.BytesIO(control_bytes), mode='r:gz') as control:
    members = {m.name.removeprefix('./'):m for m in control.getmembers()}
    check(set(members) == {'control','prerm'}, 'no preinst, postinst or postrm scripts')
    text = control.extractfile(members['control']).read().decode()
    check('Package: luci-app-wgmanager\n' in text and f'Version: {build.VERSION}\n' in text and 'Architecture: all\n' in text, 'package name/version/architecture match release')
    depends = next(line.split(': ',1)[1] for line in text.splitlines() if line.startswith('Depends:'))
    check(set(depends.split(', ')) == set(build.DEPENDS), 'all target runtime dependencies declared')
    prerm = control.extractfile(members['prerm']).read().decode()
    check('/etc/init.d/wgmanager stop' in prerm and all(x not in prerm for x in ['/etc/init.d/network','/etc/init.d/firewall','wg set','ifdown','ifup']), 'remove script stops only this plugin sampler')
    check(members['prerm'].mode == 0o755, 'remove script has executable mode')

with tarfile.open(fileobj=io.BytesIO(data_bytes), mode='r:gz') as data:
    all_members = data.getmembers()
    check(all(not m.name.startswith('/') and '..' not in PurePosixPath(m.name).parts and not m.issym() and not m.islnk() for m in all_members), 'no path traversal or linked payload files')
    files = {m.name.removeprefix('./'):m for m in all_members}
    check('etc/config/network' not in files and 'etc/config/firewall' not in files and not any(p.startswith('etc/config/') for p in files), 'no network/firewall/UCI configuration payload')
    check(files['etc/wgmanager'].mode == 0o700, 'installed private data directory is 0700')
    check(all(files[p].mode == 0o755 for p in build.EXECUTABLES), 'all RPC, CLI, init and hotplug executables have correct modes')
    def read(path): return data.extractfile(files[path]).read().decode()
    acl = json.loads(read('usr/share/rpcd/acl.d/luci-app-wgmanager.json'))
    check(acl['luci-app-wgmanager']['read']['ubus'] == {'wgmanager':['status']}, 'status ACL grants only the filtered status method')
    check(acl['luci-app-wgmanager-secrets']['write']['ubus'] == {'wgmanager':['export']}, 'secret export requires separate write ACL')
    check(not any(x in json.dumps(acl) for x in ['"*"','"file"','"uci"','"exec"']), 'ACL grants no wildcard, file, UCI or generic execution methods')
    platform = read('usr/share/wgmanager/platform.uc')
    writer = platform.split('function change_uci_peer(',1)[1].split('function snapshot()',1)[0]
    readonly = platform.split('function change_uci_peer(',1)[0] + platform.split('function snapshot()',1)[1]
    check(all(x not in readonly for x in ['ctx.set(', 'ctx.commit(', 'ctx.save(', 'ctx.delete(']) and "ctx.set('network', section, name, next.uci_options[name])" in writer and "ctx.commit('network')" in writer and 'valid_section(section)' in writer and "current['.type'] != 'wireguard_' + IFACE" in writer, 'UCI writes are isolated to a validated selected WireGuard peer section')
    check("[wg, 'set', IFACE, 'peer', pub]" in platform and all(x not in platform for x in ["'setconf'", "'syncconf'", "'ifup'", "'ifdown'", "'nft'", "'iptables'"]), 'live updates use a single peer, with no interface/firewall reset commands')
    hook = read('etc/hotplug.d/iface/95-wgmanager')
    check('[ "$ACTION" = ifup ]' in hook and '--interface "$INTERFACE" restore' in hook, 'hotplug restores only the interface named by the native ifup event')
    check('/etc/wgmanager/' in read('lib/upgrade/keep.d/wgmanager'), 'private plugin state is included in normal sysupgrade preservation')

print(f'PASS {count} package/archive/safety checks; target opkg installation not yet verified')

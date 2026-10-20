#!/usr/bin/env python3
"""Real ucode + libuci/fs integration, real wg keygen and qrencode; mock kernel only.

No network interface is created. All router paths are replaced by a temporary tree.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
UCODE = Path(os.environ['WGM_TEST_UCODE']).resolve()
MODULES = os.environ['WGM_TEST_MODULES']
REAL_WG = str(Path(os.environ['WGM_TEST_WG']).resolve())
QRENCODE = str(Path(os.environ['WGM_TEST_QRENCODE']).resolve())
ENV = dict(os.environ)
BASE_CMD = [str(UCODE), '-L', MODULES, str(ROOT/'tests/platform_driver.uc')]
checks = []


def check(value, name):
    assert value, name
    checks.append(name)
    print(f'ok {len(checks)} - {name}')


def gen():
    private = subprocess.check_output([REAL_WG, 'genkey'], env=ENV).decode().strip()
    public = subprocess.check_output([REAL_WG, 'pubkey'], input=(private+'\n').encode(), env=ENV).decode().strip()
    psk = subprocess.check_output([REAL_WG, 'genpsk'], env=ENV).decode().strip()
    return private, public, psk


with tempfile.TemporaryDirectory(prefix='wgmanager-platform-') as tmp:
    base = Path(tmp)
    conf = base/'config'; conf.mkdir(mode=0o700)
    server_private, server_public, _ = gen()
    peers = {}
    sections = [f"# Must remain byte-identical: 原配置\nconfig interface 'wg'\n\toption proto 'wireguard'\n\toption private_key '{server_private}'\n\toption listen_port '51820'\n\tlist addresses '192.168.66.1/24'\n"]
    for i in range(2, 5):
        _, public, psk = gen()
        peers[public] = {'preshared_key': psk, 'endpoint': '203.0.113.8:45000',
                         'allowed_ips': [f'192.168.66.{i}/32'], 'latest_handshake': 1700000000,
                         'transfer_rx': i*1000, 'transfer_tx': i*2000, 'persistent_keepalive': 0}
        sections.append(f"config wireguard_wg\n\toption description '旧客户端 {i}'\n\toption public_key '{public}'\n\toption preshared_key '{psk}'\n\tlist allowed_ips '192.168.66.{i}/32'\n")
    sections.append("config interface 'tailscale'\n\toption proto 'none'\n\toption device 'tailscale0'\n# OpenClash/Lucky placeholders are never passed to any writer.\n")
    network = conf/'network'; original_bytes = '\n'.join(sections).encode(); network.write_bytes(original_bytes)
    original_peers = json.loads(json.dumps(peers))
    kernel = {'server_private': server_private, 'server_public': server_public, 'peers': peers}
    (base/'kernel.json').write_text(json.dumps(kernel))
    mock = base/'mock-wg'
    mock.write_text('''#!/usr/bin/env python3
import json, pathlib, subprocess, sys
b=pathlib.Path(__file__).resolve().parent
args=sys.argv[1:]
with (b/'commands.jsonl').open('a') as f: f.write(json.dumps(args)+'\\n')
if args[0] in ['genkey','pubkey','genpsk']:
 r=subprocess.run([REAL_WG]+args, input=sys.stdin.buffer.read() if args[0]=='pubkey' else None, stdout=subprocess.PIPE)
 sys.stdout.buffer.write(r.stdout); sys.exit(r.returncode)
k=json.loads((b/'kernel.json').read_text())
if args==['show','interfaces']: print('wg');sys.exit(0)
if args==['show','wg','dump']:
 print('\\t'.join([k['server_private'],k['server_public'],'51820','off']))
 for pub,p in k['peers'].items():
  print('\\t'.join([pub,p['preshared_key'],p['endpoint'] or '(none)',','.join(p['allowed_ips']) or '(none)',str(p['latest_handshake']),str(p['transfer_rx']),str(p['transfer_tx']),str(p['persistent_keepalive']) if p['persistent_keepalive'] else 'off']))
 sys.exit(0)
assert args[:3]==['set','wg','peer'] and args.count('peer')==1, args
pub=args[3]; opts=args[4:]
if opts==['remove']: k['peers'].pop(pub,None)
else:
 p=k['peers'].setdefault(pub,dict(preshared_key='(none)',endpoint='',allowed_ips=[],latest_handshake=0,transfer_rx=0,transfer_tx=0,persistent_keepalive=0))
 assert len(opts)%2==0
 for i in range(0,len(opts),2):
  name,v=opts[i:i+2]
  assert name in ['preshared-key','allowed-ips','persistent-keepalive','endpoint'], name
  if name=='preshared-key':
   path=pathlib.Path(v); assert path.stat().st_mode&0o777==0o600
   p['preshared_key']=path.read_text().strip()
  elif name=='allowed-ips':p['allowed_ips']=v.split(',')
  elif name=='persistent-keepalive':p['persistent_keepalive']=int(v)
  else:p['endpoint']=v
(b/'kernel.json').write_text(json.dumps(k))
'''.replace('REAL_WG',repr(REAL_WG)))
    mock.chmod(0o700)
    mock_ip = base/'mock-ip'
    mock_ip.write_text("#!/bin/sh\nprintf '%s\\n' '192.168.66.0/24 proto kernel scope link src 192.168.66.1'\n")
    mock_ip.chmod(0o700)
    options = dict(data_dir=str(base/'data'), runtime_dir=str(base/'run'), confdir=str(conf),
                   wg_binary=str(mock), ip_binary=str(mock_ip), qr_binary=QRENCODE, sync_binary='/bin/sync')
    (base/'options.json').write_text(json.dumps(options))

    def run(operation='flow'):
        return subprocess.run(BASE_CMD+[str(base), operation], text=True, capture_output=True, env=ENV, timeout=40)

    r = run(); check(r.returncode == 0, 'native platform lifecycle completed: '+r.stdout.strip()+r.stderr.strip())
    check(network.read_bytes() == original_bytes, 'native UCI read leaves entire network file byte-identical')
    final = json.loads((base/'kernel.json').read_text())
    check(final == kernel, 'all 3 original runtime peers and server identity preserved')
    state = json.loads((base/'data/state.json').read_text())
    check(state['peers'] == {} and not (base/'data/journal.json').exists(), 'delete clears managed secret and finished journal')
    check((base/'data').stat().st_mode & 0o777 == 0o700 and (base/'run').stat().st_mode & 0o777 == 0o700, 'private directories are 0700')
    check(all(p.stat().st_mode & 0o777 == 0o600 for d in ['data','run'] for p in (base/d).iterdir() if p.is_file()), 'all state, plans, counters and locks are 0600')
    check(not any(p.name.startswith(('secret-','uci-')) for p in (base/'run').iterdir()), 'private temporary files removed')
    check(not Path('/tmp/wgm-injection').exists(), 'shell metacharacters in client name are inert')
    public = (base/'public-status.json').read_text()
    client = (base/'client.conf').read_text()
    client_private = next(x.split(' = ',1)[1] for x in client.splitlines() if x.startswith('PrivateKey = '))
    check(client_private not in public and server_private not in public and 'preshared_key' not in public, 'public status contains no server/client private key or PSK')
    managed_public = subprocess.check_output([REAL_WG, 'pubkey'], input=(client_private+'\n').encode(), env=ENV).decode().strip()
    check(any(p['public_key'] == managed_public for p in json.loads(public)['peers']), 'exported key derives the actual managed public key using real wg')
    commands = [json.loads(x) for x in (base/'commands.jsonl').read_text().splitlines()]
    mutations = [c for c in commands if c and c[0] == 'set']
    check(len(mutations) == 5 and all(c[3] == managed_public and c.count('peer') == 1 for c in mutations), 'all 5 live mutations target only the managed public key')
    check(all(not any(k in json.dumps(c) for k in [client_private,server_private]) for c in commands), 'no private key appears in process arguments')
    for p in original_peers:
        check(all(c[3] != p for c in mutations), 'legacy key never appears as mutation target')

    import cairosvg
    cairosvg.svg2png(url=str(base/'qr.svg'), write_to=str(base/'qr.png'), output_width=900, output_height=900)
    scanner = os.environ.get('WGM_TEST_ZBAR')
    if scanner:
        q = subprocess.run([scanner, '--quiet', '--raw', str(base/'qr.png')], capture_output=True, env=ENV)
        check(q.returncode == 0 and q.stdout.decode().rstrip('\n') == client.rstrip('\n'), 'real qrencode SVG decodes back to the exact exported configuration')
    else:
        check((base/'qr.png').stat().st_size > 0, 'real QR renders; scanner unavailable')

    # Same executable RPC wrapper, with only install/test paths and the
    # injected platform options changed. No HTTP ACL emulation is claimed.
    entry = (ROOT/'root/usr/libexec/rpcd/wgmanager').read_text()
    entry = entry.replace('/usr/share/wgmanager/', str(ROOT/'root/usr/share/wgmanager')+'/')
    entry = entry.replace('io = platform();', 'io = platform('+json.dumps(options)+');')
    entry_path = base/'rpc-entry.uc'; entry_path.write_text(entry)

    def rpc(method, payload, list_only=False):
        args = ['list'] if list_only else ['call', method]
        result = subprocess.run([str(UCODE), '-L', MODULES, str(entry_path)]+args,
                                input=payload, text=True, capture_output=True, env=ENV, timeout=30)
        check(result.returncode == 0, 'RPC wrapper exits cleanly')
        return json.loads(result.stdout)

    schema = rpc('', '', True)
    check(set(schema) == {'status','prepare','apply','export'}, 'RPC exposes no generic shell, UCI, interface-start or management-unlock method')
    safe = rpc('status', '{}')
    check(safe['ok'] and server_private not in json.dumps(safe) and 'preshared_key' not in json.dumps(safe), 'RPC status filters secrets')
    bad = rpc('exec', '{"cmd":"touch /tmp/wgm-injection"}')
    check(not bad['ok'] and bad['error']['code'] == 'INVALID_METHOD', 'RPC rejects arbitrary execution method')
    bad = rpc('apply', '{"token":"../../etc/config/network"}')
    check(not bad['ok'] and bad['error']['code'] == 'INVALID_TOKEN', 'RPC refuses path traversal in preview token')
    bad = rpc('prepare', 'x'*8193)
    check(not bad['ok'] and bad['error']['code'] == 'INVALID_INPUT', 'RPC enforces request size before parsing')
    bad = rpc('export', '{"peer_id":"p111111111111111111111111","qr":true}')
    check(not bad['ok'] and bad['error']['code'] == 'NO_PRIVATE_KEY', 'RPC refuses legacy/missing private-key export')
    monitor = json.loads((base/'data/state.json').read_text()); monitor['mode'] = 'monitor'
    (base/'data/state.json').write_text(json.dumps(monitor))
    bad = rpc('prepare', '{"action":"create","payload":"{\\"name\\":\\"test\\"}"}')
    check(not bad['ok'] and bad['error']['code'] == 'READ_ONLY', 'RPC cannot bypass the local management gate')

    holder = subprocess.Popen(BASE_CMD+[str(base),'lock-hold'], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=ENV)
    check(holder.stdout.readline().strip() == 'LOCKED', 'first independent process holds lock')
    other = run('lock-only'); check(other.returncode != 0 and 'BUSY|' in other.stdout, 'second process fails closed on lock contention')
    holder.wait(timeout=6)
    check(run('lock-only').returncode == 0, 'lock releases on process exit')
    state_path = base/'data/state.json'; state_path.chmod(0o644)
    unsafe = run('status'); check(unsafe.returncode != 0 and 'UNSAFE_PATH|' in unsafe.stdout, 'world-readable secret state is refused')
    state_path.chmod(0o600); state_path.rename(base/'data/state-original.json'); state_path.symlink_to(base/'data/state-original.json')
    unsafe = run('status'); check(unsafe.returncode != 0 and 'UNSAFE_PATH|' in unsafe.stdout, 'symlink state is refused')
    check(network.read_bytes() == original_bytes, 'all error cases preserve original network file')

print(f'PASS {len(checks)} native platform/crypto/QR checks')

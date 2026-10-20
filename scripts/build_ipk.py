#!/usr/bin/env python3
"""Build a deterministic, architecture-independent OpenWrt 24.10 IPK.

There are no install scripts or network configuration payloads. A remove-only
script stops this app's optional sampler. OpenWrt's gzip/tar envelope is used.
"""
from __future__ import annotations
import gzip
import hashlib
import io
import os
from pathlib import Path
import re
import tarfile

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(os.environ.get('WGM_DIST', str(ROOT.parent/'dist'))).resolve()
EPOCH = int(os.environ.get('SOURCE_DATE_EPOCH', '1792273200'))
VERSION = re.search(r"const VERSION = '([^']+)'", (ROOT/'root/usr/share/wgmanager/core.uc').read_text())[1]+'-1'
PACKAGE = 'luci-app-wgmanager'
DEPENDS = ['luci-base', 'rpcd', 'ucode', 'ucode-mod-fs', 'ucode-mod-uci', 'wireguard-tools', 'qrencode']
EXECUTABLES = {'usr/libexec/rpcd/wgmanager', 'usr/sbin/wgmanager', 'usr/sbin/wgmanager-collector',
               'etc/init.d/wgmanager', 'etc/hotplug.d/iface/95-wgmanager'}


def archive(entries):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode='w', format=tarfile.USTAR_FORMAT) as tf:
        for name, payload, mode, directory in entries:
            info = tarfile.TarInfo(name)
            info.uid = info.gid = 0
            info.uname = info.gname = 'root'
            info.mtime = EPOCH
            info.mode = mode
            if directory:
                info.type = tarfile.DIRTYPE
                tf.addfile(info)
            else:
                info.size = len(payload)
                tf.addfile(info, io.BytesIO(payload))
    result = io.BytesIO()
    with gzip.GzipFile(fileobj=result, mode='wb', mtime=0, filename='') as z:
        z.write(raw.getvalue())
    return result.getvalue()


def build():
    # Git does not preserve empty directories. Recreate this packaging-only
    # directory so a clean checkout produces the identical 0.2.0 archive.
    (ROOT/'root/etc/wgmanager').mkdir(parents=True, exist_ok=True)
    entries = []
    for path in sorted((ROOT/'root').rglob('*')):
        if path.is_symlink():
            raise ValueError('Symlinks are not allowed in this package')
        relative = path.relative_to(ROOT/'root').as_posix()
        assert relative not in {'etc/config/network', 'etc/config/firewall'}
        if path.is_dir():
            entries.append(('./'+relative, b'', 0o700 if relative == 'etc/wgmanager' else 0o755, True))
        else:
            entries.append(('./'+relative, path.read_bytes(), 0o755 if relative in EXECUTABLES else 0o644, False))
    installed = sum(len(x[1]) for x in entries)
    control = (f'Package: {PACKAGE}\nVersion: {VERSION}\nArchitecture: all\n'
               f'Depends: {", ".join(DEPENDS)}\nSection: luci\nPriority: optional\n'
               f'Maintainer: WireGuard Manager project\nLicense: Apache-2.0\n'
               f'Installed-Size: {installed}\n'
               'Description: Native LuCI manager for selected existing WireGuard interfaces.\n'
               ' Defaults to read-only; explicitly adopted original peers have targeted UCI persistence.\n')
    control_tar = archive([('./control', control.encode(), 0o644, False),
                           ('./prerm', (ROOT/'scripts/prerm').read_bytes(), 0o755, False)])
    data_tar = archive(entries)
    result = archive([('./debian-binary', b'2.0\n', 0o644, False),
                      ('./control.tar.gz', control_tar, 0o644, False),
                      ('./data.tar.gz', data_tar, 0o644, False)])
    OUT.mkdir(exist_ok=True, parents=True)
    target = OUT/f'{PACKAGE}_{VERSION}_all.ipk'
    target.write_bytes(result)
    print(f'{target.name}: {len(result)} bytes, SHA256 {hashlib.sha256(result).hexdigest()}')
    return target


if __name__ == '__main__':
    build()

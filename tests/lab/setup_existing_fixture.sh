#!/bin/sh
set -eu
# Only for a disposable --network none container with a fresh wg device.
[ "${WGM_DISPOSABLE_LAB:-}" = YES ] && [ -f /.dockerenv ] && [ ! -e /sys/class/net/eth0 ] || { echo "Refusing outside the isolated disposable test container" >&2; exit 1; }
umask 077
mkdir -p /tmp/wgm-lab /var/run/wgmanager /etc/wgmanager /etc/config
printf 'isolated-only\n' > /tmp/wgm-lab/isolated
wg genkey > /tmp/wgm-lab/server
wg set wg private-key /tmp/wgm-lab/server listen-port 51820
ip address add 192.168.66.1/24 dev wg
ip link set wg up
cat > /etc/config/network <<'NETWORK'
config interface 'wg'
 option proto 'wireguard'
 list addresses '192.168.66.1/24'
config interface 'unrelated'
 option proto 'none'
 option device 'dummy0'
NETWORK
for i in 2 3 4; do
 wg genkey | wg pubkey > /tmp/wgm-lab/pub
 wg genpsk > /tmp/wgm-lab/psk
 pub=$(cat /tmp/wgm-lab/pub)
 psk=$(cat /tmp/wgm-lab/psk)
 cat >> /etc/config/network <<NETWORK
config wireguard_wg 'labpeer$i'
 option description 'lab-original-$i'
 option public_key '$pub'
 list allowed_ips '192.168.66.$i/32'
 option route_allowed_ips '1'
NETWORK
 if [ "$i" = 2 ]; then printf " option persistent_keepalive 'off'\n" >> /etc/config/network; fi
 if [ "$i" != 2 ]; then printf " option preshared_key '%s'\n" "$psk" >> /etc/config/network; fi
 if [ "$i" = 3 ]; then printf " option persistent_keepalive '25'\n" >> /etc/config/network; fi
 if [ "$i" = 4 ]; then printf " option endpoint_host '198.51.100.7'\n option endpoint_port '23456'\n" >> /etc/config/network; printf " option disabled '1'\n" >> /etc/config/network; continue; fi
 if [ "$i" = 2 ]; then wg set wg peer "$pub" allowed-ips "192.168.66.$i/32"; else wg set wg peer "$pub" preshared-key /tmp/wgm-lab/psk allowed-ips "192.168.66.$i/32" persistent-keepalive 25; fi
done
ucode /app/root/usr/share/wgmanager/cli.uc enable-management
ucode /app/tests/existing_kernel_test.uc

#!/bin/sh
# Read-only target checks. Never run `uci show network` or `wg ... dump` here.
printf '%s\n' 'WireGuard Manager · 只读预检'
printf '架构：'; uname -m
printf 'WireGuard 协议：'; uci -q get network.wg.proto
printf 'wg 配置地址：'; uci -q get network.wg.addresses
printf 'wg 监听端口：'; wg show wg listen-port 2>/dev/null
printf '运行中的客户端数：'; wg show wg peers 2>/dev/null | awk 'NF{n++} END{print n+0}'
configured_count=0
while [ "$configured_count" -lt 4096 ] && [ "$(uci -q get "network.@wireguard_wg[$configured_count]")" = wireguard_wg ]; do
	configured_count=$((configured_count + 1))
done
printf '配置中的客户端数：%s\n' "$configured_count"
printf '%s\n' '依赖状态：'
for package in luci-base rpcd ucode ucode-mod-fs ucode-mod-uci wireguard-tools qrencode; do
	if opkg status "$package" 2>/dev/null | awk '/^Status:/{if($0 ~ / installed$/)found=1} END{exit !found}'; then
		printf '  %s 已安装\n' "$package"
	else
		printf '  %s 未安装（安装 IPK 时需从当前固件的软件源补齐）\n' "$package"
	fi
done
printf '%s\n' '本预检没有修改配置或重启服务。'

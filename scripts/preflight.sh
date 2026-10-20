#!/bin/sh
# Read-only target checks. Never run `uci show network` or `wg ... dump` here.
printf '%s\n' 'WireGuard Manager · 只读预检'
printf '架构：'; uname -m
# Show only public status and configured address ranges. Never print keys.
printf '%s\n' '已识别接口：'
wgmanager interfaces
if [ -n "$1" ]; then
	wgmanager --interface "$1" doctor
else
	wgmanager doctor
fi
printf '%s\n' '依赖状态：'
for package in luci-base rpcd ucode ucode-mod-fs ucode-mod-uci wireguard-tools qrencode; do
	if opkg status "$package" 2>/dev/null | awk '/^Status:/{if($0 ~ / installed$/)found=1} END{exit !found}'; then
		printf '  %s 已安装\n' "$package"
	else
		printf '  %s 未安装（安装 IPK 时需从当前固件的软件源补齐）\n' "$package"
	fi
done
printf '%s\n' '本预检没有修改配置或重启服务。'

# WireGuard Manager · LuCI

为已有 WireGuard 接口提供中文客户端管理页面。原生 LuCI + ucode 实现，界面布局参考 wg-easy，支持深浅主题与手机布局。

**当前版本：0.3.1-1 · Apache-2.0**

[下载安装包](https://github.com/halestats/luci-app-wgmanager/releases/download/v0.3.1/luci-app-wgmanager_0.3.1-1_all.ipk) · [源码分享包](https://github.com/halestats/luci-app-wgmanager/releases/download/v0.3.1/luci-app-wgmanager-GitHub-0.3.1.zip) · [版本说明](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/RELEASE-0.3.1.md) · [常见问题](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/FAQ.md) · [检查记录](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/TEST-RESULTS.md)

> **请先核对适用条件。** 当前是针对既有 iStoreOS 部署开发的版本，接口、端口、地址池仍固定在代码中；不是自动搭建 WireGuard 的通用安装器。安装不会创建接口、开放防火墙或配置 NAT。

![桌面界面演示](https://raw.githubusercontent.com/halestats/luci-app-wgmanager/main/docs/images/dashboard-desktop.png)

*截图为 0.3.0 离线演示（0.3.1 布局相同），所有数据均为测试数据，不代表真实设备或客户端在线情况。[手机布局](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/images/dashboard-mobile.png) · 下载 [离线交互预览](https://github.com/halestats/luci-app-wgmanager/releases/download/v0.3.1/WireGuard-Manager-0.3.1-preview.html) 后用浏览器打开。*

## 功能

- 客户端列表、搜索、排序、握手时间、双向速率、趋势与流量累计。
- 新建客户端、自动分配 IPv4、编辑、启用、禁用、删除。
- 插件新建客户端的配置下载与二维码，导出操作明确展示私钥内容。
- 通过 root 命令显式接管原有 UCI 客户端，保留原来的身份与连接参数。
- 操作先预览再确认；并发锁、配置漂移检测、事务回滚与显式恢复。
- 默认只读，可选后台采样；界面显示插件版本。

## 适用环境与当前限制

| 项目 | 0.3.1 的要求或范围 |
| --- | --- |
| 目标固件 | iStoreOS / OpenWrt 24.10 系列，需有 opkg、LuCI、rpcd、ucode |
| 运行接口 | 已配置并运行的 `wg`，UCI 协议为 `wireguard` |
| 服务端地址 | `192.168.66.1/24`，存在 `192.168.66.0/24` 直连路由 |
| 监听端口 | UDP `51820` |
| 客户端地址池 | `192.168.66.2`–`192.168.66.254`，每个客户端单一 `/32` |
| 初次启用管理 | 无客户端数量门槛，支持从 **0 个客户端**开始 |
| IPv6 | 当前地址分配、DNS 和导出路由只支持 IPv4，不能填写 `::/0` |
| 导出默认路由 | `192.168.66.0/24, 192.168.95.0/24`；后者是原目标环境 LAN，须在导出设置中按实际情况修改 |
| 依赖 | luci-base、rpcd、ucode、ucode-mod-fs、ucode-mod-uci、wireguard-tools、qrencode |

IPK 的 `all` 表示插件无架构专用二进制；依赖必须由固件对应的软件源提供，不等于所有 OpenWrt 版本均已验证。不要为满足条件而直接套用这些地址或伪造客户端；其他部署需要先适配源码并验证。

## 地址与路由能否自定义？

| 设置 | 0.3.1 当前行为 |
| --- | --- |
| 服务端地址 | 在 iStoreOS 的网络接口页面配置；插件目前仍只接受 `wg` 的 `192.168.66.1/24`，没有自动适配其他地址 |
| 客户端地址池 | 固定 `192.168.66.2–254`；可在这个池内手工指定单个客户端地址，不能在界面改成其他网段 |
| 导出 AllowedIPs | 可在“导出设置”自定义 IPv4 CIDR，包括实际 LAN 网段或 `0.0.0.0/0`；不是服务端地址池 |
| 新增弹窗的地址提示 | 当前是固定文字，不会跟随 `wg` 地址变化 |

当前实现只读取接口配置并检查是否符合固定条件，尚未根据接口地址推导分配网段。若在 iStoreOS 修改 `wg` 地址，插件不会自动迁移客户端或更新提示，网段不匹配会阻止管理操作。接口 IP 变化后自动推导地址池并同步提示，需要后续适配；不要将这个预期当成 0.3.1 已实现的功能。详见 [地址配置说明](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/ADDRESS-CONFIGURATION.md)。

## 安装

1. 下载 IPK，上传到路由器 `/tmp`。
2. 确认软件源与当前固件匹配，依赖缺失时按需执行 `opkg update`，然后：

```sh
opkg install /tmp/luci-app-wgmanager_0.3.1-1_all.ipk
wgmanager doctor
```

首次安装默认 `mode: monitor`。核对版本、接口、客户端数量、依赖和 `health`，确认原 VPN 仍正常。打开 LuCI 的“服务 → WireGuard Manager”（菜单位置可能随主题略有变化），刷新页面。

若提示 `RPC call to wgmanager/status failed: Object not found`，先检查：

```sh
/usr/libexec/rpcd/wgmanager list
ubus list wgmanager
```

脚本可正常列出方法但 ubus 对象未注册时，再执行：

```sh
/etc/init.d/rpcd restart
ubus call wgmanager status '{}'
```

这会重启 rpcd，可能需要重新登录 LuCI；不重启网络接口。不要把重启 network 或 WireGuard 作为安装步骤。

### 开启管理

仅在上面的适用条件全部满足、设备检查正常后执行：

```sh
wgmanager enable-management
wgmanager doctor
```

开启后可以从第一个客户端开始新增；已有 1 个、2 个或更多客户端也不受数量限制。启用时记录服务端身份，并保护实际发现的既有客户端；需要修改这些客户端时再显式接管。

**新系统仍须先配置并启用符合上述条件的 WireGuard 接口。** 取消客户端数量门槛不代表插件会自动创建服务端、配置防火墙或 NAT。没有旧客户端时，无需执行 `manage-existing`。

首次创建新客户端前，在“导出设置”填写实际公网域名或 IPv4（不带协议、路径和端口），配置 DNS 与客户端 AllowedIPs。页面操作先预览，确认后生效，最后扫码或下载配置到对应客户端。

### 可选：管理原有客户端

这是显式接管步骤，安装或升级不会自动执行：

```sh
wgmanager manage-existing
wgmanager doctor
```

- 接管前生成 `/etc/wgmanager/before-existing-*.json`，权限为 root 私有 `0600`，保存插件状态与原 network 配置。**其中含密钥，不能公开分享。**
- 接管本身只建立管理记录，不改运行中的 Peer，不重新生成密钥，不重启网络服务。
- 接管后编辑、启停、删除会更新所选原 UCI Peer 配置节并同步运行状态，禁用或删除会断开该客户端。
- 原有客户端私钥不在服务端时，无法导出它的完整配置或二维码；原设备继续使用原配置。
- 修改原有客户端 IP 后，须同步修改客户端设备上的地址。
- 当前仅支持单一地址池内 `/32`；重复公钥、不支持的路由及运行/持久配置不一致会拒绝接管。

### 可选：后台累计统计

页面关闭后仍需持续采样时执行：

```sh
/etc/init.d/wgmanager enable
/etc/init.d/wgmanager start
wgmanager doctor
```

默认每 10 秒后台采样、每 15 分钟保存；页面每 2 秒刷新。`stats.collector: false` 表示后台采样未运行，页面打开时仍会采样。流量累计为尽力统计，突然断电、接口重置或采样间隙可能带来误差。

## 管理边界与数据

新客户端保存在 `/etc/wgmanager/state.json`，随 WireGuard 接口热插拔恢复。已接管原有客户端保留在其原 UCI Peer 配置节，由原生配置负责重启恢复。

插件针对所选公钥更新，不调用 network、WireGuard、OpenClash、Tailscale、Lucky 或防火墙重启。0.3.0 可以写入已接管客户端对应的 `network` Peer 配置节，不改其他接口、路由或防火墙；因此旧版“从不写 network”的描述不适用于接管后的管理操作。

出现 `drift` 或待恢复事务时先保留私有文件并运行 `wgmanager doctor`，核对原因，再按提示考虑 `wgmanager recover`。不要手动删除事务文件强行解锁。

```sh
wgmanager read-only
```

可退回只读，保留当前客户端运行状态。卸载会停止插件采样，不主动移除运行 Peer；对原有客户端已保存的禁用、删除仍然有效。接管后的状态不能直接交给 0.2.x 读取，降级前须核对私有备份与之后的配置变更。

## 源码构建

需要 Python 3，无需 OpenWrt SDK：

```sh
WGM_DIST="$PWD/dist" python3 scripts/build_ipk.py
```

会输出 `dist/luci-app-wgmanager_0.3.1-1_all.ipk`。当前仓库的 Makefile 是本项目构建入口，不是可直接放入 OpenWrt SDK 的 package 配方。

发布 IPK 的 SHA-256：

```text
e24736c38474c450182fac4ecb47325b7ab40d6b557e27db6b3efe991d807eb3
```

[目录说明与发布清单](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/GITHUB-PUBLISH.md) · [测试方法](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/TESTING.md) · [更新记录](https://github.com/halestats/luci-app-wgmanager/blob/main/CHANGELOG.md) · [安全设计与历史审查](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/SECURITY-REVIEW.md)

## 验证范围

0.3.1 本次移除数量门槛并同步状态校验，未运行功能测试或设备验收。保留的 135 项检查记录属于 0.3.0，不能作为 0.3.1 已通过的结果。0.2.6 新客户端管理曾获目标 iStoreOS 用户正常使用反馈。详见 [按版本记录](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/TEST-RESULTS.md)。

## 反馈与贡献

请在本仓库 Issues 提供插件版本、固件版本、脱敏后的 `wgmanager doctor` 输出、复现步骤及界面截图。不要上传私钥、PSK、二维码、完整客户端配置、原始 `wg show ... dump`、`state.json` 或接管备份。

欢迎提出接口/网段自动适配、地址池可配置化、IPv6 等适配建议。变更请说明适用环境及验证范围。

## 许可证与致谢

采用 [Apache License 2.0](https://github.com/halestats/luci-app-wgmanager/blob/main/LICENSE)。界面布局参考 [wg-easy](https://github.com/wg-easy/wg-easy)，本项目使用原生 LuCI/ucode 实现；不属于 WireGuard、OpenWrt、iStoreOS 或 wg-easy 官方项目。

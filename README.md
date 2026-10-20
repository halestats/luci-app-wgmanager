# WireGuard Manager · LuCI

原生 LuCI + ucode WireGuard 客户端管理插件，面向 iStoreOS / OpenWrt 24.10 既有 `wg` 接口，支持中文界面、深浅主题、手机布局和客户端配置/二维码导出。

**当前开发版本：0.4.0-1（预发布，尚待功能及设备验收） · Apache-2.0**

[下载安装包](https://github.com/halestats/luci-app-wgmanager/releases/download/v0.4.0/luci-app-wgmanager_0.4.0-1_all.ipk) · [源码分享包](https://github.com/halestats/luci-app-wgmanager/releases/download/v0.4.0/luci-app-wgmanager-GitHub-0.4.0.zip) · [版本说明](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/RELEASE-0.4.0.md) · [常见问题](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/FAQ.md) · [0.3.1 发布基线](https://github.com/halestats/luci-app-wgmanager/releases/tag/v0.3.1)

## 0.4.0：跟随 wg 接口的地址池

`192.168.66.1/24` 是推荐默认配置示例，**不再是管理条件**。插件读取 iStoreOS 中 `wg` 接口的实际主 IPv4 和前缀，后端校验、自动分配、状态概览和新增/编辑弹窗说明使用同一份网段数据。

| wg 接口配置示例 | 自动客户端地址范围 |
| --- | --- |
| `192.168.66.1/24` | `192.168.66.2`–`192.168.66.254` |
| `192.168.77.1/24` | `192.168.77.2`–`192.168.77.254` |
| `10.8.0.1/24` | `10.8.0.2`–`10.8.0.254` |
| `10.8.0.10/24` | `10.8.0.1`–`10.8.0.254`，排除服务端 `.10` |

自动分配还会避开网络地址、广播地址、接口其他 IPv4、已有客户端、禁用客户端和已有 AllowedIPs 覆盖的地址。支持 `/8`–`/30`；多个 IPv4 时取配置顺序中的第一个作为主网段，其他接口地址一并排除。IPv6 不作为本版地址池。

> 修改接口 IP 仍由 iStoreOS 原生网络页面完成。插件不修改或重启接口；配置尚未应用到运行接口、直连路由缺失时会明确阻止写入，不会偷偷创建网络配置。

## 导出路由模式

- **自动跟随 wg 与 LAN 网段**：新安装默认启用；使用当前 `wg` 子网及可解析的原生 `network.lan` IPv4 子网，后续导出时随配置变化。LAN 未配置完整 IPv4/掩码时只加入 wg 子网，不猜测家庭网段。最多保留 16 条。
- **自定义路由**：可填写实际内网 CIDR 或 `0.0.0.0/0`。旧版本已保存的路由升级后按自定义保留，避免覆盖用户选择；可在“导出设置”切换到自动模式。

不再把 `192.168.95.0/24` 当作每台设备的默认 LAN。导出路由与地址池是两件事；路由变化只影响之后下载/扫码的配置，已导入的手机配置需同步修改或重新导入。

## 接口换网段后的旧客户端

已有客户端不会被自动改号。旧网段记录保留并显示“地址需调整”，可以明确编辑到当前地址池、禁用或删除。编辑后仍要同步客户端设备地址；插件新建客户端可重新下载配置，原有客户端私钥未保存在服务端时不能恢复二维码。

接口重建后的插件恢复流程跳过不属于当前地址池的旧记录，返回 `skipped_out_of_pool`。已不在运行接口中的旧网段客户端可以通过明确编辑迁移；事务记录其操作前实际未装载状态，失败回滚不重新添加原本缺失的 Peer。普通配置漂移仍会阻止写入。

尚未接管的原有 UCI 客户端依然受保护；接管要求每个原有客户端为当前池内的单一 IPv4 `/32`。这些记录需要先在原生配置中符合该条件，再显式接管。

## 适用条件

| 项目 | 当前范围 |
| --- | --- |
| 固件 | iStoreOS / OpenWrt 24.10 系列，opkg、LuCI、rpcd、ucode |
| 接口 | 已配置并运行的 `wg`，UCI 协议为 WireGuard |
| 服务端 IPv4 | 从接口读取，主地址为 `/8`–`/30` 内有效主机；`192.168.66.1/24` 仅为默认示例 |
| 客户端地址池 | 按接口前缀推导，单个客户端地址为 `/32`，最多管理 128 个 |
| 初次启用管理 | 支持 0 个、1 个、2 个及更多既有客户端 |
| 监听端口 | 本版仍要求 UDP `51820`；端口可配置化不属于本次 IP 适配 |
| IPv6 | 地址分配、DNS、导出路由仍只支持 IPv4，不能填 `::/0` |
| 依赖 | luci-base、rpcd、ucode、ucode-mod-fs、ucode-mod-uci、wireguard-tools、qrencode |

插件不负责从零创建 WireGuard 服务端、开放防火墙或配置 NAT。IPK 的 `all` 表示插件无架构专用二进制，不代表所有固件/硬件均已验证；依赖需由对应固件的软件源提供。

## 安装和升级

下载 IPK 并上传到 `/tmp`，按需更新匹配固件的软件源，然后：

```sh
opkg install /tmp/luci-app-wgmanager_0.4.0-1_all.ipk
wgmanager doctor
```

核对 `version`、`health`、`network.server_address`、`network.subnet`、`pool_start`/`pool_end` 和 `out_of_pool_count`。升级已经启用管理的设备，无需重复启用或接管。安装不会替你修改 wg 地址。

新安装先检查已配置的接口和依赖，健康正常后执行：

```sh
wgmanager enable-management
```

LuCI 入口为“服务 → WireGuard Manager”。填写导出设置后即可新增第一个客户端。默认只读，无客户端数量门槛。若页面 RPC 对象未注册，先检查脚本和 ubus；仅在需要时重启 rpcd，可能需要重新登录 LuCI：

```sh
/usr/libexec/rpcd/wgmanager list
ubus list wgmanager
/etc/init.d/rpcd restart
```

### 可选：接管原有客户端

```sh
wgmanager manage-existing
wgmanager doctor
```

接管会先生成 root 私有的 `/etc/wgmanager/before-existing-*.json` 备份，再建立管理引用；接管本身不改变运行 Peer。备份含密钥，不可公开上传。接管后对所选客户端的编辑、启停、删除会同步持久化原 UCI Peer 配置；禁用/删除会断开所选客户端。

### 可选：后台采样

```sh
/etc/init.d/wgmanager enable
/etc/init.d/wgmanager start
```

后台每 10 秒采样、每 15 分钟保存，页面每 2 秒刷新。流量累计为尽力统计，不是计费数据；`stats.collector: false` 不影响 WireGuard 转发。

## 管理与恢复边界

操作先预览再确认。预览绑定接口地址及 LAN 配置；预览后网络配置改变，需要重新预览。并发锁、服务端公钥固定、目标归属、漂移检查与事务机制继续保留。

插件新建客户端保存在 `/etc/wgmanager/state.json`，原有接管客户端仍保存于其 UCI 配置节。只更新所选 Peer，不重启网络、WireGuard、防火墙、OpenClash、Tailscale 或 Lucky，不自动改路由/NAT。

发生异常先保留私有文件并运行 `wgmanager doctor`，按诊断考虑 `wgmanager recover`；不要删除事务文件强行解锁。`wgmanager read-only` 可关闭写入并保留运行状态。

旧版本不理解自动路由模式和非原固定网段的记录，**不要直接降级并继续使用新状态**；先核对私有备份、未完成事务与之后的配置修改。卸载不会撤销原有 Peer 已保存的禁用或删除。

## 界面演示

![桌面布局示例](https://raw.githubusercontent.com/halestats/luci-app-wgmanager/main/docs/images/dashboard-desktop.png)

上图为 0.3.0 的历史布局示例，0.4.0 的新地址提示和路由模式以安装界面及新版离线预览为准。所有截图均为假数据。

[下载 0.4.0 离线交互预览](https://github.com/halestats/luci-app-wgmanager/releases/download/v0.4.0/WireGuard-Manager-0.4.0-preview.html)，保存后用浏览器打开；不连接路由器。

## 构建与验证范围

使用 Python 3 构建，无需 OpenWrt SDK：

```sh
WGM_DIST="$PWD/dist" python3 scripts/build_ipk.py
```

IPK SHA-256：`7c6a2fb8311d503c07f7b67d9bb541c3d9223fe85946a8f840ac0b9344201833`。

本次未新增或运行功能测试，未连接或修改用户路由器。历史 135 项检查属于 0.3.0，不能作为 0.4.0 的通过结论。本版作为预发布提供，具体静态检查记录见 [按版本记录](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/TEST-RESULTS.md)。

[完整地址说明](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/ADDRESS-CONFIGURATION.md) · [FAQ](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/FAQ.md) · [更新记录](https://github.com/halestats/luci-app-wgmanager/blob/main/CHANGELOG.md) · [安全设计](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/SECURITY-REVIEW.md)

## 反馈、许可证与致谢

Issues 请提供版本、固件、脱敏后的 doctor 输出和复现步骤；不要上传私钥、PSK、二维码、完整客户端配置、原始 wg dump、state.json 或接管备份。

采用 [Apache License 2.0](https://github.com/halestats/luci-app-wgmanager/blob/main/LICENSE)。界面布局参考 [wg-easy](https://github.com/wg-easy/wg-easy)，本项目原生实现于 LuCI/ucode，不属于 WireGuard、OpenWrt、iStoreOS 或 wg-easy 官方项目。

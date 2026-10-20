# WireGuard Manager · LuCI

原生 LuCI + ucode WireGuard 客户端管理插件，面向 iStoreOS / OpenWrt 24.10 已有的 WireGuard 接口。支持中文界面、深浅主题、手机布局、客户端管理及配置/二维码导出。

**当前开发版本：0.5.0-1（预发布，待功能及设备验收） · Apache-2.0**

[下载安装包](https://github.com/halestats/luci-app-wgmanager/releases/download/v0.5.0/luci-app-wgmanager_0.5.0-1_all.ipk) · [源码分享包](https://github.com/halestats/luci-app-wgmanager/releases/download/v0.5.0/luci-app-wgmanager-GitHub-0.5.0.zip) · [版本说明](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/RELEASE-0.5.0.md) · [常见问题](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/FAQ.md) · [0.3.1 发布基线](https://github.com/halestats/luci-app-wgmanager/releases/tag/v0.3.1)

## 0.5.0：多网段和接口选择

### 一个接口有两个 IPv4 地址

插件读取所选接口的全部 IPv4/前缀，新增和编辑弹窗展示全部可用范围。示例：

| 接口地址 | 客户端可用范围 |
| --- | --- |
| `192.168.77.1/24` | `192.168.77.2`–`192.168.77.254` |
| `192.168.66.1/24` | `192.168.66.2`–`192.168.66.254` |

手动填写可以选择任一范围；留空则按接口配置顺序寻找空闲地址，第一个网段无空闲时继续下一个。单个客户端仍只有一个 IPv4 `/32`。已有 `.66` 客户端只要仍属于任一已配置网段，就不会因 `.77` 排在第一而被标记为旧网段。

排除每个网段的网络/广播地址、接口全部本地地址、已有及禁用客户端、UCI/运行 Peer 的 AllowedIPs。相同子网合并为一个池，重叠网段的边界也保留为不可分配地址。支持 `/8`–`/30`，每个接口最多 16 个不同 IPv4 网段、128 个管理客户端。

### 接口可以不叫 wg

同时读取原生 UCI 中 `proto=wireguard` 的接口及实际 WireGuard 设备。只有一个时自动识别；多个且本页尚未选择时先显示选择提示。页面顶部可切换 `wg`、`wg0`、`vpn0` 等接口，当前浏览器标签页记住自己的选择。

概览名称、地址池、客户端列表、流量记录、导出设置、新增/编辑/启停/删除、恢复及导出文件名均跟随所选接口。导出端口读取该接口的实际 UDP 监听端口，不再固定为 51820；不替用户修改接口、防火墙、端口映射或 NAT。

每个 RPC 都携带接口名。操作预览显示目标接口，预览绑定接口、端口、IPv4 和 LAN 配置；变化后必须重新预览。弹窗及操作期间锁住接口选择，切换后的旧轮询响应不会覆盖新接口数据。

## 自动导出路由

“自动跟随所选接口与 LAN 网段”使用所选接口**全部 IPv4 子网**及可解析的原生 `network.lan` IPv4 子网，去重后最多 64 项。上述两个地址加上 LAN `192.168.95.1/24` 时，AllowedIPs 为：

```text
192.168.77.0/24, 192.168.66.0/24, 192.168.95.0/24
```

新安装默认自动模式；旧版手工保存的路由继续作为自定义保留。自定义可填写实际内网路由或 `0.0.0.0/0`。LAN 缺少有效前缀/掩码时不猜测网段。导出设置只影响之后下载的配置，已经导入手机的配置仍需同步修改或重新导入。

`192.168.66.1/24` 只是未配置时的展示示例，不能用默认示例启用管理。IPv6 地址池、DNS 和导出路由仍不支持，不能填 `::/0`。

## 安装或升级

下载 IPK 上传至 `/tmp`，使用当前固件匹配的软件源补齐依赖，然后执行：

```sh
opkg install /tmp/luci-app-wgmanager_0.5.0-1_all.ipk
/etc/init.d/rpcd restart
wgmanager doctor
```

**本版 RPC 增加 interface 参数，升级后需要重新加载 rpcd 的方法定义。** 上述命令只重启 LuCI 的 RPC 服务，可能需要重新登录；没有重启网络、WireGuard 或防火墙。之后强制刷新浏览器页面。

LuCI 入口：“服务 → WireGuard Manager”。只有一个接口时自动显示；多个接口时在页面顶部选择。命令行可列出接口，并明确指定操作目标：

```sh
wgmanager interfaces
wgmanager --interface wg doctor
wgmanager --interface vpn0 doctor
```

已启用管理的原 `wg` 设备继续使用原记录，无需重复启用或接管。其他接口的记录独立，首次默认为只读；核对所选接口健康正常后：

```sh
wgmanager --interface vpn0 enable-management
```

多接口时，省略 `--interface` 的 doctor 只返回选择提示，写操作拒绝猜测目标。将 `vpn0` 换成自己的接口名。接口名限 1–15 个字母、数字、下划线、点或连字符，首字符为字母、数字或下划线；保留名称 `all`、`interfaces` 不支持。

### 可选：接管所选接口的原有客户端

```sh
wgmanager --interface vpn0 manage-existing
```

无客户端数量门槛，支持从 0 个开始。接管先生成 root 私有备份，再引用对应 UCI Peer；接管本身不改变连接。原有客户端须为当前任一池内的单一 IPv4 `/32`。接管后编辑、禁用、启用、删除会持久化所选 Peer 配置。没有客户端原私钥时不能恢复完整配置或二维码。

### 可选：后台采样

```sh
/etc/init.d/wgmanager enable
/etc/init.d/wgmanager start
```

每 10 秒逐个采样已识别接口，每 15 分钟保存各自累计，停止采样服务时逐接口 checkpoint。页面每 2 秒刷新；`collector: false` 不影响 WireGuard 转发。累计为尽力统计，不能用作计费数据。

## 地址应用和迁移

接口地址仍由 iStoreOS 原生“网络 → 接口”配置。**全部新地址须保存并应用到运行接口**，并有对应直连路由；否则锁住管理并指出未应用的地址。更改接口可能中断 VPN，远程管理时应先安排可靠的访问方式。

从接口配置中移除某网段后，其中已有客户端会显示“地址需调整”；可以明确编辑到当前池、禁用或删除，随后同步设备配置。不会自动改号。恢复流程跳过所有当前池之外的插件记录，不重新添加旧地址。

## 数据和操作边界

原 `wg` 继续使用 `/etc/wgmanager/`，保留其旧状态、密钥、流量和备份；其他接口使用 `/etc/wgmanager/interfaces/<接口名>/`，运行数据同样按接口隔离。每个接口独立保存管理模式及固定服务端身份。

**把接口重命名视为新目标，不自动搬迁旧名称的私钥或管理记录。** 原目录保留；若需迁移，请先保留私有备份并明确核对身份和客户端归属，不要删除旧目录“重置”。

各接口共用写锁，避免同时提交同一 network 文件。插件只对明确接管的单个 Peer 配置节持久化；不修改服务端接口，不写路由/NAT/防火墙，不重启网络、OpenClash、Tailscale 或 Lucky。原生 ifup 事件只恢复该事件接口的插件客户端。

异常先运行 `wgmanager --interface 接口名 doctor`。需要恢复时保留状态及事务，核对后执行对应接口的 recover；不要删除事务文件绕过锁定。`read-only` 关闭该接口的管理写入。旧包不理解新多接口数据及自动路由能力，不要直接降级并沿用新状态。

## 适用环境

需要 iStoreOS / OpenWrt 24.10 系列及 opkg、luci-base、rpcd、ucode、ucode-mod-fs、ucode-mod-uci、wireguard-tools、qrencode。已有并运行的接口须有原生 UCI WireGuard 配置。只有运行设备、没有对应 UCI 配置的接口可发现和查看，但不能管理。

IPK 为 `all`，表示插件没有架构专用二进制，不代表所有固件或硬件已经验证。

## 界面演示

[下载 0.5.0 离线交互预览](https://github.com/halestats/luci-app-wgmanager/releases/download/v0.5.0/WireGuard-Manager-0.5.0-preview.html)，保存后用浏览器打开。演示包含 `wg` 的两个网段和 `vpn0` 的独立列表，全部为假数据，不连接路由器，演示配置不能用于连接。

[历史桌面布局截图](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/images/dashboard-desktop.png) 属于 0.3.0；最新字段以本版安装界面和预览为准。

## 构建与检查范围

```sh
WGM_DIST="$PWD/dist" python3 scripts/build_ipk.py
```

IPK SHA-256：`629b2d02dd988deb2afc608804d17791069b56a749929a88fcac0ec9610c4fb8`。

本次执行静态语法/编译和文件核对，**没有新增或运行功能测试，也没有连接用户路由器验证 0.5.0**。不将旧版通过记录计入本版。以预发布提供，详见 [按版本检查记录](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/TEST-RESULTS.md)。

[地址与接口说明](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/ADDRESS-CONFIGURATION.md) · [FAQ](https://github.com/halestats/luci-app-wgmanager/blob/main/docs/FAQ.md) · [更新记录](https://github.com/halestats/luci-app-wgmanager/blob/main/CHANGELOG.md)

## 分享、反馈和许可证

请分享仓库或 Release 链接。反馈时提供版本、固件、脱敏 doctor 和复现步骤；不要公开私钥、PSK、二维码、完整客户端配置、原始 wg dump、state.json 或接管备份。

采用 [Apache License 2.0](https://github.com/halestats/luci-app-wgmanager/blob/main/LICENSE)。布局参考 [wg-easy](https://github.com/wg-easy/wg-easy)，本项目是独立 LuCI/ucode 实现，不属于 WireGuard、OpenWrt、iStoreOS 或 wg-easy 官方项目。

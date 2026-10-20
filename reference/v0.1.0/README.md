# WireGuard Manager · iStoreOS 24.10 (0.1.0 测试版)

本包是 LuCI 原生只读 WireGuard 监控面板，采用已安装的 `luci-proto-wireguard` 内置 `luci.wireguard.getWgInstances` 接口。不会创建第二个 WireGuard 服务，也不会修改 `/etc/config/network`、接口 `wg`、UCI 配置或防火墙。

## 已实现

- 服务 → WireGuard Manager
- 识别运行中的 `wg`、监听端口和已有 Peer
- 客户端名称、Allowed IP、公钥缩略、端点和最近握手
- 两秒轮询，客户端上下行速度、累计流量、24 次采样柱状图
- 搜索、排序、深色 / 浅色模式
- 客户端详情（只显示公钥，**不显示私钥**）
- 点击「前往接口配置」跳转已有 LuCI 网络页面

## 尚未实现（需验证只读版后再继续）

- 一键新增、编辑、启停、删除 Peer
- 二维码和配置下载
- 长期历史流量和准确在线检测

WireGuard 并无实时在线会话状态，状态按最近握手是否小于 3 分钟估算。第一轮带宽显示 0 B/s 是正常的；第二轮开始统计。客户端下载是服务端的 TX，客户端上传是服务端的 RX。

## 安装

1. 保持现有 WireGuard SSH 连通。
2. 把 `luci-app-wgmanager_0.1.0-1_all.ipk` 上传到路由器 `/tmp/`，或者在系统 → 软件包 → 上传软件包安装。
3. SSH 单条执行：`opkg install /tmp/luci-app-wgmanager_0.1.0-1_all.ipk`。
4. 重新登录 LuCI 或强制刷新，查看「服务 → WireGuard Manager」。若没出现，可 SSH 单条执行：`rm -f /tmp/luci-indexcache`，然后刷新 LuCI。
5. 删除面板：`opkg remove luci-app-wgmanager`。

不要通过网页端或公网直接开放路由器管理界面。

## 注意

本包按 LuCI / OpenWrt 24.10 的公开 RPC 代码编写并做了 JS 语法及包结构静态检查，但未在你本人这台 iStoreOS 上运行测试。遇到错误先停在只读阶段，把浏览器错误或反馈发来。

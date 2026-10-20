# 0.2.5 故障根因与验证

## 新增失败

生产 snapshot 读取 wg dump 的第八列（persistent-keepalive）。真实 wireguard-tools 将关闭状态输出为 off。ucode 的 int('off') 为 NaN，`?? 0` 不会将 NaN 转为 0，因此 target_matches 中的 0 比较失败。实际 Peer 已写入，后续 VERIFY_FAILED 触发回滚。

此前平台模拟器将该字段输出为数字 0，漏掉了真实输出差异。本版同时修正 parser 和模拟器。错误格式、超出 65535 的保活间隔仍拒绝处理。

## 标题

标题从 h2/h3 改成自有 div class + role=heading + aria-level，保留标题语义；由自有 CSS 设置字体和透明背景。样式 URL 带后端版本，减少旧 CSS 缓存干扰。页面仍需一次强制刷新以更新 JavaScript。

## 实际执行

- OpenWrt 24.10.4 x86_64 rootfs、ucode 2025.07.18~3f64c808-r1、wireguard-tools 1.0.20210914-r4。
- 独立 Docker 容器，network=none、独立网络命名空间、NET_ADMIN，仅使用随机生成的测试密钥及三个假 Peer。
- 实际 WireGuard 内核来自 Linux 7.2.9-orbstack（不是用户 iStoreOS 的内核）。
- 0.2.4 同一路径实际复现 APPLY_FAILED；调试发现目标 IP 和 PSK 相符、其他 Peer 指纹相符，唯有保活值为 NaN。
- 0.2.5 真实内核检查 12 项通过：含新增、改地址、配置/二维码、禁用、启用、删除、原三个 Peer、服务端身份、网络文件及最终健康。
- 同环境核心策略 34 项通过；浏览器 24 项、主题与模式 7 项、安装包 20 项通过。
- 完整平台 Python 测试未在此次环境重跑；其模拟器输出已修正为 off，避免继续掩盖本次缺陷。

这些检查未连接用户路由器，不替代用户设备的实际配置导入、连通性及重启持久化验收。

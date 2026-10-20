> 0.3.1 取消数量门槛并更新原有用例预期，但本次未运行测试。下方 0.3.0 和更早版本的通过记录仅属于历史版本。

> 当前版本的测试数量与环境以 [TEST-RESULTS.md](TEST-RESULTS.md) 顶部 0.3.0 表格为准。以下保留分版本的复现方法；历史环境限制和网络写入边界只适用于对应版本。

# 0.3.0 测试补充

当前结果以 TEST-RESULTS.md 的 0.3.0 表格为准。新增原有客户端接管的真实内核检查（tests/existing_kernel_test.uc）及 UI 检查（tests/ui_existing_test.cjs）。

真实内核检查必须在一次性 OpenWrt 容器、独立网络命名空间（--network none）中执行，额外 NET_ADMIN 只作用于测试命名空间。先安装 ucode、ucode-mod-fs、ucode-mod-uci、wireguard-tools、ip-full、qrencode，将源码复制为 /app，创建空 wg 设备，然后仅在该容器中运行：

```sh
WGM_DISPOSABLE_LAB=YES sh /app/tests/lab/setup_existing_fixture.sh
```

此脚本会建立仅供测试的 UCI 配置和假 Peer，具有容器检查门。不要在路由器上执行。用完停止并移除测试容器，不影响已有 Docker 服务。

浏览器原有客户端界面：

```sh
WGM_TEST_CHROME=/absolute/path/to/chrome node tests/ui_existing_test.cjs
```

其他测试方法沿用下方历史说明；其中旧版的环境限制与不写 UCI 边界只描述对应历史版本。

# 测试与复现

## 测试范围

测试始终使用临时文件树和内核 Peer 模拟器，没有创建 VPN 接口，没有接入用户的 iStoreOS。原网络文件逐字节比较和 3 个既有 Peer 的保留是核心验收条件。

运行时为 OpenWrt `openwrt-24.10` 分支指定的 ucode 提交 `3f64c8089bf3ea4847c96b91df09fbfcaec19e1d`（2025-07-18）。宿主编译了该 ucode 的 fs/uci 模块和 libuci/libubox。平台测试中的 `wg genkey/pubkey/genpsk` 使用真实 `wireguard-tools 1.0.20210914`，二维码使用真实 `qrencode 4.1.1`、CairoSVG 渲染和 `zbarimg 0.23.93` 解码。没有把模拟 Peer 的变更描述为真实内核测试。

## 核心策略与事务

```sh
ucode tests/core_test.uc
```

覆盖输入与密钥格式、默认只读、原有客户端保护、自动分配/宽网段冲突、禁用地址保留、完整新客户端生命周期、元数据操作不触碰内核、会话/修订号/时钟绑定、故障注入、回滚、恢复、服务端身份改变、外部运行状态改变、计数重置与重启、损坏管理文件保留。

## 原生平台与 RPC 包装层

安装宿主测试依赖：Python 3、CairoSVG、WireGuard tools、qrencode、zbarimg，以及能加载 fs/uci 模块的 ucode。

```sh
WGM_TEST_UCODE=/absolute/path/to/ucode \
WGM_TEST_MODULES='/absolute/path/to/ucode/modules/*.so' \
WGM_TEST_WG=/absolute/path/to/wg \
WGM_TEST_QRENCODE=/absolute/path/to/qrencode \
WGM_TEST_ZBAR=/absolute/path/to/zbarimg \
python3 tests/platform_test.py
```

需要 root 身份以复核生产路径的所有权规则，但所有写入都在 `TemporaryDirectory` 下。测试驱动通过显式导入参数替换路径，生产 RPC/CLI 不读取这种替换参数或环境变量。测试传入的名称包含 shell 元字符，检查它们不执行；检查所有真实命令只作用于同一新公钥、私钥不进参数、临时文件清理、目录/文件权限、独立进程争锁、宽权限/符号链接文件拒绝。原生 RPC 包装层仅替换安装路径和测试适配器，校验方法白名单、请求大小、无权恢复旧私钥、只读门和路径穿越拒绝；不声称模拟了真实 HTTP 会话 ACL。

未设置 `WGM_TEST_ZBAR` 时只验证渲染；本次验收实际设置了扫描器并比对了**完整配置**的扫码结果。

## DOM 交互

```sh
npm install --no-save jsdom playwright
node tests/ui_dom_test.cjs
```

真实 dashboard.js 在小型 LuCI API 适配层中运行。覆盖受保护客户端的按钮边界、IP 排序、速度方向、轮询失败恢复、预览不写入、重复点击只提交一次、名称作为文本、新建/编辑/禁用/启用/删除、配置 Blob 内容、私钥对话框清理、搜索、导出设置和失效预览错误提示。

该测试不支持 CSS 布局，也不替代 LuCI 的真实会话校验。可选浏览器测试源码为 `tests/ui_test.cjs`：

```sh
WGM_TEST_CHROME=/absolute/path/to/chrome node tests/ui_test.cjs
```

当前执行环境的本地套接字限制导致真实 Chrome 无法启动，故没有把可选浏览器/手机布局检查计入通过数量，也没有交付伪造预览截图。

## 包结构、语法与构建

```sh
node --check root/www/luci-static/resources/view/wgmanager/dashboard.js
shellcheck -s sh scripts/preflight.sh scripts/prerm root/usr/sbin/wgmanager root/usr/sbin/wgmanager-collector root/etc/init.d/wgmanager root/etc/hotplug.d/iface/95-wgmanager
python3 scripts/build_ipk.py
python3 tests/package_test.py
```

包结构测试校验 gzip/tar IPK、必需元数据、实际依赖、执行权限、没有 network/firewall 载荷、没有安装阶段脚本、卸载只涉及自己的采样服务，以及重建结果一致。

最终运行记录随源码保存在 `docs/test-results/`；所有记录仅包含假数据和检查结果，没有用户密钥或配置。

## 设备验收顺序

1. 安装后先 `wgmanager doctor`，保持 `monitor`，核实 3 个旧客户端与既有 VPN 均正常。
2. 仅重载 rpcd 注册插件，验证真实 LuCI 页面和权限。
3. 手动启用新客户端管理，用第二设备创建一个测试客户端，同时持续检查原客户端连通。
4. 仅对测试客户端验收二维码、配置导入、速率、编辑、禁用、启用、删除。
5. 可选启用本插件采样服务；真实重启持久化测试留到用户自行选择的维护时段。

以上第 1–5 项尚未在用户设备执行，交付不以“请立即重启网络”作为任何前置条件。

# 0.5.0 接口和地址数据来源

## 接口发现与目标

platform 读取已提交 UCI 中所有 proto=wireguard 的 interface 配置节，并合并 `wg show interfaces` 的实际设备名单。只返回名称、配置存在性、运行存在性和地址等公开字段。没有对应原生配置的运行设备不能管理。

接口名由 valid_interface 验证：1–15 个 ASCII 安全字符，不接受路径、开头短横线、保留参数 all/interfaces。CLI/RPC 不允许指定数据目录、二进制或环境路径。

无请求目标且只有一个时自动选择；多个时 status 返回 selection_required=true 和列表，不读写任何接口的管理状态。其他 RPC 拒绝未选择的目标。选择保存在浏览器 sessionStorage；每次 status/prepare/apply/export 显式传递 interface，无全局默认切换。

## 存储、锁和升级

wg 的 data/run 根目录保留为旧路径；其他接口分别使用根目录下 interfaces/<name>，分离 state/journal/plan/traffic/collector/backup。目录 0700、文件 0600 和安全文件检查沿用。所有接口使用同一根运行目录锁，以串行提交共享的 UCI network 文件。

接口重命名不做自动身份迁移；旧名称私有目录保留。各接口的管理模式独立，新接口默认 monitor，原 wg 模式不改变。新 RPC 方法定义需由 rpcd restart 重新加载，之后刷新浏览器。

## 全部 IPv4 地址池

network_profile 读取所选接口的全部 addresses，忽略 IPv6。每个 IPv4 须含 /8–/30 且为有效主机地址；相同子网去重，保留配置顺序，最多 16 个子网。

返回 network.server_addresses、subnets、pools、excluded_addresses、reserved_addresses 和 hint。旧 server_address/subnet/prefix/pool_start/pool_end 字段仍代表第一池，供兼容读取；新逻辑使用 pools 数组。

每池排除网络/广播及全部本地地址；重叠子网的边界也保留。address_in_pool 可接受任一池的可用地址。allocate 按配置顺序遍历池，按区间跳过既有/禁用/运行 Peer 和宽 AllowedIPs。第一个池没空位才尝试下一池，不逐地址扫描 /8。

概览展示全部服务端地址。新增/编辑弹窗读取统一 hint，打开时也随轮询更新。单个客户端依旧分配一个 /32，用户可以手填任一池内的地址。

## 应用状态和导出路由

逐项核对 `ip -4 address show dev <name>` 含全部配置地址；未应用时 NETWORK_NOT_APPLIED 明确列出地址。再核对各子网在该设备上有无经由网关的对应直连路由；缺少时返回缺失网段，插件不创建路由。

auto 路由是全部接口子网加可解析 network.lan 网段，去重最多 64 项；custom 保留用户路由。无有效 LAN 掩码时不猜测；不自动推导 IPv6。导出的 Endpoint 读取当前所选接口实际监听端口，预览网络签名也绑定该端口。

接口地址变化使旧预览失效；客户端不属于任何池时才标记 out_of_pool。恢复跳过旧地址，明确编辑才迁移；既有 UCI 引用、公钥、事务和回滚约束仍保留。

## 采样与恢复

collect-all/checkpoint-all 逐接口执行各自采样与保存，一个失败仍继续其他接口并返回逐接口结果。原生 ifup 事件通过 --interface 只恢复事件目标；不主动启动或重启网络。插件私有记录的写入与原生 Peer 单节提交边界不变。

开发阶段的静态检查记录保留。2026-10-21 用户反馈整体运行实测正常并确认正式发布，详见 DEVICE-VALIDATION-0.5.0.md；不补写未提供的专项测试结果。

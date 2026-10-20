# 0.2.6 管理按钮灰色问题

LuCI openwrt-24.10 的 dom.attr 会省略 null/undefined 属性，但对 false 调用 setAttribute，成为字符串 false。HTML 布尔属性 disabled 只要存在即禁用，disabled="false" 也会禁用。

因此，在正常管理模式里给卡片按钮传 disabled: false，仍会禁用二维码/配置、编辑、启停和删除。页面顶部的新增和导出设置按钮使用 DOM property 直接赋值，因此可能仍可操作。

修复为：需要禁用时保留真值，不需要时传 null，省略整个属性。未放宽后端权限、只读限制、忙状态或漂移保护。

## 测试缺口与回归

此前测试适配器将布尔值赋给原生 disabled property，使 false 正常解除禁用，未反映 LuCI 的属性行为。这次适配器按 LuCI 实现执行：null 省略，其他标量走 setAttribute。

在相同适配器和浏览器中，0.2.5 的四个按钮均得到 disabled="false"，回归断言按预期失败；0.2.6 五个按钮（含详情）均无 disabled 属性且可用。只读、忙状态、漂移仍使对应操作不可用，成功刷新会移除后端已不存在的客户端。

本版通过浏览器交互 24 项、属性与状态 7 项、主题与模式 7 项、安装包 20 项。RPC 采用模拟层，未连接用户路由器。后端除版本号外与 0.2.5 相同，未重复执行内核管理套件。

## 用户反馈的状态差异

截图出现客户端 s，但最新 doctor 只有三个受保护客户端、没有插件管理客户端。因此不能仅凭截图认定已持久保存；需在升级后新建一个测试客户端，再用 doctor 核对 client_count 4 / protected_count 3 / managed_count 1。

参考源码：
https://github.com/openwrt/luci/blob/openwrt-24.10/modules/luci-base/htdocs/luci-static/resources/luci.js

# 0.5.0 正式发布

2026-10-21，使用者实测运行正常并确认正式发布。GitHub v0.5.0 取消预发布标记并设为最新正式版；主分支 README、版本说明和设备反馈同步更新。

保留已实测的原标签、安装包、源码 ZIP、离线 HTML 和 SHA256SUMS，不覆盖附件或改变校验值。源码 ZIP 是预发布阶段的原始构建快照，内含当时文档；最新正式说明以主分支和 Release 为准。已安装 0.5.0 不需要重装。

旧版本下载和 Release 保留。SOURCE-SHA256SUMS 反映主分支当前源码及文档，不包含 downloads、编译缓存及自身。

不上传实际设备配置、state、私钥、PSK、二维码、完整客户端配置或接管备份。用户反馈只记为实际提供的整体运行反馈，不扩展成未执行的自动化或兼容性覆盖。

安装文档和 Release 正文补充 `opkg update && opkg install rpcd ucode ucode-mod-fs ucode-mod-uci wireguard-tools qrencode`，方便已有 LuCI/opkg 的新系统准备依赖；本次只改说明，原附件和运行代码保持不变。

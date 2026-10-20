# 当前开发状态

- 0.2.6：用户反馈新客户端管理正常，doctor 为 mode manage、health ok、client_count 4、protected_count 3、managed_count 1、drift_count 0。保留为取消原有保护前的基线。
- 用户明确要求原三个客户端不再保护，进入正式使用。
- 0.3.0：增加原有 UCI 客户端的原位接管、持久管理、备份与事务恢复，135 项本地检查通过。尚未在用户路由器安装此新版本。
- 接管动作需要设备 root 执行 wgmanager manage-existing，安装不会自动改变运行 Peer。用户当前预期接管结果为 protected_count 0、managed_count 4、legacy_count 3。
- 接管后的编辑、禁用、删除涉及所选原 UCI Peer 的持久配置；沿用不重启网络和不写防火墙的边界。
- 所有交付版本、源码、构建脚本及测试记录独立保留。备份含秘密，留在设备 root 私有目录，不上传 GitHub。

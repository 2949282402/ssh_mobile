最新更新时间：2026-08-08

# feature_sftp

SFTP 文件浏览、传输、预览、编辑和路径收藏 Feature。

## 边界

- `SftpModule` 独占 `sftp.db`、路径 Repository 和 Feature Service。
- `sftp.db` 只保存 recent paths、favorite paths 和必要的传输元数据，不保存密码、
  私钥或 Token。
- Feature 通过 `SftpBackend` 使用 App Shell 注入的旧 SFTP 后端，并通过
  `ssh_core.SshSessionManager` 共享 App Scope SSH 初始化；Feature 不创建或关闭
  全局 SSH/SFTP 资源。
- 页面使用 Route-scoped `SftpViewModel`。页面关闭时解除监听；当前兼容后端仍由
  `AppRuntime` 持有，因此允许未迁移模块继续使用同一连接和传输任务。

## 公共入口

只通过 `package:feature_sftp/feature_sftp.dart` 引用 `SftpModule`、
`SftpViewModel`、页面、模型和 Port。App Shell 的兼容适配器位于
`apps/ssh_mobile_full/lib/app/sftp_feature_adapters.dart`。

## 验证

```powershell
flutter analyze
flutter test --no-pub
```

Drift schema 变化后，在本目录运行 `dart run build_runner build`，并提交生成的
`lib/src/data/database/sftp_database.g.dart`。

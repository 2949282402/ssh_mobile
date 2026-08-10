最新更新时间：2026-08-10

# feature_sftp

SFTP 文件浏览、传输、预览、编辑和路径收藏 Feature。

## 边界

- `SftpModule` 独占 `sftp.db`、路径 Repository 和 Feature Service。
- `sftp.db` 只保存 recent paths、favorite paths 和必要的传输元数据，不保存密码、
  私钥或 Token。
- Feature 通过 `SftpBackend` 使用 App Shell 注入的旧 SFTP 后端，并通过
  `ssh_core.SshSessionManager` 共享 App Scope SSH 初始化；Feature 不创建或关闭
  全局 SSH/SFTP 资源。
- 页面使用 Route-scoped `SftpViewModel`。页面关闭时解除监听；共享的旧
  `SftpService` 仍由 `AppRuntime` 持有，只能通过 App Shell backend adapter 注入。
- 公共入口提供 SFTP 路由的纯 metadata；App Shell 负责聚合并创建 Route Scope，Feature
  不依赖其他 Feature 的实现。

## 公共入口

只通过 `package:feature_sftp/feature_sftp.dart` 引用 `SftpModule`、
`SftpViewModel`、页面、模型和 Port。App Shell 的 Feature 适配器位于
`apps/ssh_mobile_full/lib/app/sftp_feature_adapters.dart`；仍共享的 native
后端仅通过 `sftp_backend_adapters.dart` / `sftp_io_backend_adapters.dart` 暴露。

## 验证

```powershell
flutter analyze
flutter test --no-pub
```

Drift schema 变化后，在本目录运行 `dart run build_runner build`，并提交生成的
`lib/src/data/database/sftp_database.g.dart`。

## Package contract

- 职责：提供 SFTP 浏览、传输、预览、编辑、路径历史和收藏。
- 不负责：全局 SSH/SFTP 连接、凭据存储或其他 Feature 的实现。
- Public API：`package:feature_sftp/feature_sftp.dart`，包括 `SftpModule`、页面、
  ViewModel、模型和 Port。
- 依赖：`app_core`、`app_ui`、`ssh_core`、Drift、Provider、SFTP/预览直接插件。
- 数据库：`SftpModule` 独占 `sftp.db`；只保存路径/传输元数据，不保存密码、私钥或 Token。
- 生命周期与资源 Owner：Module 负责数据库、Repository 和 Feature Service；Route
  Scope 负责 ViewModel；AppRuntime 负责注入的 SSH Manager 和兼容 Backend。
- 测试命令：`dart run build_runner build`、`flutter analyze --no-pub`、
  `flutter test --no-pub`。

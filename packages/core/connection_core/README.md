> 最新更新时间：2026-08-08

# connection_core

`connection_core` 是 Connection 领域的 Core Package，负责非 UI 领域模型、
Connection/凭据/Host Key 公共契约，以及只保存非敏感连接结构的独立 Drift
数据库。

## 边界

- `ConnectionConfig` 的密码和私钥字段只用于短生命周期运行时数据，数据库映射
  会主动排除它们。
- `ConnectionRepository` 只管理连接结构和排序；`CredentialRepository` 只管理
  Secure Storage 中的密码、私钥；`HostKeyRepository` 只管理 Host Key 信任元数据。
- `ConnectionDatabase` 是本 Package 的资源，由 AppRuntime 创建并关闭；它使用
  `connection.sqlite`，不读取或迁移旧统一业务数据库/SharedPreferences 连接数据。
- 本 Package 不依赖任何 Feature，也不暴露 `/src/` 路径给外部调用方。

## 验证

```bash
flutter pub get
dart run build_runner build
flutter analyze
flutter test
```

> 最新更新时间：2026-08-08

# connection_core 维护约束

- 这里只放 Connection 领域模型、Repository/Capability 契约、Connection Drift
  数据库和 Secure Storage 凭据实现，不放 Screen、ViewModel 或 SSH 会话实现。
- Drift 表只能保存非敏感连接结构；密码、私钥和 Token 必须经过
  `CredentialRepository` 进入平台 Secure Storage。
- `ConnectionDatabase` 的创建和关闭 Owner 是 AppRuntime；Repository 不得自行创建
  全局数据库，也不能通过静态单例隐藏资源。
- 数据库当前按 Plan 使用全新 `connection.sqlite`，不添加旧统一业务数据库或旧
  SharedPreferences 的迁移适配器。
- 新增或修改代码需要补充中文职责/约束注释，并为 CRUD、并发顺序、凭据隔离和
  生命周期补充测试。

最新更新时间：2026-08-10

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
- Full App 迁移已关闭旧 Connection 导入门禁；不得恢复旧
  `apps/ssh_mobile_full/lib/features/connection/` 业务入口或模型转导出。

## Step29 标准字段

- 允许修改范围：Connection 模型、Repository、Host Key/凭据契约、数据库输入、生成代码和测试。
- 禁止依赖：Feature、SSH 会话、UI、App Shell 业务实现或统一旧数据库。
- Public API 修改要求：同步 `connection_core.dart`、AppRuntime 适配器、迁移文档和生成代码。
- 数据库约束：只保存非敏感结构，数据库名固定为 `connection.sqlite`；秘密只能进 Secure Storage。
- 资源释放规则：AppRuntime 创建并关闭 `ConnectionDatabase`；Repository 不隐藏全局 Owner。
- 必须运行的测试：`dart run build_runner build`、`flutter analyze`、`flutter test`。

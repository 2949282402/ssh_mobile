最新更新时间：2026-08-09

# feature_connection

SSH Mobile 的连接 Feature，负责连接配置编辑界面和连接配置的应用编排。

## 边界

- 只通过 `connection_core` 的 `ConnectionRepository`、`CredentialRepository` 和 `HostKeyRepository` 访问连接数据。
- SSH/SFTP/监控等运行时能力通过 `ConnectionRuntimePort` 和 `ConnectionVerificationPort` 注入，Feature 不创建 App Service。
- 不拥有 Connection 数据库；数据库生命周期仍由 AppRuntime 管理。
- 当前 Step 06 暂时在包内保留连接页面所需的最小 UI 组件和双语文案。Step 09 建立 `app_ui` 后，再将共享组件迁移到公共 UI 包。
- 公共入口同时提供纯 Route metadata；App Shell 只聚合这些描述并在 Route Scope 创建
  ViewModel，不把 Widget 或 ViewModel 放入 Core。

## 公共入口

业务代码只能导入 `package:feature_connection/feature_connection.dart`，不能导入 `lib/src/`：

- `ConnectionViewModel`
- `ConnectionRuntimePort`
- `ConnectionVerificationPort`
- `ConnectionStrings`
- `AddEditScreen`

## 生命周期

`ConnectionViewModel` 是 Route/Provider Scope 资源，释放时只解除 Repository 监听；Repository、凭据存储和 SSH/SFTP 服务由 AppRuntime 或注入方负责释放。
